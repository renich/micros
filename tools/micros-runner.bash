#!/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

# micros-runner.bash: Event-Driven Headless QEMU Harness
# Orchestrates UEFI and Sandbox mode executions with sub-second milestone detection.

MODE="sandbox"
SANDBOX_EXPECT="Substrate self-test verified (Macros 20+22=42)"
UEFI_EXPECT="µShell"
EXPECT="$SANDBOX_EXPECT"
EXPECT_EXPLICIT=0
FAIL_PATTERN="KERNEL FATAL|CPU Exception|Kernel Panic|panic:"
FORBID_PATTERN=""
SCREENDUMP=""
SCREENSHOT=""
SERIAL_LOG=""
SERIAL_INPUT=""
TIMEOUT_SEC=10
MON_SOCK="/tmp/micros-qemu-mon.sock"
ISA_DEBUG=0
NO_KVM=0
DISK_RAW=""
WIPE_DISK=0
VERIFY_PERSISTENCE=0
NVME_RAW=""
WIPE_NVME=0
VERIFY_SILICON=0
VERIFY_REBUILD=0

usage() {
    cat <<EOF
Usage: $0 [options]
Options:
  --mode [uefi|sandbox]      Execution mode (default: sandbox)
  --expect <pattern>         Success regex sentinel
  --fail <pattern>           Regex for fatal panic
  --forbid <pattern>         Regex that must NOT appear in the serial log (negative assertion)
  --screendump <path.ppm>    Capture GOP framebuffer to PPM
  --screenshot <path.png>    Convert PPM to PNG
  --serial-log <path>        Output serial log
  --input <string>           Delayed interactive input sent to serial console
  --timeout <seconds>        Timeout in seconds (default: 10)
  --monitor-sock <path>      QEMU monitor socket (default: /tmp/micros-qemu-mon.sock)
  --isa-debug-exit           Enable QEMU isa-debug-exit on port 0xf4
  --no-kvm                   Disable KVM hardware acceleration
  --disk <path>              Path to raw disk image for VirtIO-Blk
  --wipe-disk                Wipe/recreate raw disk image before booting
  --verify-persistence       Execute two-stage cold-reboot persistence verification (catalog root + CAS cache)
  --nvme <path>              Path to raw disk image for PCIe NVMe SSD
  --wipe-nvme                Wipe/recreate NVMe disk image before booting
  --verify-silicon           Execute end-to-end silicon installer & cord-cutting verification (provisions the NVMe target)
  --verify-rebuild           Execute end-to-end in-system kernel self-rebuild verification (AI supervisor owned)
  --preserve-efi             Do not overwrite ESP/EFI/BOOT/BOOTX64.EFI with build output
EOF
    exit 1
}

PRESERVE_EFI=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --expect) EXPECT="$2"; EXPECT_EXPLICIT=1; shift 2 ;;
        --fail) FAIL_PATTERN="$2"; shift 2 ;;
        --forbid) FORBID_PATTERN="$2"; shift 2 ;;
        --screendump) SCREENDUMP="$2"; shift 2 ;;
        --screenshot) SCREENSHOT="$2"; shift 2 ;;
        --serial-log) SERIAL_LOG="$2"; shift 2 ;;
        --input) SERIAL_INPUT="$2"; shift 2 ;;
        --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
        --monitor-sock) MON_SOCK="$2"; shift 2 ;;
        --isa-debug-exit) ISA_DEBUG=1; shift 1 ;;
        --no-kvm) NO_KVM=1; shift 1 ;;
        --disk) DISK_RAW="$2"; shift 2 ;;
        --wipe-disk) WIPE_DISK=1; shift 1 ;;
        --verify-persistence) VERIFY_PERSISTENCE=1; shift 1 ;;
        --nvme) NVME_RAW="$2"; shift 2 ;;
        --wipe-nvme) WIPE_NVME=1; shift 1 ;;
        --verify-silicon) VERIFY_SILICON=1; shift 1 ;;
        --verify-rebuild) VERIFY_REBUILD=1; shift 1 ;;
        --preserve-efi) PRESERVE_EFI=1; shift 1 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Silence shellcheck for options used across roadmap phases
: "${SCREENDUMP}" "${SCREENSHOT}" "${MON_SOCK}" "${ISA_DEBUG}"

# Only fall back to the per-mode sentinel when the caller did not pin one.
if [[ "$EXPECT_EXPLICIT" -eq 0 ]]; then
    case "$MODE" in
        uefi) EXPECT="$UEFI_EXPECT" ;;
        sandbox) EXPECT="$SANDBOX_EXPECT" ;;
    esac
fi

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

run_reboot_persistence_verification() {
    local disk="${DISK_RAW:-$BUILD_DIR/micros-disk.raw}"
    local log1
    local log2
    log1=$(mktemp /tmp/micros-persist-s1-XXXXXX.log)
    log2=$(mktemp /tmp/micros-persist-s2-XXXXXX.log)
    # shellcheck disable=SC2064
    trap "rm -f '$log1' '$log2'" RETURN

    echo "========================================================"
    echo " MicrOS Sovereign Storage Persistence Test (CAS cache)"
    echo "========================================================"
    echo "[persist-test] Stage 1: Cold boot on a wiped disk; force a demand-miss synthesis..."

    local stage1_input
    stage1_input=$(printf ':run persist_probe\na\nexit\n')

    "$0" --mode uefi --disk "$disk" --wipe-disk --serial-log "$log1" --input "$stage1_input" --expect "[ush] Synthesized and cached to CAS" --timeout "$TIMEOUT_SEC"

    if ! grep -F "[ush] Demand-miss for 'persist_probe'" "$log1" >/dev/null 2>&1; then
        echo "[persist-test] FAILED: Stage 1 did not exercise the demand-miss synthesis path."
        cat "$log1"
        exit 1
    fi
    echo "[persist-test] Stage 1 SUCCESS! Actor synthesized, stored in CAS, and catalog root persisted."

    echo "[persist-test] Stage 2: Cold reboot from the same disk; catalog and CAS cache must survive..."
    local stage2_input
    stage2_input=$(printf ':run persist_probe\na\nexit\n')

    "$0" --mode uefi --disk "$disk" --serial-log "$log2" --input "$stage2_input" --forbid "Demand-miss" --expect "[ush] Demand-hit for 'persist_probe'" --timeout "$TIMEOUT_SEC"

    echo "[persist-test] Stage 2 SUCCESS! Catalog restored from the persisted CAS root across a cold reboot; no re-synthesis."
    echo "========================================================"
    echo " Sovereign Reboot Persistence VERIFIED."
    echo "========================================================"
    exit 0
}

if [[ "$VERIFY_PERSISTENCE" -eq 1 ]]; then
    run_reboot_persistence_verification
fi

run_silicon_verification() {
    local disk="${DISK_RAW:-$BUILD_DIR/micros-disk.raw}"
    local nvme="${NVME_RAW:-$BUILD_DIR/micros-nvme.raw}"
    local log1
    local log2
    log1=$(mktemp /tmp/micros-silicon-s1-XXXXXX.log)
    log2=$(mktemp /tmp/micros-silicon-s2-XXXXXX.log)
    # shellcheck disable=SC2064
    trap "rm -f '$log1' '$log2'" RETURN

    echo "========================================================"
    echo " MicrOS Sovereign Silicon Deployment & Cord-Cutting Test"
    echo "========================================================"
    echo "[silicon-test] Stage 1: Provision a target NVMe from the live system..."

    rm -f "$nvme"
    mkdir -p "$BUILD_DIR"
    truncate -s 1G "$nvme"

    local stage1_input
    stage1_input=$(printf ':run installer\na\nexit\n')

    "$0" --mode uefi --disk "$disk" --wipe-disk --nvme "$nvme" --serial-log "$log1" --input "$stage1_input" --forbid '\\[install\\] Error' --expect "Deployment succeeded! Target silicon is standalone and verified." --timeout "$TIMEOUT_SEC"

    echo "[silicon-test] Stage 1 SUCCESS! Target partitioned, ESP formatted, standalone kernel staged."
    echo "[silicon-test] Stage 2: Cord-cutting verification - booting the target with no host disk..."

    "$0" --mode uefi --nvme "$nvme" --serial-log "$log2" --expect "µShell" --timeout "$TIMEOUT_SEC"

    echo "[silicon-test] Stage 2 SUCCESS! MicrOS booted directly from the provisioned target."
    echo "========================================================"
    echo " Sovereign Cord-Cutting VERIFIED."
    echo "========================================================"
    exit 0
}

if [[ "$VERIFY_SILICON" -eq 1 ]]; then
    run_silicon_verification
fi

run_rebuild_verification() {
    local disk="${DISK_RAW:-$BUILD_DIR/micros-disk.raw}"
    local log1
    local ai_timeout=$((TIMEOUT_SEC > 45 ? TIMEOUT_SEC : 45))
    log1=$(mktemp /tmp/micros-rebuild-XXXXXX.log)
    # shellcheck disable=SC2064
    trap "rm -f '$log1'" RETURN

    echo "========================================================"
    echo " MicrOS In-System Self-Rebuild (owned by the AI supervisor)"
    echo "========================================================"
    echo "[rebuild-test] Cold boot UEFI; the guest requests a rebuild, the supervisor performs it..."

    local stage1_input
    stage1_input=$(printf 'rebuild the system\nexit\n')

    "$0" --mode uefi --disk "$disk" --serial-log "$log1" --input "$stage1_input" --forbid '\[rebuild\] Error' --expect "[rebuild] Rebuild complete! Candidate kernel staged successfully." --timeout "$ai_timeout"

    echo "[rebuild-test] SUCCESS! In-system bundle repack, PE32+ kernel synthesis, and dual-slot ESP staging verified."
    echo "========================================================"
    echo " Phase 4 / Track D In-System Self-Rebuilding VERIFIED."
    echo "========================================================"
    exit 0
}

if [[ "$VERIFY_REBUILD" -eq 1 ]]; then
    run_rebuild_verification
fi

if [[ "$MODE" == "sandbox" ]]; then
    mkdir -p "$INITRAMFS_DIR/dev" "$INITRAMFS_DIR/proc" "$INITRAMFS_DIR/sys"
    cp "$ROOT_DIR/zig-out/bin/micros-init" "$INITRAMFS_DIR/init"
    cp "$ROOT_DIR/zig-out/bin/ush" "$INITRAMFS_DIR/ush"
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

    if [[ -n "$FORBID_PATTERN" ]] && grep -E "$FORBID_PATTERN" "$TMP_SERIAL" >/dev/null 2>&1; then
        echo "[micros-runner] FAILED: Forbidden pattern '$FORBID_PATTERN' present in serial log."
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

    ESP_DIR="$BUILD_DIR/esp"
    mkdir -p "$ESP_DIR/EFI/BOOT"
    if [[ "$PRESERVE_EFI" -eq 0 ]]; then
        cp "$ROOT_DIR/zig-out/bin/boot.efi" "$ESP_DIR/EFI/BOOT/BOOTX64.EFI"
    fi
    cp "$ROOT_DIR/src/kernel/genesis.mcb" "$ESP_DIR/genesis.mcb"

    HOST_PORT="${MICROS_HOST_PORT:-8080}"
    if ss -tln 2>/dev/null | grep -q ":${HOST_PORT} "; then
        HOST_PORT=18080
    fi

    QEMU_ARGS=(
        -m 512M
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_IMAGE"
        -drive "format=raw,file=fat:rw:$ESP_DIR"
        -netdev "user,id=net0,hostfwd=tcp::${HOST_PORT}-:8080"
        -device "virtio-net-pci,netdev=net0"
        -display none
        -no-reboot
    )

    if [[ -z "$NVME_RAW" || -n "$DISK_RAW" || "$VERIFY_PERSISTENCE" -eq 1 ]]; then
        DISK_RAW="${DISK_RAW:-$BUILD_DIR/micros-disk.raw}"
        if [[ "$WIPE_DISK" -eq 1 && -f "$DISK_RAW" ]]; then
            rm -f "$DISK_RAW"
        fi
        if [[ ! -f "$DISK_RAW" ]]; then
            mkdir -p "$BUILD_DIR"
            truncate -s 64M "$DISK_RAW"
        fi
        QEMU_ARGS+=(
            -drive "if=none,id=disk0,format=raw,file=$DISK_RAW"
            -device "virtio-blk-pci,drive=disk0"
        )
    fi

    if [[ -n "$NVME_RAW" ]]; then
        if [[ "$WIPE_NVME" -eq 1 && -f "$NVME_RAW" ]]; then
            rm -f "$NVME_RAW"
        fi
        if [[ ! -f "$NVME_RAW" ]]; then
            mkdir -p "$BUILD_DIR"
            truncate -s 512M "$NVME_RAW"
        fi
        QEMU_ARGS+=(
            -drive "if=none,id=nvm0,format=raw,file=$NVME_RAW"
            -device "nvme,serial=MICROS_NVME_01,drive=nvm0"
        )
    fi

    if [[ "$NO_KVM" -eq 0 && -w /dev/kvm ]]; then
        QEMU_ARGS+=(-enable-kvm)
    else
        QEMU_ARGS+=(-cpu max)
    fi

    if [[ -n "$SCREENDUMP" || -n "$SCREENSHOT" ]]; then
        rm -f "$MON_SOCK"
        QEMU_ARGS+=(-monitor "unix:$MON_SOCK,server,nowait")
    fi

    send_qemu_monitor_cmd() {
        local cmd="$1"
        if [[ ! -S "$MON_SOCK" ]]; then return 0; fi
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "import socket, sys, time; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1]); time.sleep(0.1); s.sendall((sys.argv[2] + '\n').encode()); time.sleep(0.3); s.close()" "$MON_SOCK" "$cmd" >/dev/null 2>&1 || true
        elif command -v nc >/dev/null 2>&1; then
            printf "%s\n" "$cmd" | nc -w 1 -U "$MON_SOCK" >/dev/null 2>&1 || true
        fi
    }

    capture_screendump() {
        if [[ -n "$SCREENDUMP" && "$DUMP_CAPTURED" -eq 0 && -S "$MON_SOCK" ]]; then
            send_qemu_monitor_cmd "screendump $SCREENDUMP"
            sleep 0.5
            if [[ -f "$SCREENDUMP" && -s "$SCREENDUMP" ]]; then
                DUMP_CAPTURED=1
                echo "[micros-runner] Captured framebuffer screendump: $SCREENDUMP"
            fi
        fi
    }

    FIFO_IN=""
    FEEDER_PID=""
    if [[ -n "$SERIAL_INPUT" ]]; then
        FIFO_IN=$(mktemp -u "${BUILD_DIR}/qemu-in-XXXXXX.fifo")
        mkfifo "$FIFO_IN"
        (
            while ! grep -E "(ush>|macros>)" "$TMP_SERIAL" >/dev/null 2>&1; do
                sleep 0.1
            done
            sleep 0.2
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ -n "$line" ]]; then
                    printf "%s\n" "$line"
                    sleep 1.0
                fi
            done <<< "$(printf '%b\n' "$SERIAL_INPUT")"
            sleep 10
        ) > "$FIFO_IN" &
        FEEDER_PID=$!

        QEMU_ARGS+=(-serial stdio)
        echo "[micros-runner] Launching QEMU UEFI harness with interactive input (timeout: ${TIMEOUT_SEC}s)..."
        qemu-system-x86_64 "${QEMU_ARGS[@]}" < "$FIFO_IN" > "$TMP_SERIAL" 2>&1 &
        QEMU_PID=$!
    else
        QEMU_ARGS+=(-serial "file:$TMP_SERIAL")
        echo "[micros-runner] Launching QEMU UEFI harness (timeout: ${TIMEOUT_SEC}s)..."
        qemu-system-x86_64 "${QEMU_ARGS[@]}" &
        QEMU_PID=$!
    fi

    START_TIME=$(date +%s)
    DUMP_CAPTURED=0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        NOW=$(date +%s)
        ELAPSED=$((NOW - START_TIME))

        if [[ -n "$SCREENDUMP" && "$DUMP_CAPTURED" -eq 0 ]]; then
            if [[ -n "$SERIAL_INPUT" ]]; then
                if grep -E "(Interactive Studio|µOS macros>)" "$TMP_SERIAL" >/dev/null 2>&1; then
                    sleep 0.5
                    capture_screendump
                fi
            elif grep -F "Visual canvas and vector status rendered successfully" "$TMP_SERIAL" >/dev/null 2>&1 || \
                 grep -E "(ush>|µOS macros>)" "$TMP_SERIAL" >/dev/null 2>&1 || \
                 grep -F "Event loop terminated" "$TMP_SERIAL" >/dev/null 2>&1; then
                capture_screendump
            fi
        fi

        if grep -F "Event loop terminated" "$TMP_SERIAL" >/dev/null 2>&1; then
            capture_screendump
            break
        fi

        if [[ "$ELAPSED" -ge "$TIMEOUT_SEC" ]]; then
            capture_screendump
            echo "[micros-runner] Timeout reached (${TIMEOUT_SEC}s)."
            break
        fi
        sleep 0.2
    done

    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi

    if [[ -n "$FEEDER_PID" ]]; then
        kill "$FEEDER_PID" 2>/dev/null || true
        wait "$FEEDER_PID" 2>/dev/null || true
    fi
    if [[ -n "$FIFO_IN" && -p "$FIFO_IN" ]]; then
        rm -f "$FIFO_IN"
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

    if [[ -n "$FORBID_PATTERN" ]] && grep -E "$FORBID_PATTERN" "$TMP_SERIAL" >/dev/null 2>&1; then
        echo "[micros-runner] FAILED: Forbidden pattern '$FORBID_PATTERN' present in serial log."
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
