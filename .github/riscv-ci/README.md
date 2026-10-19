# RISC-V QEMU CI

Cross-compiles this repository for `riscv64-unknown-linux-gnu` and runs the
tier1 suites under QEMU:

- **user-mode** — 12 parallel matrix jobs (`test/jdk`, `test/langtools`,
  `test/hotspot/jtreg`, `test/lib-test`), each JDK binary wrapped with
  `qemu-riscv64`.
- **system-mode** — 5 parallel suites booting a full RISC-V Linux guest
  (`qemu-system-riscv64`) with virtio-9p shared folders. The test lists live in
  [`sysmode/`](sysmode); they target the vector/intrinsics tests that cannot run
  correctly in user-mode.

The workflow is [`../../workflows/riscv-ci.yml`](../../workflows/riscv-ci.yml).

## Requirements

Self-hosted runners with the `riscv-ci` label, plus:

| Item | Location |
| --- | --- |
| Toolchain image | `art.damo.xrvm.cn/riscv-sw/openjdk/openjdk-buildtest-ub2204:v10` |
| SystemMode image cache | `/home/jenkins/ci-cache/sysmode-images` (`Image`, `fw_dynamic.bin`, `rootfs.ext4`) |
| Outbound proxy | `http://11.122.133.68:3128` (runner `.env` + workflow env) |

The image ships the Xuantie GCC 14.3 sysroot, jtreg 8.1, boot JDK 25 and the
Dev-CI QEMU 8.2.94 builds. Tests intentionally use **JDK 25 end to end**: a
guard in every script fails the job if either the source tree or the JDK under
test is not version 25.

The SystemMode images come from the internal Xuantie Linux SDK. If the cache is
absent the script downloads the SDK tarball from `11.122.130.22` instead.

## Artifacts

The intranet egress proxy does not allow the Azure blob endpoints used by
`actions/upload-artifact`, so the jobs exchange files through the runner host:

- `/home/jenkins/ci-cache/runs/<run-id>/` — JDK bundles and `source.tar.gz`,
  removed when the run finishes.
- `/home/jenkins/ci-cache/results/<run-id>/<job>/` — jtreg reports and logs,
  kept for 7 days.

## Triggering

- Push to `master`, or open a pull request against `master`.
- Manual runs: `workflow_dispatch` with optional `jvm_options` (user-mode only;
  defaults to no extra flags) and `timeout_factor` (default `96`).
- The workflow is serialized per ref; a new push cancels the previous run.

## Job layout

The jtreg JShell tests connect to a remote JVM with a hard-coded 5-second JDI
timeout, and the SystemMode `targeted_langtools` suite has similar
timing-sensitive JDI/stop tests. On a 32-core host they fail when they compete
with the matrix jobs, so they are isolated:

1. `langtools` runs alone (`-cpus 28`) right after the build.
2. `usermode` (11 targets, max 4) and `systemmode` (4 suites, max 2) run next.
3. `systemmode_langtools` runs last, alone.

## Known issues

- `TestAESIntrinsicsOnUnsupportedConfig` in the system-mode `targeted_hotspot`
  suite currently fails: the forced `-XX:+UseZvkn` flag bypasses CPU feature
  detection until the corresponding JDK patches land. The job is left failing
  on purpose rather than masking the failure.

## Reproducing a single job locally

```bash
# Build
docker run --rm \
  -v "$PWD:/workspace/src" -v "$PWD/out:/workspace/out" \
  art.damo.xrvm.cn/riscv-sw/openjdk/openjdk-buildtest-ub2204:v10 \
  bash /workspace/src/.github/riscv-ci/scripts/build.sh

# User-mode (needs out/*.tar.gz from the build)
docker run --rm \
  -e TEST_TARGET='test/jdk/:tier1_part1' \
  -v "$PWD:/workspace/src" -v "$PWD/out:/workspace/artifacts:ro" \
  -v "$PWD/test-out:/workspace/out" \
  art.damo.xrvm.cn/riscv-sw/openjdk/openjdk-buildtest-ub2204:v10 \
  bash /workspace/src/.github/riscv-ci/scripts/usermode-test.sh

# System-mode (needs the same artifacts and the image cache)
docker run --rm --privileged \
  -e SUITE=targeted_jdk \
  -v "$PWD:/workspace/src" -v "$PWD/out:/workspace/artifacts:ro" \
  -v "$PWD/test-out:/workspace/out" \
  -v /home/jenkins/ci-cache/sysmode-images:/opt/sysmode-images:ro \
  art.damo.xrvm.cn/riscv-sw/openjdk/openjdk-buildtest-ub2204:v10 \
  bash /workspace/src/.github/riscv-ci/scripts/systemmode-test.sh
```
