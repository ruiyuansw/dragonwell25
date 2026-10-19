#!/usr/bin/env bash
# Cross-compile OpenJDK for riscv64 and package artifacts for the test jobs.
# Runs inside the openjdk-buildtest-ub2204 image with the checkout mounted at
# $SRC_DIR and a host directory mounted at $OUT_DIR.
set -euxo pipefail

SRC_DIR="${SRC_DIR:-/workspace/src}"
OUT_DIR="${OUT_DIR:-/workspace/out}"
DEBUG_LEVEL="${DEBUG_LEVEL:-release}"
BUILD_JOBS="${BUILD_JOBS:-28}"
BOOT_JDK="${BOOT_JDK:-/opt/boot-jdk-25}"

echo "=== Build env ==="
uname -a
riscv64-unknown-linux-gnu-gcc --version | head -1
qemu-riscv64 --version | head -1

cd "$SRC_DIR"
git log -1 --pretty=oneline 2>/dev/null || true

# The source and the boot JDK must both be JDK 25.
SRC_VER=$(grep -m1 'DEFAULT_VERSION_FEATURE=' make/conf/version-numbers.conf | grep -o '[0-9]*')
echo "Source JDK feature version: $SRC_VER"
[ "$SRC_VER" = "25" ] || { echo "ERROR: expected JDK 25 source, got $SRC_VER"; exit 2; }

echo "Selected Boot JDK: $BOOT_JDK"
"$BOOT_JDK/bin/java" -version 2>&1 | grep -q 'version "25\.' || {
  echo "ERROR: boot JDK is not JDK 25"; exit 2; }

bash configure \
  --openjdk-target=riscv64-unknown-linux-gnu \
  --with-boot-jdk="$BOOT_JDK" \
  --with-sysroot=/opt/xuantie-toolchain/sysroot \
  --with-jtreg=/opt/jtreg \
  --with-gtest=/opt/gtest \
  --enable-headless-only \
  --with-freetype=bundled \
  --with-cups-include=/opt/xuantie-toolchain/sysroot/usr/include \
  --with-x=/opt/xuantie-toolchain/sysroot/usr \
  --with-jvm-variants=server \
  --with-debug-level="$DEBUG_LEVEL" \
  --disable-warnings-as-errors \
  --with-extra-cflags='-Wa,-march=rv64gcv_zba_zbb_zbs' \
  BUILD_CC=/usr/bin/gcc-12 \
  BUILD_CXX=/usr/bin/g++-12

CONF="linux-riscv64-server-$DEBUG_LEVEL"
make CONF="$CONF" LOG=info images test-image JOBS="$BUILD_JOBS"

BUILD_DIR="build/$CONF"
mkdir -p "$OUT_DIR"
tar czf "$OUT_DIR/jdk-riscv64_bin.tar.gz" -C "${BUILD_DIR}/images" jdk
tar czf "$OUT_DIR/jdk-riscv64_bin-tests.tar.gz" -C "${BUILD_DIR}/images" test

# Pristine source for the test jobs (they each configure their own tree).
tar czf "$OUT_DIR/source.tar.gz" --exclude=./build --exclude=./.git -C "$SRC_DIR" .

ls -lh "$OUT_DIR"
sha256sum "$OUT_DIR"/*.tar.gz
echo "=== Build done ==="
