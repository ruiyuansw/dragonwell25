# RISC-V CI (GitHub Actions → Flow)

GitHub Actions is the trigger and status layer. Every job pins one self-hosted
runner slot and waits for exactly one node of an internal Flow pipeline; all
compile and test work runs on Flow pods.

| GitHub job | Runner slot | Flow pipeline | Flow node |
| --- | --- | --- | --- |
| `Flow UserMode build` | `slot-01` | `20598` | `dragonwell25_Build` |
| `usermode jdk_part1a/1b` | `slot-02..03` | `20598` | `dw25_UM_jdk_part1a/1b` |
| `usermode jdk_part2/3` | `slot-04..05` | `20598` | `dw25_UM_jdk_part2/3` |
| `usermode langtools_1/2/3` | `slot-06..08` | `20598` | `dw25_UM_langtools_1/2/3` |
| `usermode hs_common/runtime/serviceability/gc` | `slot-09..12` | `20598` | `dw25_UM_hs_*` |
| `usermode hs_compiler_part1/2/3` | `slot-13`, `slot-20..21` | `20598` | `dw25_UM_hs_compiler_*` |
| `usermode lib_test` | `slot-22` | `20598` | `dw25_UM_lib_test` |
| `Flow SystemMode build` | `slot-14` | `20599` | `dragonwell25_Build` |
| `systemmode targeted_jdk/langtools/hotspot` | `slot-15..17` | `20599` | `dw25_SM_targeted_*` |
| `systemmode hotspot_part1a/1b` | `slot-18..19` | `20599` | `dw25_SM_hotspot_part1a/1b` |
| `systemmode hotspot_part2a/b/c` | `slot-23..25` | `20599` | `dw25_SM_hotspot_part2a/b/c` |

Every test task is sized for at most ~2 hours on the 16c pods. The UserMode
split is computed from the checked-out test tree at run time (greedy balance by
test count), so it follows tests being added or removed; the SystemMode lists
are split round-robin. Suites that are split carry a 3h Flow max runtime.

SystemMode passes no `-XX:+UseXXX` flags: the guest kernel's hwprobe is the
single source of truth for V/Zvkn detection. UserMode keeps the pipeline's
`JVM_OPTIONS` variable (empty by default).

A slot label is attached to exactly one runner and each job runs on exactly one
slot, so the GitHub job ↔ Flow node pairing is deterministic. Both pipelines
carry the same pod resources as the internal `jdk25u` setup (16c/32g, build
plan 16c/32g). SystemMode additionally needs a privileged pod.

## Internal resources only

The pipelines never use upstream toolchain or SDK downloads:

| Item | Source |
| --- | --- |
| Build/test image | `art.damo.xrvm.cn/riscv-sw/openjdk/openjdk-buildtest-ub2204:v10` |
| Toolchain / sysroot | `/opt/xuantie-toolchain` (inside the image) |
| Boot JDK | `/opt/boot-jdk-25` |
| QEMU | `/opt/xuantie-qemu-devci` (user-mode and system-mode builds) |
| SystemMode images | Xuantie Linux SDK `XuanTie_V1.4.0-rc3` from `11.122.130.22`, cached at `/opt/sysmode-images` |
| jtreg | `/opt/jtreg` (8.1) |

Both the source tree and the JDK under test are checked to be JDK 25.

## Triggering

- Push to `master` or `ci/**`, or open a same-repo pull request against `master`.
- `workflow_dispatch` accepts optional `jvm_options` for the UserMode pipeline.
- Flow has no working cancel API, so a superseded run is queued, not cancelled
  (`cancel-in-progress: false`); queuing avoids orphaned Flow pods.
- Fork PRs are skipped: they cannot read `FLOW_TOKEN` and must not execute on
  the self-hosted runners.

The trigger jobs call [`flow_bridge.py`](flow_bridge.py):

```bash
flow_bridge.py trigger   --pipeline 20598 --set SOURCE_REPO=... --set ...
flow_bridge.py wait-node --history <history-id> --label dw25_UM_jdk_part1
flow_bridge.py show      --history <history-id>
```

The Flow token is read from the `FLOW_TOKEN` repository secret, falling back to
`~/.riscv-flow/auth.json` on the runner host. History IDs are exported as job
outputs and mirrored to `/home/jenkins/ci-cache/flow/<run-id>/{um,sm}.history`.

## Runners

Twenty-five self-hosted runners on the build host, one per slot:

- labels: `self-hosted`, `riscv-bridge`, `slot-01` … `slot-25`
- auto-start on boot: systemd units `actions.runner.ruiyuansw-dragonwell25.riscv-ci-NN`
- outbound proxy configured in each runner's `.env`
  (`http_proxy`/`https_proxy=http://11.122.133.68:3128`, intranet hosts in
  `no_proxy`)

Register or relabel a runner with a fresh token from
*Settings → Actions → Runners → New runner*:

```bash
cd ~/actions-runner-NN
./config.sh --replace --url https://github.com/ruiyuansw/dragonwell25 \
  --token <registration-token> --name riscv-ci-NN \
  --labels riscv-bridge,slot-NN --unattended
./svc.sh install && ./svc.sh start
```

## Test exclusions

- [`ProblemList-riscv64-qemu-usermode.txt`](ProblemList-riscv64-qemu-usermode.txt)
  is applied to all UserMode suites. Entries whose test path no longer exists in
  the checked-out tree are dropped before jtreg runs.
- [`sysmode/`](sysmode) holds the five SystemMode test lists used by the Flow
  suites.

## Known issues

- `TestAESIntrinsicsOnUnsupportedConfig` in the SystemMode `targeted_hotspot`
  suite fails until the forced `-XX:+UseZvkn` path is fixed in the JDK: the flag
  bypasses CPU feature detection. The job is left failing on purpose.
- UserMode JShell tests need a TTY (`System.console()`), and some JDI-based
  tests have a hard-coded 5 s connect timeout; the Flow pods provide both the
  TTY and the CPU headroom.
