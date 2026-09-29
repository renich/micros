#!/usr/bin/bash
# ==============================================================================
# MicrOS (µOS) Autonomous Self-Rewrite Trial-Boot & Verdict Watchdog Harness
# Implements Stage 4 Phase 3 trial boot, calibrated watchdog deadline (P4-C1),
# fault pattern superset, and live dual-verdict verification (PASS and FAIL).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNNER="${REPO_ROOT}/tools/micros-runner.bash"
ESP_BOOT_DIR="${REPO_ROOT}/build/esp/EFI/BOOT"
TRIALS_DIR="${MICROS_TRIALS_DIR:-${REPO_ROOT}/.agents/trials}"
RFCS_DIR="${MICROS_RFCS_DIR:-${REPO_ROOT}/.agents/rfcs}"
TRIAL_LOG="/tmp/micros-trial.log"

mkdir -p "${TRIALS_DIR}"

FAIL_PATTERN="KERNEL FATAL|CPU Exception|Kernel Panic|panic:|vector-14|#UD|#GP|Unhandled Interrupt|FATAL:|PANIC:"
PRIMARY_SENTINEL="ush>"
SECONDARY_SENTINEL="Actor 1 (ush) online"

# Dynamic calibration defaults (P4-C1)
CALIBRATE=0
INDUCE_FAULT=0
TIMEOUT_SEC=15
CANDIDATE_FILE=""
RFC_ID=""
RAW_BOOT=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --calibrate              Execute 3 baseline boots to calibrate watchdog deadline (2x max)
  --stage <file.efi>       Stage candidate kernel image for trial boot
  --rfc <rfc-id>           Record STAGED/TRIAL/COMMITTED/ROLLED_BACK into the RFC lifecycle
  --raw-boot               Boot staged ESP via raw FAT image + direct QEMU (no vvfat/runner)
  --induce-fault           Simulate candidate corruption/fault to verify watchdog rollback
  --timeout <seconds>      Override watchdog deadline (default: calibrated 15s)
  -h, --help               Display this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --calibrate)     CALIBRATE=1; shift 1 ;;
        --stage)         CANDIDATE_FILE="$2"; shift 2 ;;
        --rfc)           RFC_ID="$2"; shift 2 ;;
        --raw-boot)      RAW_BOOT=1; shift 1 ;;
        --induce-fault)  INDUCE_FAULT=1; shift 1 ;;
        --timeout)       TIMEOUT_SEC="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1" >&2; usage ;;
    esac
done

calibrate_deadline() {
    echo "========================================================"
    echo " [trial-watchdog] Calibrating Dynamic Deadline (P4-C1)"
    echo "========================================================"
    local times=()
    local max_time="0"

    for i in 1 2 3; do
        echo "[trial-watchdog] Baseline boot ${i}/3..."
        local t0 t1 elapsed
        t0="$(date +%s%N)"
        "${RUNNER}" --mode uefi --no-kvm --expect "${PRIMARY_SENTINEL}" --timeout 15 >/dev/null 2>&1 || true
        t1="$(date +%s%N)"
        elapsed="$(echo "scale=3; (${t1} - ${t0}) / 1000000000" | bc)"
        echo "[trial-watchdog] Boot ${i} elapsed: ${elapsed}s"
        times+=("${elapsed}")
        if (( $(echo "${elapsed} > ${max_time}" | bc -l) )); then
            max_time="${elapsed}"
        fi
    done

    # Deadline = 2x max baseline elapsed (P4-C1)
    local calibrated
    calibrated="$(echo "scale=0; (${max_time} * 2 + 0.99) / 1" | bc)"
    if [[ "${calibrated}" -lt 10 ]]; then
        calibrated=10
    fi
    TIMEOUT_SEC="${calibrated}"
    echo "[trial-watchdog] Baseline max: ${max_time}s | Calibrated deadline (2x): ${TIMEOUT_SEC}s"
    echo "========================================================"
}

if [[ "${CALIBRATE}" -eq 1 ]]; then
    calibrate_deadline
fi

# Ensure UEFI boot artifacts exist
if [[ ! -f "${ESP_BOOT_DIR}/BOOTX64.EFI" ]]; then
    echo "[trial-watchdog] Building baseline UEFI image..."
    make -C "${REPO_ROOT}" uefi-boot >/dev/null 2>&1
fi

BACKUP_IMAGE="${ESP_BOOT_DIR}/BOOTX64.EFI.last_known_good"
if [[ ! -f "${BACKUP_IMAGE}" ]]; then
    cp -f "${ESP_BOOT_DIR}/BOOTX64.EFI" "${BACKUP_IMAGE}"
fi

# S4-F3: lifecycle state recording + TRIAL.DAT canary drive (harness side).
# The RFC JSON is the lifecycle system of record past THAWED; TRIAL.DAT in
# the staged ESP is the file-level canary (read by rebuild.zig interop and,
# in M42, by descriptor-driven slot selection at boot).
rfc_set_state() {
    local new_state="$1"
    local extra_json="{}"
    if [[ $# -ge 2 && -n "$2" ]]; then extra_json="$2"; fi
    [[ -n "${RFC_ID}" ]] || return 0
    local rfc_file="${RFCS_DIR}/${RFC_ID}.json"
    [[ -f "${rfc_file}" ]] || { echo "[trial-watchdog] warning: RFC ${RFC_ID} not found; skipping state record" >&2; return 0; }
    if jq --arg s "${new_state}" --argjson x "${extra_json}" \
       '.state = $s | .trial = ((.trial // {}) + $x)' \
       "${rfc_file}" > "${rfc_file}.tmp"; then
        mv "${rfc_file}.tmp" "${rfc_file}"
        echo "[trial-watchdog] RFC ${RFC_ID} entered state: ${new_state}"
    else
        echo "[trial-watchdog] ERROR: failed to record state ${new_state} into ${rfc_file}" >&2
        return 1
    fi
}

drive_canary() {
    printf '%s' "$1" > "${ESP_BOOT_DIR}/TRIAL.DAT"
    echo "[trial-watchdog] TRIAL.DAT canary set to '$1' in staged ESP"
}

# Staging phase
if [[ "${INDUCE_FAULT}" -eq 1 ]]; then
    echo "[trial-watchdog] Inducing deliberate fault in candidate image..."
    # Corrupt entry point instructions to trigger UD2 (#UD exception)
    cp -f "${BACKUP_IMAGE}" "${ESP_BOOT_DIR}/BOOTX64.EFI"
    printf '\x0F\x0B\x0F\x0B' | dd of="${ESP_BOOT_DIR}/BOOTX64.EFI" seek=111856 bs=1 conv=notrunc 2>/dev/null
elif [[ -n "${CANDIDATE_FILE}" && -f "${CANDIDATE_FILE}" ]]; then
    echo "[trial-watchdog] Staging candidate image: ${CANDIDATE_FILE}"
    cp -f "${CANDIDATE_FILE}" "${ESP_BOOT_DIR}/BOOTX64.EFI"
fi
drive_canary "1"
rfc_set_state "STAGED" "$(jq -n --arg i "$(basename "${ESP_BOOT_DIR}/BOOTX64.EFI")" --arg h "$(sha256sum "${ESP_BOOT_DIR}/BOOTX64.EFI" | awk '{print $1}')" '{image:$i,sha256:$h}')" || exit 1

echo "[trial-watchdog] Launching QEMU UEFI trial boot (deadline: ${TIMEOUT_SEC}s, sentinel: '${PRIMARY_SENTINEL}')..."
rm -f "${TRIAL_LOG}"
rfc_set_state "TRIAL" "{}" || exit 1

# Portable raw-image boot (sandboxes without writable /var/tmp for vvfat).
# Builds a FAT image from the staged ESP dir and boots it directly; the
# verdict/sentinel/fault logic below is identical for both boot modes.
run_qemu_raw() {
    local log_path="${1:-${TRIAL_LOG}}"
    local esp_dir="${REPO_ROOT}/build/esp"
    local img="/tmp/micros-trial-esp.raw"
    local ovmf=""
    for c in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
        if [[ -f "${c}" ]]; then ovmf="${c}"; break; fi
    done
    [[ -n "${ovmf}" ]] || { echo "[trial-watchdog] error: OVMF image not found" >&2; return 1; }
    mkdir -p "${esp_dir}/EFI/BOOT"
    cp -f "${REPO_ROOT}/src/kernel/genesis.mcb" "${esp_dir}/genesis.mcb"
    rm -f "${img}"
    dd if=/dev/zero of="${img}" bs=1M count=64 status=none
    mkfs.vfat -F 32 "${img}" >/dev/null
    mmd -i "${img}" ::/EFI ::/EFI/BOOT
    mcopy -i "${img}" "${esp_dir}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "${img}" "${esp_dir}/genesis.mcb" ::/genesis.mcb
    if [[ -f "${esp_dir}/EFI/BOOT/TRIAL.DAT" ]]; then
        mcopy -i "${img}" "${esp_dir}/EFI/BOOT/TRIAL.DAT" ::/EFI/BOOT/TRIAL.DAT
    fi
    timeout "${TIMEOUT_SEC}s" qemu-system-x86_64 -m 512M \
        -drive "if=pflash,format=raw,readonly=on,file=${ovmf}" \
        -drive "format=raw,file=${img}" \
        -netdev "user,id=net0" -device "virtio-net-pci,netdev=net0" \
        -display none -no-reboot -cpu max \
        -serial "file:${log_path}" >/dev/null 2>&1 || true
    # Verdict inputs are the serial log contents; exit status is informational.
    return 0
}

# Confirm-boot after verdict: boots current ESP and checks the sentinel.
# Returns 0 only when the sentinel is present (explicit; never assumed).
confirm_boot_ok() {
    local clog="/tmp/micros-trial-confirm.log"
    rm -f "${clog}"
    if [[ "${RAW_BOOT}" -eq 1 ]]; then
        run_qemu_raw "${clog}"
    else
        "${RUNNER}" --mode uefi --no-kvm --preserve-efi --timeout "${TIMEOUT_SEC}" --serial-log "${clog}" >/dev/null 2>&1 || true
    fi
    grep -q -E "(${PRIMARY_SENTINEL}|${SECONDARY_SENTINEL})" "${clog}"
}

RUNNER_EXIT=0
if [[ "${RAW_BOOT}" -eq 1 ]]; then
    run_qemu_raw
else
    "${RUNNER}" --mode uefi --no-kvm --preserve-efi --expect "${PRIMARY_SENTINEL}" --fail "${FAIL_PATTERN}" --timeout "${TIMEOUT_SEC}" --serial-log "${TRIAL_LOG}" >/dev/null 2>&1 || RUNNER_EXIT=$?
fi

echo "========================================================"
echo "          TRIAL BOOT VERDICT EVALUATION"
echo "========================================================"

# Check for fault pattern matches
if grep -E "${FAIL_PATTERN}" "${TRIAL_LOG}" >/dev/null 2>&1; then
    fault_line="$(grep -E "${FAIL_PATTERN}" "${TRIAL_LOG}" | head -n 1)"
    echo "[trial-watchdog] VERDICT: FAIL (Fault detected: ${fault_line})"
    echo "[trial-watchdog] Initiating automated fail-safe rollback to last-known-good..."
    cp -f "${BACKUP_IMAGE}" "${ESP_BOOT_DIR}/BOOTX64.EFI"
    drive_canary "0"

    timestamp="$(date +%s)"
    fail_archive="${TRIALS_DIR}/trial-fail-${timestamp}.log"
    cp -f "${TRIAL_LOG}" "${fail_archive}"
    echo "[trial-watchdog] Failure transcript preserved in: ${fail_archive}"
    rfc_set_state "ROLLED_BACK" "$(jq -n --arg a "$(basename "${fail_archive}")" --arg f "$(printf '%s' "${fault_line}" | head -c 120)" '{archive:$a,fault:$f}')" || echo "[trial-watchdog] warning: ROLLED_BACK ledger record failed (rollback itself complete)" >&2
    
    echo "[trial-watchdog] Confirming rollback via clean reboot..."
    if confirm_boot_ok; then
        echo "[trial-watchdog] Rollback CONFIRMED: Last-known-good boot identity restored."
    else
        echo "[trial-watchdog] ROLLBACK UNCONFIRMED: confirm boot missed sentinel" >&2
    fi
    exit 1
fi

# Check for timeout or sentinel miss (check primary or secondary sentinel)
if [[ "${RUNNER_EXIT}" -ne 0 ]] || (! grep -F "${PRIMARY_SENTINEL}" "${TRIAL_LOG}" >/dev/null 2>&1 && ! grep -F "${SECONDARY_SENTINEL}" "${TRIAL_LOG}" >/dev/null 2>&1); then
    echo "[trial-watchdog] VERDICT: FAIL (Watchdog timeout or sentinel miss within ${TIMEOUT_SEC}s)"
    echo "[trial-watchdog] Initiating automated fail-safe rollback to last-known-good..."
    cp -f "${BACKUP_IMAGE}" "${ESP_BOOT_DIR}/BOOTX64.EFI"
    drive_canary "0"

    timestamp="$(date +%s)"
    fail_archive="${TRIALS_DIR}/trial-fail-${timestamp}.log"
    cp -f "${TRIAL_LOG}" "${fail_archive}"
    echo "[trial-watchdog] Failure transcript preserved in: ${fail_archive}"
    rfc_set_state "ROLLED_BACK" "$(jq -n --arg a "$(basename "${fail_archive}")" '{archive:$a,fault:"timeout-or-sentinel-miss"}')" || echo "[trial-watchdog] warning: ROLLED_BACK ledger record failed (rollback itself complete)" >&2
    
    echo "[trial-watchdog] Confirming rollback via clean reboot..."
    if confirm_boot_ok; then
        echo "[trial-watchdog] Rollback CONFIRMED: Last-known-good boot identity restored."
    else
        echo "[trial-watchdog] ROLLBACK UNCONFIRMED: confirm boot missed sentinel" >&2
    fi
    exit 1
fi

# Passing trial
echo "[trial-watchdog] VERDICT: PASS (Sentinel verified, 0 faults detected)"
echo "[trial-watchdog] Promoting candidate: Updating last-known-good backup..."
cp -f "${ESP_BOOT_DIR}/BOOTX64.EFI" "${BACKUP_IMAGE}"
drive_canary "0"

timestamp="$(date +%s)"
pass_archive="${TRIALS_DIR}/trial-pass-${timestamp}.log"
cp -f "${TRIAL_LOG}" "${pass_archive}"
echo "[trial-watchdog] Successful trial transcript archived in: ${pass_archive}"
rfc_set_state "COMMITTED" "$(jq -n --arg a "$(basename "${pass_archive}")" '{archive:$a}')" || echo "[trial-watchdog] warning: COMMITTED ledger record failed (verdict PASS stands, archive preserved)" >&2
echo "========================================================"
exit 0
