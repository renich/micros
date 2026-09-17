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

# Silence shellcheck for options used across roadmap phases
: "${SCREENDUMP}" "${SCREENSHOT}" "${MON_SOCK}" "${ISA_DEBUG}"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "ERROR: qemu-system-x86_64 not found."
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
INITRAMFS_DIR="$BUILD_DIR/initramfs"
CPIO_ARCHIVE="$BUILD_DIR/initramfs.cpio"
TMP_SERIAL="${SERIAL_LOG:-$(mktemp /tmp/micros-serial-XXXXXX.log)}"

# shellcheck disable=SC2329
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
elif [[ "$MODE" == "uefi" ]]; then
    OVMF_IMAGE=""
    for candidate in \
        "/usr/share/edk2/ovmf/OVMF_CODE.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd" \
        "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd" \
        "/usr/share/ovmf/OVMF.fd"; do
        if [[ -f "$candidate" ]]; then
            OVMF_IMAGE="$candidate"
            break
        fi
    done

    if [[ -z "$OVMF_IMAGE" ]]; then
        echo "ERROR: OVMF UEFI firmware image not found on host."
        exit 1
    fi

    if [[ "$EXPECT" == "Substrate self-test verified (Macros 20+22=42)" ]]; then
        EXPECT="MicrOS (uOS) Sovereign Genesis Actor Online"
    fi

    ESP_DIR="$BUILD_DIR/esp"
    mkdir -p "$ESP_DIR/EFI/BOOT"
    cp "$ROOT_DIR/zig-out/bin/boot.efi" "$ESP_DIR/EFI/BOOT/BOOTX64.EFI"

    QEMU_ARGS=(
        -m 512M
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_IMAGE"
        -drive "format=raw,file=fat:rw:$ESP_DIR"
        -netdev "user,id=net0"
        -device "virtio-net-pci,netdev=net0"
        -serial "file:$TMP_SERIAL"
        -display none
        -no-reboot
    )

    if [[ "$NO_KVM" -eq 0 && -w /dev/kvm ]]; then
        QEMU_ARGS+=(-enable-kvm)
    else
        QEMU_ARGS+=(-cpu max)
    fi

    if [[ -n "$SCREENDUMP" || -n "$SCREENSHOT" ]]; then
        rm -f "$MON_SOCK"
        QEMU_ARGS+=(-monitor "unix:$MON_SOCK,server,nowait")
    fi

    echo "[micros-runner] Launching QEMU UEFI harness (timeout: ${TIMEOUT_SEC}s)..."
    qemu-system-x86_64 "${QEMU_ARGS[@]}" &
    QEMU_PID=$!

    START_TIME=$(date +%s)
    DUMP_CAPTURED=0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        NOW=$(date +%s)
        ELAPSED=$((NOW - START_TIME))

        if [[ -n "$SCREENDUMP" && "$DUMP_CAPTURED" -eq 0 && -S "$MON_SOCK" ]]; then
            if grep -F "Visual canvas and vector status rendered successfully" "$TMP_SERIAL" >/dev/null 2>&1 || grep -F "Event loop terminated" "$TMP_SERIAL" >/dev/null 2>&1; then
                python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect('$MON_SOCK')
    time.sleep(0.1)
    s.sendall(b'screendump $SCREENDUMP\n')
    time.sleep(0.3)
    s.close()
except Exception:
    pass
" || true
                if [[ -f "$SCREENDUMP" && -s "$SCREENDUMP" ]]; then
                    DUMP_CAPTURED=1
                    echo "[micros-runner] Captured framebuffer screendump: $SCREENDUMP"
                fi
            fi
        fi

        if grep -F "Event loop terminated" "$TMP_SERIAL" >/dev/null 2>&1; then
            if [[ -n "$SCREENDUMP" && "$DUMP_CAPTURED" -eq 0 && -S "$MON_SOCK" ]]; then
                python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect('$MON_SOCK')
    time.sleep(0.1)
    s.sendall(b'screendump $SCREENDUMP\n')
    time.sleep(0.3)
    s.close()
except Exception:
    pass
" || true
                if [[ -f "$SCREENDUMP" && -s "$SCREENDUMP" ]]; then
                    DUMP_CAPTURED=1
                    echo "[micros-runner] Captured framebuffer screendump: $SCREENDUMP"
                fi
            fi
            break
        fi

        if [[ "$ELAPSED" -ge "$TIMEOUT_SEC" ]]; then
            echo "[micros-runner] Timeout reached (${TIMEOUT_SEC}s)."
            break
        fi
        sleep 0.2
    done

    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi

    if [[ -n "$SCREENSHOT" && -n "$SCREENDUMP" && -f "$SCREENDUMP" ]]; then
        if command -v magick >/dev/null 2>&1; then
            magick "$SCREENDUMP" "$SCREENSHOT"
        elif command -v convert >/dev/null 2>&1; then
            convert "$SCREENDUMP" "$SCREENSHOT"
        elif command -v pnmtopng >/dev/null 2>&1; then
            pnmtopng "$SCREENDUMP" > "$SCREENSHOT"
        fi
        echo "[micros-runner] Framebuffer screenshot saved: $SCREENSHOT"
    fi

    echo "--- QEMU UEFI Serial Console Output ---"
    cat "$TMP_SERIAL"
    echo "---------------------------------------"

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
else
    echo "[micros-runner] Mode '$MODE' not supported."
    exit 1
fi
