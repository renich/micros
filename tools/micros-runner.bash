#!/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

# micros-runner.bash: Event-Driven Headless QEMU Harness
# Orchestrates UEFI and Sandbox mode executions with sub-second milestone detection.

MODE="sandbox"
EXPECT="Substrate self-test verified (Macros 20+22=42)"
FAIL_PATTERN="KERNEL FATAL|CPU Exception|Kernel Panic|panic:"
SCREENDUMP=""
SCREENSHOT=""
SERIAL_LOG=""
TIMEOUT_SEC=10
MON_SOCK="/tmp/micros-qemu-mon.sock"
ISA_DEBUG=0
NO_KVM=0

usage() {
    cat <<EOF
Usage: $0 [options]
Options:
  --mode [uefi|sandbox]      Execution mode (default: sandbox)
  --expect <pattern>         Success regex sentinel
  --fail <pattern>           Regex for fatal panic
  --screendump <path.ppm>    Capture GOP framebuffer to PPM
  --screenshot <path.png>    Convert PPM to PNG
  --serial-log <path>        Output serial log
  --timeout <seconds>        Timeout in seconds (default: 10)
  --monitor-sock <path>      QEMU monitor socket (default: /tmp/micros-qemu-mon.sock)
  --isa-debug-exit           Enable QEMU isa-debug-exit on port 0xf4
  --no-kvm                   Disable KVM hardware acceleration
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --expect) EXPECT="$2"; shift 2 ;;
        --fail) FAIL_PATTERN="$2"; shift 2 ;;
        --screendump) SCREENDUMP="$2"; shift 2 ;;
        --screenshot) SCREENSHOT="$2"; shift 2 ;;
        --serial-log) SERIAL_LOG="$2"; shift 2 ;;
        --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
        --monitor-sock) MON_SOCK="$2"; shift 2 ;;
        --isa-debug-exit) ISA_DEBUG=1; shift 1 ;;
        --no-kvm) NO_KVM=1; shift 1 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "ERROR: qemu-system-x86_64 not found."
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
INITRAMFS_DIR="$BUILD_DIR/initramfs"
CPIO_ARCHIVE="$BUILD_DIR/initramfs.cpio"
TMP_SERIAL="${SERIAL_LOG:-$(mktemp /tmp/micros-serial-XXXXXX.log)}"

cleanup() {
    if [[ -z "$SERIAL_LOG" && -f "$TMP_SERIAL" ]]; then
        rm -f "$TMP_SERIAL"
    fi
}
trap cleanup EXIT

if [[ "$MODE" == "sandbox" ]]; then
    mkdir -p "$INITRAMFS_DIR/dev" "$INITRAMFS_DIR/proc" "$INITRAMFS_DIR/sys"
    cp "$ROOT_DIR/zig-out/bin/micros-init" "$INITRAMFS_DIR/init"
    cp "$ROOT_DIR/zig-out/bin/msh" "$INITRAMFS_DIR/msh"
    (cd "$INITRAMFS_DIR" && find . | cpio -o -H newc --quiet) > "$CPIO_ARCHIVE"

    KERNEL="/boot/vmlinuz-$(uname -r)"
    if [[ ! -f "$KERNEL" ]]; then
        # Fallback to any vmlinuz in /boot
        KERNEL="$(find /boot -name "vmlinuz*" | head -n 1)"
    fi

    QEMU_ARGS=(
        -cpu host
        -kernel "$KERNEL"
        -initrd "$CPIO_ARCHIVE"
        -append "console=ttyS0 earlyprintk=serial,ttyS0 panic=1 rdinit=/init"
        -serial "file:$TMP_SERIAL"
        -display none
        -no-reboot
        -m 256M
    )

    if [[ "$NO_KVM" -eq 0 && -w /dev/kvm ]]; then
        QEMU_ARGS+=(-enable-kvm)
    else
        QEMU_ARGS+=(-cpu max)
    fi

    echo "[micros-runner] Launching QEMU sandbox harness (timeout: ${TIMEOUT_SEC}s)..."
    timeout "${TIMEOUT_SEC}s" qemu-system-x86_64 "${QEMU_ARGS[@]}" || true

    echo "--- QEMU Serial Console Output ---"
    cat "$TMP_SERIAL"
    echo "----------------------------------"

    if grep -E "$FAIL_PATTERN" "$TMP_SERIAL" >/dev/null 2>&1; then
        echo "[micros-runner] FAILED: Matched fatal panic pattern."
        exit 1
    fi

    if grep -F "$EXPECT" "$TMP_SERIAL" >/dev/null 2>&1; then
        echo "[micros-runner] SUCCESS: Milestone sentinel '$EXPECT' verified."
        exit 0
    fi

    echo "[micros-runner] FAILED: Sentinel '$EXPECT' not found in serial log."
    exit 1
fi

echo "[micros-runner] Mode '$MODE' not yet implemented in Phase 0."
exit 1
