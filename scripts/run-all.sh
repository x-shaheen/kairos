#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="$REPO_ROOT/build/run-logs"
OUTPUT_DIR="$REPO_ROOT/build/iso"
ARTIFACTS_DIR="$REPO_ROOT/dist"
REPORT="$LOG_DIR/report.txt"
mkdir -p "$LOG_DIR" "$OUTPUT_DIR" "$ARTIFACTS_DIR"

echo "RUN START: $(date)" | tee "$LOG_DIR/run-start.txt"

# 1) Git status snapshot
echo "=== GIT SNAPSHOT ===" | tee "$REPORT"
git status --porcelain -b | tee "$LOG_DIR/git-status.txt" >> "$REPORT"

# 2) Environment snapshot
echo "=== ENVIRONMENT SNAPSHOT ===" | tee -a "$REPORT"
uname -a | tee "$LOG_DIR/uname.txt" >> "$REPORT"
cat /etc/os-release 2>/dev/null | tee "$LOG_DIR/os-release.txt" >> "$REPORT" || true
go version 2>/dev/null | tee "$LOG_DIR/go-version.txt" >> "$REPORT" || true
git --version 2>/dev/null | tee "$LOG_DIR/git-version.txt" >> "$REPORT" || true
docker --version 2>/dev/null | tee "$LOG_DIR/docker-version.txt" >> "$REPORT" || true
docker buildx version 2>/dev/null | tee "$LOG_DIR/buildx-version.txt" >> "$REPORT" || true
qemu-system-x86_64 --version 2>/dev/null | tee "$LOG_DIR/qemu-version.txt" >> "$REPORT" || true
echo "CPU cores: $(nproc)" | tee -a "$REPORT"
free -h | tee "$LOG_DIR/mem.txt" >> "$REPORT"
df -h . | tee "$LOG_DIR/disk.txt" >> "$REPORT"

# 3) Canonical build: use scripts/build-iso.sh which wraps make targets
echo "=== BUILD PHASE ===" | tee -a "$REPORT"
# Ensure required tools for scripts/build-iso.sh
for cmd in docker go make; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command $cmd not found. Aborting." | tee -a "$REPORT"
    exit 1
  fi
done

# Run the repo-provided ISO builder script (it runs make binaries and image build)
echo "Running scripts/build-iso.sh (this will: make binaries, make image-kairos-init, docker build images/Dockerfile, auroraboot container to build ISO)" | tee -a "$REPORT"
# Capture stdout/stderr to a log file
if ! ./scripts/build-iso.sh 2>&1 | tee "$LOG_DIR/build-iso.log"; then
  echo "ERROR: scripts/build-iso.sh failed. See $LOG_DIR/build-iso.log" | tee -a "$REPORT"
  exit 2
fi
echo "BUILD SCRIPT COMPLETED" | tee -a "$REPORT"

# Find generated ISO
ISO="$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2- || true)"
if [ -z "$ISO" ]; then
  echo "ERROR: No ISO found in $OUTPUT_DIR after build." | tee -a "$REPORT"
  exit 3
fi
echo "ISO produced: $ISO" | tee -a "$REPORT"

# 4) Quick sanity: list dist artifacts
echo "Dist contents:" | tee -a "$REPORT"
ls -la "$ARTIFACTS_DIR" | tee "$LOG_DIR/dist-list.txt" >> "$REPORT"

# 5) QEMU boot test
echo "=== QEMU BOOT TEST ===" | tee -a "$REPORT"
MEM=${MEMORY:-4096}
CPUS=${CPUS:-2}
DRIVE_SIZE=${DRIVE_SIZE:-20000}  # MB for install target
DRIVE_IMG="$LOG_DIR/target-disk.qcow2"
qemu-img create -f qcow2 "$DRIVE_IMG" "${DRIVE_SIZE}M" 2>&1 | tee "$LOG_DIR/qemu-img-create.log"

# Determine whether /dev/kvm exists
KVM_AVAILABLE=0
if [ -c /dev/kvm ]; then KVM_AVAILABLE=1; fi

QEMU_CMD=(qemu-system-x86_64 -m "$MEM" -smp "$CPUS" -drive file="$DRIVE_IMG",if=virtio,format=qcow2 -cdrom "$ISO" -boot d -serial mon:stdio -display none -rtc base=utc)
if [ "$KVM_AVAILABLE" -eq 1 ]; then
  QEMU_CMD+=( -enable-kvm )
else
  echo "WARN: /dev/kvm not available — qemu will run in emulation (slow)" | tee -a "$REPORT"
fi

# Provide networking (user) with ssh forward for convenience
QEMU_CMD+=( -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 )

echo "Starting QEMU. Console will stream to $LOG_DIR/qemu.console.log" | tee -a "$REPORT"
# Run QEMU and capture output for a limited time (e.g., 15 minutes) — user can adjust
timeout=${QEMU_TIMEOUT:-900}
# Launch QEMU in background, redirect console
"${QEMU_CMD[@]}" 2>&1 | tee "$LOG_DIR/qemu.console.log" & QEMU_PID=$!
echo "QEMU PID: $QEMU_PID" | tee -a "$REPORT"

echo "Waiting up to $timeout seconds for QEMU to boot..." | tee -a "$REPORT"
SECONDS=0
BOOT_OK=0
while [ "$SECONDS" -lt "$timeout" ]; do
  if grep -E --line-buffered -i "Kairos|kairos|login:|systemd|Started|Reached target|cloud-init" "$LOG_DIR/qemu.console.log" >/dev/null 2>&1; then
    BOOT_OK=1
    break
  fi
  sleep 3
done

if [ "$BOOT_OK" -eq 1 ]; then
  echo "QEMU boot appears to have produced useful console output; collecting logs." | tee -a "$REPORT"
else
  echo "ERROR: QEMU did not show expected boot output within $timeout seconds. Check $LOG_DIR/qemu.console.log" | tee -a "$REPORT"
  kill "$QEMU_PID" 2>/dev/null || true
  exit 4
fi

# Optional: leave QEMU running for interactive install; otherwise kill
if [ "${KEEP_QEMU:-0}" -eq 1 ]; then
  echo "KEEP_QEMU is set: leaving QEMU running as PID $QEMU_PID" | tee -a "$REPORT"
else
  echo "Stopping QEMU PID $QEMU_PID" | tee -a "$REPORT"
  kill "$QEMU_PID" || true
fi

echo "RUN COMPLETE: $(date)" | tee -a "$REPORT"
echo "Full logs in $LOG_DIR" | tee -a "$REPORT"
exit 0
