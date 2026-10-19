#!/usr/bin/env bash
# Run a targeted test list under QEMU system-mode (full RISC-V Linux guest).
# Inputs (env): SUITE (name of sysmode/<suite>.txt), JVM_OPTIONS, SMP, MEMORY
set -eux

SRC_DIR="${SRC_DIR:-/workspace/src}"
ART_DIR="${ART_DIR:-/workspace/artifacts}"
OUT_DIR="${OUT_DIR:-/workspace/out}"
SUITE="${SUITE:?SUITE is required}"
TEST_LIST="$SRC_DIR/.github/riscv-ci/sysmode/$SUITE.txt"
[ -f "$TEST_LIST" ] || { echo "ERROR: test list not found: $TEST_LIST"; exit 2; }

export WORKSPACE="${WORKSPACE:-/workspace}"
export BOOT_JDK_HOME="${BOOT_JDK_HOME:-/opt/boot-jdk-25}"
export XUANTIE_CPU="${XUANTIE_CPU:-xt-c9501fdvkmt}"
export DEBUG_LEVEL="${DEBUG_LEVEL:-release}"
export VM_TIMEOUT="${VM_TIMEOUT:-14400}"
export SMP="${SMP:-14}"
export MEMORY="${MEMORY:-28G}"
export SDK_URL="${SDK_URL:-http://11.122.130.22/release/Linux-SDK/XuanTie_V1.4.0-rc3/tarball/xuantie-linux-V1.4.0-rc3.tar.gz}"
# In system-mode V/Zvkn are auto-detected by the real kernel hwprobe; the
# explicit flag set keeps parity with user-mode and keeps intrinsics active.
export JVM_OPTIONS="${JVM_OPTIONS:--XX:+UnlockDiagnosticVMOptions -XX:+UnlockExperimentalVMOptions -XX:+UseRVV -XX:+UseRVA23U64 -XX:+UseZvkn -XX:+UseZacas -XX:+UseZabha -XX:+UseZihintpause}"

QEMU_SYSTEM=""
for dir in /opt/xuantie-qemu-devci /opt/xuantie-qemu; do
    if [ -x "$dir/bin/qemu-system-riscv64" ]; then QEMU_SYSTEM="$dir/bin/qemu-system-riscv64"; break; fi
done
[ -z "$QEMU_SYSTEM" ] && { echo "ERROR: qemu-system-riscv64 not found"; exit 1; }
echo "Using QEMU (system): $QEMU_SYSTEM"

IMG_DIR="${SYSIMG_DIR:-/opt/sysmode-images}"
if [ ! -f "$IMG_DIR/Image" ]; then
  IMG_DIR="$WORKSPACE/sysmode-images"
  mkdir -p "$IMG_DIR"
  echo "=== Downloading Xuantie Linux SDK images ==="
  cd /tmp
  export no_proxy="11.122.130.22,11.122.129.163,10.63.42.20,*.alibaba-inc.com"
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY || true
  wget --no-proxy -q -O sdk.tar.gz "$SDK_URL" || {
    echo "=== wget failed, retrying with curl ==="
    curl --noproxy '*' -sSfL -o sdk.tar.gz "$SDK_URL"
  }
  tar xzf sdk.tar.gz --strip-components=1 \
    archived/images-rva23/kernel/Image-6.6-rv64-kcdefault \
    archived/images-rva23/opensbi/fw_dynamic-v1.7-rv64.bin \
    archived/images-rva23/rootfs/rootfs.xuantie-image-rv64-6.6-lite.ext4
  rm -f "$IMG_DIR/Image" "$IMG_DIR/fw_dynamic.bin" "$IMG_DIR/rootfs.ext4"
  mv images-rva23/kernel/Image-6.6-rv64-kcdefault "$IMG_DIR/Image"
  mv images-rva23/opensbi/fw_dynamic-v1.7-rv64.bin "$IMG_DIR/fw_dynamic.bin"
  mv images-rva23/rootfs/rootfs.xuantie-image-rv64-6.6-lite.ext4 "$IMG_DIR/rootfs.ext4"
  rm -rf sdk.tar.gz images/ images-rva23/
fi
echo "=== SDK images: $IMG_DIR ==="

SHARE_DIR="$WORKSPACE/test-run"
mkdir -p "$SHARE_DIR" "$OUT_DIR"
cd "$SHARE_DIR"
tar xzf "$ART_DIR/jdk-riscv64_bin.tar.gz"
rm -rf jdk-image
mv jdk jdk-image
if [ -f "$ART_DIR/jdk-riscv64_bin-tests.tar.gz" ]; then
  rm -rf tests-image
  tar xzf "$ART_DIR/jdk-riscv64_bin-tests.tar.gz"
  rm -rf tests-image
  mv test tests-image
fi

SRC_VER=$(grep -m1 'DEFAULT_VERSION_FEATURE=' "$SRC_DIR/make/conf/version-numbers.conf" | grep -o '[0-9]*')
echo "Source JDK feature version: $SRC_VER"
[ "$SRC_VER" = "25" ] || { echo "ERROR: expected JDK 25 source, got $SRC_VER"; exit 2; }

# Copy source tree + jtreg into the shared dir for guest access.
cp -aL /opt/jtreg "$SHARE_DIR/jtreg" 2>/dev/null || true
rm -rf "$SHARE_DIR/OpenJDK"
cp -a "$SRC_DIR" "$SHARE_DIR/OpenJDK"
cp "$TEST_LIST" "$SHARE_DIR/testlist.txt"
echo "=== Test list ($SUITE): $(wc -l < "$SHARE_DIR/testlist.txt") entries ==="

# The guest-init heredoc is quoted, so hand JVM_OPTIONS over through a file.
printf '%s\n' "$JVM_OPTIONS" > "$SHARE_DIR/jvm_options.txt"
echo "=== JVM_OPTIONS handed to guest: $(cat "$SHARE_DIR/jvm_options.txt") ==="

cp "$IMG_DIR/rootfs.ext4" "$WORKSPACE/rootfs-work.ext4"
dd if=/dev/zero bs=1M count=3968 >> "$WORKSPACE/rootfs-work.ext4" 2>/dev/null
resize2fs "$WORKSPACE/rootfs-work.ext4" 2>/dev/null || (e2fsck -fy "$WORKSPACE/rootfs-work.ext4" && resize2fs "$WORKSPACE/rootfs-work.ext4") || true

cat > /tmp/guest-init.sh << 'GUEST_INIT'
#!/bin/sh
# Auto-init script for QEMU system-mode OpenJDK testing.
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

ip link set lo up
ip link set eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -t 10 2>/dev/null || true
echo "nameserver 10.0.2.3" > /etc/resolv.conf
echo "Network: $(ip addr show eth0 2>/dev/null | grep 'inet ' || echo 'no IP')"

export http_proxy="http://11.122.133.68:3128"
export https_proxy="http://11.122.133.68:3128"
export no_proxy="localhost,127.0.0.1"

mkdir -p /mnt/host
mount -t 9p -o trans=virtio,version=9p2000.L host_share /mnt/host

export PATH="/mnt/host/jdk-image/bin:/mnt/host/jtreg/bin:$PATH"
export JAVA_HOME="/mnt/host/jdk-image"
export JT_HOME="/mnt/host/jtreg"
export HOME=/root
mkdir -p /root /tmp

JVM_OPTIONS="$(cat /mnt/host/jvm_options.txt 2>/dev/null || echo '')"
echo "=== JVM_OPTIONS: $JVM_OPTIONS ==="

# This script runs as PID 1: ANY premature exit panics the kernel.
TEST_RC=99
cleanup() {
  echo "$TEST_RC" > /mnt/host/done_marker 2>/dev/null
  sync
  poweroff -f 2>/dev/null || reboot -f 2>/dev/null || echo o > /proc/sysrq-trigger 2>/dev/null
  while : ; do sleep 60; done
}
trap cleanup EXIT INT TERM

echo "=== Feature detection (verify V/Zvkn are seen by real hwprobe) ==="
java -XX:+UnlockDiagnosticVMOptions -XX:+UnlockExperimentalVMOptions \
     -XX:+UseRVV -XX:+UseZvkn -Xlog:os+cpu=info -version 2>&1 | grep -iE "feature|CPU:" || true

echo "=== Java version ==="
java -version 2>&1

TEST_ARGS=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  TEST_ARGS="$TEST_ARGS /mnt/host/OpenJDK/$t"
done < /mnt/host/testlist.txt
echo "=== Running $(echo $TEST_ARGS | wc -w) tests in system-mode ==="

cd /mnt/host
{ /mnt/host/jtreg/bin/jtreg \
  -jdk:/mnt/host/jdk-image \
  -verbose:fail,error,time \
  -timeout:100 \
  -concurrency:12 \
  -k:'!headful&!intermittent' \
  -w:/mnt/host/work \
  -r:/mnt/host/report \
  -ignore:quiet \
  -nativepath:/mnt/host/tests-image/hotspot/jtreg/native \
  -vmoptions:"$JVM_OPTIONS -XX:-CreateCoredumpOnCrash -Xmx1g" \
  $TEST_ARGS \
  ; echo $? > /tmp/jtreg.rc ; } 2>&1 | tee /mnt/host/test_output.log
TEST_RC="$(cat /tmp/jtreg.rc 2>/dev/null || echo 99)"

echo "=== Tests complete (jtreg rc=$TEST_RC) ==="
exit 0
GUEST_INIT
chmod +x /tmp/guest-init.sh

debugfs -w -R "write /tmp/guest-init.sh /guest-init.sh" "$WORKSPACE/rootfs-work.ext4" 2>/dev/null || {
  e2cp /tmp/guest-init.sh "$WORKSPACE/rootfs-work.ext4":/guest-init.sh 2>/dev/null || {
    echo "WARNING: Cannot inject init script into rootfs"
  }
}
debugfs -w -R "set_inode_field /guest-init.sh mode 0100755" "$WORKSPACE/rootfs-work.ext4" 2>/dev/null || true

echo "=== Starting QEMU system-mode ==="
timeout "$VM_TIMEOUT" $QEMU_SYSTEM \
  -machine virt \
  -cpu "${XUANTIE_CPU},sv57=off" \
  -smp "$SMP" \
  -m "$MEMORY" \
  -nographic \
  -bios "$IMG_DIR/fw_dynamic.bin" \
  -kernel "$IMG_DIR/Image" \
  -drive file="$WORKSPACE/rootfs-work.ext4",format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -append "root=/dev/vda rw console=ttyS0 earlycon=sbi init=/guest-init.sh no5lvl" \
  -virtfs local,path="$SHARE_DIR",mount_tag=host_share,security_model=none,id=host_share \
  -no-reboot \
  2>&1 | tee "$WORKSPACE/qemu-console.log" &

QEMU_PID=$!

set +x
RESULT_SEEN=""
while kill -0 $QEMU_PID 2>/dev/null; do
  [ -f "$SHARE_DIR/done_marker" ] && break
  if [ -f "$SHARE_DIR/test_output.log" ] && grep -q "Test results:" "$SHARE_DIR/test_output.log" 2>/dev/null; then
    [ -z "$RESULT_SEEN" ] && RESULT_SEEN=$(date +%s)
    if [ $(( $(date +%s) - RESULT_SEEN )) -ge 120 ]; then
      echo "=== jtreg finished but guest did not power off; forcing QEMU termination ==="
      pkill -f qemu-system-riscv64 2>/dev/null || true
      kill $QEMU_PID 2>/dev/null || true
      break
    fi
  fi
  sleep 10
done
for _ in $(seq 1 15); do kill -0 $QEMU_PID 2>/dev/null || break; sleep 2; done
pkill -f qemu-system-riscv64 2>/dev/null || true
set -x

kill $QEMU_PID 2>/dev/null || true

echo "=== Collecting results ==="
cp "$SHARE_DIR/test_output.log" "$OUT_DIR/" 2>/dev/null || true
cp -r "$SHARE_DIR/report" "$OUT_DIR/" 2>/dev/null || true
cp -r "$SHARE_DIR/work" "$OUT_DIR/" 2>/dev/null || true
cp "$WORKSPACE/qemu-console.log" "$OUT_DIR/" 2>/dev/null || true

grep -q 'version "25\.' "$WORKSPACE/qemu-console.log" || {
  echo "ERROR: guest JDK is not JDK 25"; tail -30 "$WORKSPACE/qemu-console.log"; exit 1; }
echo "=== Guest JDK 25 verified ==="

if [ ! -f "$SHARE_DIR/done_marker" ] && grep -q "Test results:" "$SHARE_DIR/test_output.log" 2>/dev/null; then
  echo "=== jtreg results found (guest did not power off; log-based verdict) ==="
  grep -E "Test results:" "$SHARE_DIR/test_output.log" | tail -3
  if grep -qE "failed: [1-9]|error: [1-9]" "$SHARE_DIR/test_output.log"; then
    echo "=== TEST FAILURE DETECTED (log-based) ==="
    exit 1
  fi
  echo "=== System-mode test DONE - ALL PASSED (log-based) ==="
  exit 0
fi
if [ -f "$SHARE_DIR/done_marker" ]; then
  MARKER_RC="$(cat "$SHARE_DIR/done_marker" 2>/dev/null || echo 99)"
  echo "=== jtreg rc from guest: $MARKER_RC ==="
  if [ "$MARKER_RC" != "0" ]; then
    echo "=== TEST FAILURE DETECTED (jtreg rc=$MARKER_RC) ==="
    grep -E "Test results:|Error:" "$SHARE_DIR/test_output.log" 2>/dev/null | tail -20 || true
    exit 1
  fi
  echo "=== QEMU console log tail ==="
  tail -30 "$WORKSPACE/qemu-console.log"
  if grep -q "Error: Some tests failed" "$WORKSPACE/qemu-console.log" || grep -q "TEST RESULT: Failed" "$WORKSPACE/qemu-console.log" || grep -q "TEST RESULT: Error" "$WORKSPACE/qemu-console.log"; then
    echo "=== TEST FAILURE DETECTED ==="
    grep -c "TEST RESULT: Failed" "$WORKSPACE/qemu-console.log" 2>/dev/null | xargs -I{} echo "Failed: {} tests"
    grep -c "TEST RESULT: Error" "$WORKSPACE/qemu-console.log" 2>/dev/null | xargs -I{} echo "Error: {} tests"
    exit 1
  fi
  echo "=== System-mode test DONE - ALL PASSED (skips are expected & OK) ==="
  exit 0
else
  echo "=== ERROR: Tests did not complete (no done_marker) ==="
  tail -50 "$WORKSPACE/qemu-console.log"
  exit 1
fi
