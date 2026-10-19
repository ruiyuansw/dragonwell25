#!/usr/bin/env bash
# Run one tier1 test target under QEMU user-mode.
# Inputs (env): TEST_TARGET, JVM_OPTIONS, TIMEOUT_FACTOR, JTREG_JOBS
set -eux

SRC_DIR="${SRC_DIR:-/workspace/src}"
ART_DIR="${ART_DIR:-/workspace/artifacts}"
OUT_DIR="${OUT_DIR:-/workspace/out}"
TEST_TARGET="${TEST_TARGET:?TEST_TARGET is required}"

export SYSROOT_RV64="${SYSROOT_RV64:-/opt/xuantie-toolchain/sysroot}"
export BOOT_JDK_HOME="${BOOT_JDK_HOME:-/opt/boot-jdk-25}"
export JT_HOME="${JT_HOME:-/opt/jtreg}"
export XUANTIE_CPU="${XUANTIE_CPU:-xt-c9501fdvkmt}"
export DEBUG_LEVEL="${DEBUG_LEVEL:-release}"
JVM_OPTIONS="${JVM_OPTIONS:-}"
TIMEOUT_FACTOR="${TIMEOUT_FACTOR:-96}"
JTREG_JOBS="${JTREG_JOBS:-6}"

QEMU_BIN=""
for dir in /opt/xuantie-qemu-devci /opt/qemu /opt/xuantie-qemu; do
  if [ -x "$dir/bin/qemu-riscv64" ]; then QEMU_BIN="$dir/bin/qemu-riscv64"; break; fi
done
[ -z "$QEMU_BIN" ] && QEMU_BIN=$(which qemu-riscv64 2>/dev/null || true)
[ -z "$QEMU_BIN" ] && { echo "ERROR: qemu-riscv64 not found"; exit 1; }
echo "Using QEMU: $QEMU_BIN"

mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

# Unpack the JDK under test and the prebuilt test image.
mkdir -p /workspace/test-run
cd /workspace/test-run
tar xzf "$ART_DIR/jdk-riscv64_bin.tar.gz"
tar xzf "$ART_DIR/jdk-riscv64_bin-tests.tar.gz"
rm -rf jdk-image tests-image
mv jdk jdk-image
mv test tests-image

export QEMU_LD_PREFIX="$SYSROOT_RV64"
export QEMU_CPU="$XUANTIE_CPU"
JDK_DIR=/workspace/test-run/jdk-image
wrap_elf() {
  local f="$1"
  [ -f "$f" ] || return 0
  case "$f" in *.so|*.so.*|*.debuginfo) return 0;; esac
  head -c 2 "$f" | grep -q '#!' && return 0
  head -c 4 "$f" | grep -q 'ELF' || return 0
  mv "$f" "$f.real"
  printf '#!/bin/sh\nexec %s -L %s -cpu %s "%s.real" "$@"\n' "$QEMU_BIN" "$SYSROOT_RV64" "$XUANTIE_CPU" "$f" > "$f"
  chmod +x "$f"
}
for f in "$JDK_DIR"/bin/*; do wrap_elf "$f"; done
[ -f "$JDK_DIR/lib/jspawnhelper" ] && wrap_elf "$JDK_DIR/lib/jspawnhelper"
GTEST_DIR=/workspace/test-run/tests-image/hotspot/gtest
if [ -d "$GTEST_DIR" ]; then find "$GTEST_DIR" -type f -executable | while read f; do echo "$f" | grep -q '\.real$' && continue; wrap_elf "$f"; done; fi
for natdir in /workspace/test-run/tests-image/hotspot/jtreg/native /workspace/test-run/tests-image/jdk/jtreg/native /workspace/test-run/tests-image/lib-test/jtreg/native; do
  [ -d "$natdir" ] && find "$natdir" -type f -executable | while read f; do echo "$f" | grep -q '\.real$' && continue; wrap_elf "$f"; done
done

# Guard: source and JDK under test must both be JDK 25.
SRC_VER=$(grep -m1 'DEFAULT_VERSION_FEATURE=' "$SRC_DIR/make/conf/version-numbers.conf" | grep -o '[0-9]*')
echo "Source JDK feature version: $SRC_VER"
[ "$SRC_VER" = "25" ] || { echo "ERROR: expected JDK 25 source, got $SRC_VER"; exit 2; }
JDK_VER_OUT=$("$JDK_DIR/bin/java" -version 2>&1) || true
echo "$JDK_VER_OUT"
echo "$JDK_VER_OUT" | grep -q 'version "25\.' || { echo "ERROR: JDK under test is not JDK 25"; exit 2; }

PROBLEM_LIST_SRC="$SRC_DIR/.github/riscv-ci/ProblemList-riscv64-qemu-usermode.txt"
PROBLEM_LIST=/workspace/test-run/ProblemList-riscv64-qemu-usermode.txt
cp "$PROBLEM_LIST_SRC" "$PROBLEM_LIST"
# Drop ProblemList entries whose test no longer exists in this source tree
# (stale paths would be handed to jtreg as unknown tests).
python3 - "$PROBLEM_LIST" "$SRC_DIR" <<'PY'
import os, sys
pl, root = sys.argv[1], sys.argv[2]
roots = [os.path.join(root, p) for p in ("test/hotspot/jtreg", "test/jdk",
                                        "test/langtools", "test/lib-test")]
keep, dropped = [], 0
for ln in open(pl):
    s = ln.strip()
    if not s or s.startswith('#'):
        keep.append(ln)
        continue
    t = s.split()[0].split('#')[0]
    if any(os.path.exists(os.path.join(r, t)) for r in roots):
        keep.append(ln)
    else:
        dropped += 1
open(pl, 'w').writelines(keep)
print("ProblemList: kept %d lines, dropped %d stale entries" % (len(keep), dropped))
PY

# Probe JVM_OPTIONS against the JDK under test and drop flags it does not know.
EFFECTIVE_JVM_OPTIONS="$JVM_OPTIONS"
for _ in 1 2 3 4 5 6 7 8; do
  if PROBE=$("$JDK_DIR/bin/java" $EFFECTIVE_JVM_OPTIONS -version 2>&1); then
    echo "=== JVM option probe OK ==="
    break
  fi
  BAD=$(printf '%s\n' "$PROBE" | sed -n "s/.*Unrecognized VM option '\([A-Za-z0-9_]*\)'.*/\1/p" | head -1)
  if [ -z "$BAD" ]; then
    echo "=== JVM option probe failed for a non-flag reason ==="
    printf '%s\n' "$PROBE"
    break
  fi
  echo "=== dropping unsupported JVM option: $BAD (not present in this JDK) ==="
  EFFECTIVE_JVM_OPTIONS=$(printf '%s' "$EFFECTIVE_JVM_OPTIONS" | sed "s/-XX:[+-]${BAD}//g")
done
echo "=== EFFECTIVE_JVM_OPTIONS=$EFFECTIVE_JVM_OPTIONS ==="
echo "=== RVA23 flag state after VM init ==="
"$JDK_DIR/bin/java" $EFFECTIVE_JVM_OPTIONS -XX:+PrintFlagsFinal -version 2>/dev/null \
  | grep -E ' (UseRVV|UseRVA23U64|UseZvkn|UseZacas|UseZabha|UseZihintpause|UseZalasr|UseZba|UseZbb|UseZbs) ' || true

cd "$SRC_DIR"
bash configure --openjdk-target=riscv64-unknown-linux-gnu --with-boot-jdk="$BOOT_JDK_HOME" \
  --with-sysroot="$SYSROOT_RV64" --with-jtreg="$JT_HOME" --with-gtest=/opt/gtest \
  --enable-headless-only --with-freetype=bundled \
  --with-cups-include="$SYSROOT_RV64/usr/include" \
  --with-fontconfig-include="$SYSROOT_RV64/usr/include" \
  --with-alsa-include="$SYSROOT_RV64/usr/include" \
  --with-x=no BUILD_CC=/usr/bin/gcc-12 BUILD_CXX=/usr/bin/g++-12

export JDK_IMAGE_DIR="$JDK_DIR"
export TEST_IMAGE_DIR=/workspace/test-run/tests-image
set +e
make test-prebuilt CONF="linux-riscv64-server-$DEBUG_LEVEL" LOG=info TEST="$TEST_TARGET" \
  JDK_IMAGE_DIR="$JDK_IMAGE_DIR" TEST_IMAGE_DIR="$TEST_IMAGE_DIR" \
  JTREG="JAVA_OPTIONS=$EFFECTIVE_JVM_OPTIONS -XX:-CreateCoredumpOnCrash;VERBOSE=fail,error,time;KEYWORDS=!headful&!intermittent;TIMEOUT_FACTOR=$TIMEOUT_FACTOR;JOBS=$JTREG_JOBS" \
  TEST_JOBS="$JTREG_JOBS" JTREG_EXTRA_PROBLEM_LISTS="$PROBLEM_LIST" \
  2>&1 | tee /tmp/test_output.log
MAKE_EXIT=$?
set -e
echo "make test-prebuilt exit=$MAKE_EXIT"

mkdir -p "$OUT_DIR"
cp /tmp/test_output.log "$OUT_DIR/" || true
cp -r build/run-test-prebuilt/test-results "$OUT_DIR/" || true
cp -r build/run-test-prebuilt/test-support "$OUT_DIR/" || true
if grep -q "TEST FAILURE" /tmp/test_output.log; then
  echo "=== TEST FAILURE DETECTED - exiting with error ==="
  grep -E "TEST RESULT:|Test results:" /tmp/test_output.log | tail -20 || true
  exit 1
fi
[ "$MAKE_EXIT" -eq 0 ] || { echo "=== make failed with $MAKE_EXIT ==="; exit "$MAKE_EXIT"; }
echo "=== All tests passed ==="
