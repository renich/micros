#!/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

# micros-cluster.bash: Virtual Multi-Node P2P Cluster Mesh Orchestrator
# SPEC-TECH-P2P-001 / Milestone 37: Virtual Multi-Node P2P Cluster Mesh under QEMU.
# Interconnects independent MicrOS virtual machines via QEMU multicast socket networking.

MODE="interactive"
TIMEOUT_SEC=20
CLUSTER_PORT=12345
BUILD_DIR="build/cluster"
OVMF_PATH="/usr/share/edk2/ovmf/OVMF_CODE.fd"
NODE1_PID=""
NODE2_PID=""

if [[ ! -f "$OVMF_PATH" ]] && [[ -f "/usr/share/OVMF/OVMF_CODE.fd" ]]; then
    OVMF_PATH="/usr/share/OVMF/OVMF_CODE.fd"
fi

usage() {
    cat <<EOF
Usage: $0 [options]
Options:
  --mode [interactive|headless|verify]  Execution mode (default: interactive)
  --timeout <seconds>                   Verification timeout in seconds (default: 20)
  --port <port>                         Virtual mesh interconnect port (default: 12345)
  --mcast <addr>                        Ignored (legacy compatibility)
  --help                                Show this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --timeout) TIMEOUT_SEC="$2"; shift 2 ;;
        --port) CLUSTER_PORT="$2"; shift 2 ;;
        --mcast) shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    if [[ -n "${NODE1_PID:-}" ]] && kill -0 "$NODE1_PID" 2>/dev/null; then
        kill "$NODE1_PID" 2>/dev/null || true
        wait "$NODE1_PID" 2>/dev/null || true
    fi
    if [[ -n "${NODE2_PID:-}" ]] && kill -0 "$NODE2_PID" 2>/dev/null; then
        kill "$NODE2_PID" 2>/dev/null || true
        wait "$NODE2_PID" 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

prepare_node_env() {
    local node_id="$1"
    local node_dir="${BUILD_DIR}/node${node_id}"
    mkdir -p "${node_dir}/esp/EFI/BOOT"

    local efi_src="zig-out/bin/boot.efi"
    if [[ ! -f "$efi_src" ]]; then
        efi_src="build/esp/EFI/BOOT/BOOTX64.EFI"
    fi
    local mcb_src="src/kernel/genesis.mcb"
    if [[ ! -f "$mcb_src" ]]; then
        mcb_src="build/esp/genesis.mcb"
    fi
    cp "$efi_src" "${node_dir}/esp/EFI/BOOT/BOOTX64.EFI"
    cp "$mcb_src" "${node_dir}/esp/genesis.mcb"

    if [[ ! -f "${node_dir}/disk.raw" ]]; then
        truncate -s 64M "${node_dir}/disk.raw"
    fi
}

setup_cluster() {
    echo "=> Preparing dual-node virtual cluster environment..."
    mkdir -p "$BUILD_DIR"
    prepare_node_env 1
    prepare_node_env 2
}

run_verify() {
    setup_cluster
    local n1_log="${BUILD_DIR}/node1/serial.log"
    local n2_log="${BUILD_DIR}/node2/serial.log"
    rm -f "$n1_log" "$n2_log"

    echo "=> Spawning Node 1 (MAC 52:54:00:12:34:01, headless)..."
    qemu-system-x86_64 -enable-kvm -cpu host -m 512M \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_PATH" \
        -drive format=raw,file="fat:rw:${BUILD_DIR}/node1/esp" \
        -drive id=disk0,if=none,format=raw,file="${BUILD_DIR}/node1/disk.raw" \
        -device virtio-blk-pci,drive=disk0 \
        -netdev "socket,id=net0,listen=127.0.0.1:${CLUSTER_PORT}" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:01 \
        -display none \
        -serial file:"$n1_log" &
    NODE1_PID=$!

    sleep 0.5

    echo "=> Spawning Node 2 (MAC 52:54:00:12:34:02, headless)..."
    qemu-system-x86_64 -enable-kvm -cpu host -m 512M \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_PATH" \
        -drive format=raw,file="fat:rw:${BUILD_DIR}/node2/esp" \
        -drive id=disk0,if=none,format=raw,file="${BUILD_DIR}/node2/disk.raw" \
        -device virtio-blk-pci,drive=disk0 \
        -netdev "socket,id=net0,connect=127.0.0.1:${CLUSTER_PORT}" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:02 \
        -display none \
        -serial file:"$n2_log" &
    NODE2_PID=$!

    echo "=> Waiting for dual-node P2P mesh cluster startup (timeout: ${TIMEOUT_SEC}s)..."
    local start_time
    start_time=$(date +%s)
    local n1_ready=0
    local n2_ready=0
    local n1_discovered=0
    local n2_discovered=0

    while true; do
        local now
        now=$(date +%s)
        local elapsed=$((now - start_time))
        if (( elapsed > TIMEOUT_SEC )); then
            echo "[-] Error: Cluster startup timed out after ${TIMEOUT_SEC} seconds." >&2
            echo "--- Node 1 Serial Log ---" >&2
            tail -n 20 "$n1_log" 2>/dev/null || true
            echo "--- Node 2 Serial Log ---" >&2
            tail -n 20 "$n2_log" 2>/dev/null || true
            return 1
        fi

        if [[ -f "$n1_log" ]] && grep -q "P2P mesh discovery daemon active" "$n1_log" 2>/dev/null; then
            if (( n1_ready == 0 )); then
                echo "  [  ok  ] Node 1: P2P mesh daemon online & link-local IP configured"
                n1_ready=1
            fi
        fi

        if [[ -f "$n2_log" ]] && grep -q "P2P mesh discovery daemon active" "$n2_log" 2>/dev/null; then
            if (( n2_ready == 0 )); then
                echo "  [  ok  ] Node 2: P2P mesh daemon online & link-local IP configured"
                n2_ready=1
            fi
        fi

        if [[ -f "$n1_log" ]] && grep -q "Peer node discovered at.*192\.168\.100\.2" "$n1_log" 2>/dev/null; then
            if (( n1_discovered == 0 )); then
                echo "  [  ok  ] Node 1: Received UDP beacon & discovered peer 192.168.100.2 on virtual mesh"
                n1_discovered=1
            fi
        fi

        if [[ -f "$n2_log" ]] && grep -q "Peer node discovered at.*192\.168\.100\.1" "$n2_log" 2>/dev/null; then
            if (( n2_discovered == 0 )); then
                echo "  [  ok  ] Node 2: Received UDP beacon & discovered peer 192.168.100.1 on virtual mesh"
                n2_discovered=1
            fi
        fi

        if (( n1_ready == 1 && n2_ready == 1 && n1_discovered == 1 && n2_discovered == 1 )); then
            echo "=> Dual-node virtual P2P cluster mesh successfully established & verified!"
            return 0
        fi

        sleep 0.5
    done
}

run_interactive() {
    setup_cluster
    local n2_log="${BUILD_DIR}/node2/serial.log"
    rm -f "$n2_log"

    echo "=> Starting background Node 2 (MAC 52:54:00:12:34:02, log: ${n2_log})..."
    qemu-system-x86_64 -enable-kvm -cpu host -m 512M \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_PATH" \
        -drive format=raw,file="fat:rw:${BUILD_DIR}/node2/esp" \
        -drive id=disk0,if=none,format=raw,file="${BUILD_DIR}/node2/disk.raw" \
        -device virtio-blk-pci,drive=disk0 \
        -netdev "socket,id=net0,listen=127.0.0.1:${CLUSTER_PORT}" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:02 \
        -display none \
        -serial file:"$n2_log" &
    NODE2_PID=$!

    sleep 0.5

    echo "=> Starting interactive Node 1 (MAC 52:54:00:12:34:01, live display & serial)..."
    qemu-system-x86_64 -enable-kvm -cpu host -m 512M \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_PATH" \
        -drive format=raw,file="fat:rw:${BUILD_DIR}/node1/esp" \
        -drive id=disk0,if=none,format=raw,file="${BUILD_DIR}/node1/disk.raw" \
        -device virtio-blk-pci,drive=disk0 \
        -netdev "socket,id=net0,connect=127.0.0.1:${CLUSTER_PORT}" \
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:01 \
        -device virtio-vga,xres=1280,yres=800 \
        -display gtk,zoom-to-fit=on \
        -serial stdio
}

case "$MODE" in
    verify) run_verify ;;
    interactive|headless) run_interactive ;;
    *) echo "Unknown mode: $MODE" >&2; exit 1 ;;
esac
