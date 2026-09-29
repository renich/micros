#!/usr/bin/bash
# ==============================================================================
# MicrOS (µOS) Autonomous Self-Rewrite RFC Lifecycle & Empirical Gate Harness
# Implements Stage 4 Phase 2 RFC state machine, G-perf/G-fault/G-tail gates,
# and harness-side human-thaw token verification (P4-C3/P4-C4).
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RFCS_DIR="${MICROS_RFCS_DIR:-${REPO_ROOT}/.agents/rfcs}"
THAW_FLAG_PATH="/tmp/micros-rfc-thaw.flag"

mkdir -p "${RFCS_DIR}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  propose <file.json>   Register and validate a new candidate RFC (state: PROPOSED)
  gate <rfc-id>         Execute empirical gates: G-perf, G-fault, G-tail (state: FROZEN)
  thaw <rfc-id>         Verify and consume host thaw token (state: THAWED)
  status <rfc-id>       Display RFC lifecycle and empirical gate status
EOF
    exit 1
}

cmd_propose() {
    local rfc_file="${1:-}"
    [[ -n "${rfc_file}" && -f "${rfc_file}" ]] || { echo "error: valid RFC JSON file required" >&2; exit 1; }

    local rfc_id
    rfc_id="$(jq -r '.id // empty' "${rfc_file}")"
    [[ -n "${rfc_id}" ]] || { echo "error: RFC JSON missing .id field" >&2; exit 1; }

    local target_file="${RFCS_DIR}/${rfc_id}.json"
    jq '.state = "PROPOSED" | .gates.G_perf.status = "PENDING" | .gates.G_fault.status = "PENDING" | .gates.G_tail.status = "PENDING"' "${rfc_file}" > "${target_file}"
    echo "[rfc-gate] RFC ${rfc_id} registered in state: PROPOSED (${target_file})"
}

median_of_3() {
    printf "%s\n" "$1" "$2" "$3" | sort -n | sed -n '2p'
}

mark_rejected() {
    local rfc_file="$1" gate="$2" reason="$3"
    if jq --arg g "${gate}" --arg r "${reason}" \
       '.state = "REJECTED" | .gates[$g].status = "FAIL" | .gates[$g].reason = $r' \
       "${rfc_file}" > "${rfc_file}.tmp"; then
        mv "${rfc_file}.tmp" "${rfc_file}"
        echo "[rfc-gate] GATES FAILED at ${gate}: ${reason}. RFC entered state: REJECTED" >&2
    else
        echo "[rfc-gate] GATES FAILED at ${gate}: ${reason}. ERROR: REJECTED state write failed" >&2
    fi
    exit 1
}

cmd_gate() {
    local rfc_id="${1:-}"
    [[ -n "${rfc_id}" ]] || { echo "error: RFC ID required" >&2; exit 1; }

    local rfc_file="${RFCS_DIR}/${rfc_id}.json"
    [[ -f "${rfc_file}" ]] || { echo "error: RFC ${rfc_id} not found in ${RFCS_DIR}" >&2; exit 1; }

    local baseline_file="${REPO_ROOT}/tools/rfcs-baseline.json"
    [[ -f "${baseline_file}" ]] || { echo "error: baseline ${baseline_file} missing; measure and commit it first" >&2; exit 1; }
    local base_ns
    base_ns="$(jq -r '.ns_per_switch // empty' "${baseline_file}")"
    [[ -n "${base_ns}" ]] || { echo "error: baseline file lacks .ns_per_switch" >&2; exit 1; }

    local perf_target
    perf_target="$(jq -r '.perf_target // false' "${rfc_file}")"

    echo "========================================================"
    echo "  Executing Empirical Verification Gates for ${rfc_id}"
    echo "========================================================"

    # Gate 1: G-perf (median-of-3 fiber latency vs committed baseline).
    # perf_target=true  -> require >=5% improvement (delta <= -5.0%).
    # perf_target=false -> require no regression (delta < +1.0%).
    echo "[gate:G-perf] Running fiber benchmark median-of-3 (baseline: ${base_ns} ns)..."
    local b1 b2 b3 bench_out
    bench_out="$("${REPO_ROOT}/tools/micros-fiber-bench" 2>&1)"
    echo "${bench_out}"
    b1="$(echo "${bench_out}" | grep -E "Latency/Switch" | awk '{print $4}')"
    b2="$("${REPO_ROOT}/tools/micros-fiber-bench" 2>&1 | grep -E "Latency/Switch" | awk '{print $4}')"
    b3="$("${REPO_ROOT}/tools/micros-fiber-bench" 2>&1 | grep -E "Latency/Switch" | awk '{print $4}')"
    [[ -n "${b1}" && -n "${b2}" && -n "${b3}" ]] || mark_rejected "${rfc_file}" "G_perf" "benchmark parse failure"
    local cand_ns delta_pct
    cand_ns="$(median_of_3 "${b1}" "${b2}" "${b3}")"
    delta_pct="$(awk "BEGIN {printf \"%.3f\", (${cand_ns} - ${base_ns}) / ${base_ns} * 100}")"
    echo "[gate:G-perf] Baseline: ${base_ns} ns | Candidate median-of-3: ${cand_ns} ns | Delta: ${delta_pct}%"
    if [[ "${perf_target}" == "true" ]]; then
        awk "BEGIN {exit !((${delta_pct} <= -5.0))}" \
            || mark_rejected "${rfc_file}" "G_perf" "improvement ${delta_pct}% weaker than -5.0% bound"
        echo "[gate:G-perf] PASS: improvement ${delta_pct}% meets -5.0% bound"
    else
        awk "BEGIN {exit !((${delta_pct} < 1.0))}" \
            || mark_rejected "${rfc_file}" "G_perf" "regression ${delta_pct}% breaches +1.0% bound"
        echo "[gate:G-perf] PASS: no regression (${delta_pct}% within +1.0% bound)"
    fi

    # Gate 2: G-fault (full test suite must exit 0 with pass == total).
    # ZIG_TEST_EXTRA_ARGS passthrough (default empty): lets sandboxed runs
    # redirect the global cache, e.g. --global-cache-dir /tmp/zig-cache-g.
    # It changes WHERE zig builds, never WHAT the gate asserts.
    # NOTE: script IFS is newline+tab (no space), so split explicitly.
    echo "[gate:G-fault] Running full test suite verification..."
    local test_out
    local -a zig_extra=()
    if [[ -n "${ZIG_TEST_EXTRA_ARGS:-}" ]]; then
        IFS=' ' read -ra zig_extra <<< "${ZIG_TEST_EXTRA_ARGS}"
    fi
    if ! test_out="$(cd "${REPO_ROOT}" && zig build test "${zig_extra[@]}" --summary all 2>&1)"; then
        echo "[gate:G-fault] failing zig output (tail):" >&2
        echo "${test_out}" | tail -n 15 >&2
        mark_rejected "${rfc_file}" "G_fault" "zig build test exited non-zero"
    fi
    local test_count
    test_count="$(echo "${test_out}" | grep -oE "[0-9]+/[0-9]+ tests passed" | tail -n 1 || true)"
    [[ -n "${test_count}" ]] || mark_rejected "${rfc_file}" "G_fault" "unparseable test summary"
    local pass_n total_n
    pass_n="$(echo "${test_count}" | cut -d/ -f1)"
    total_n="$(echo "${test_count}" | cut -d/ -f2 | awk '{print $1}')"
    [[ "${pass_n}" == "${total_n}" ]] || mark_rejected "${rfc_file}" "G_fault" "suite not fully green: ${test_count}"
    echo "[gate:G-fault] Test Suite: ${test_count} (PASS)"

    # Gate 3: G-tail (p99 tail latency bound <= 50.0 us, from Gate 1 run).
    local p99_us
    p99_us="$(echo "${bench_out}" | grep -E "Tail Latency p99" | awk '{print $6}')"
    [[ -n "${p99_us}" ]] || mark_rejected "${rfc_file}" "G_tail" "p99 parse failure"
    echo "[gate:G-tail] Measured p99 Tail Latency: ${p99_us} us (bound: <= 50.0 us)"
    if awk "BEGIN {exit !(${p99_us} <= 50.0)}"; then
        echo "[gate:G-tail] PASS: Tail latency within WCET bounds"
    else
        mark_rejected "${rfc_file}" "G_tail" "p99 ${p99_us}us exceeded 50.0us bound"
    fi

    jq --arg lat "${cand_ns}" --arg delta "${delta_pct}" --arg p99 "${p99_us}" --arg tc "${test_count}" \
       '.state = "FROZEN" |
        .gates.G_perf.status = "PASS" | .gates.G_perf.ns_per_switch = ($lat | tonumber) | .gates.G_perf.delta_pct = ($delta | tonumber) |
        .gates.G_fault.status = "PASS" | .gates.G_fault.tests = $tc |
        .gates.G_tail.status = "PASS" | .gates.G_tail.p99_us = ($p99 | tonumber)' \
       "${rfc_file}" > "${rfc_file}.tmp" && mv "${rfc_file}.tmp" "${rfc_file}"
    echo "========================================================"
    echo "[rfc-gate] ALL GATES PASSED. RFC ${rfc_id} entered state: FROZEN"
    echo "[rfc-gate] (Autonomous staging blocked fail-closed; human thaw required)"
    echo "========================================================"
}

cmd_thaw() {
    local rfc_id="${1:-}"
    [[ -n "${rfc_id}" ]] || { echo "error: RFC ID required" >&2; exit 1; }

    local rfc_file="${RFCS_DIR}/${rfc_id}.json"
    [[ -f "${rfc_file}" ]] || { echo "error: RFC ${rfc_id} not found" >&2; exit 1; }

    local cur_state
    cur_state="$(jq -r '.state' "${rfc_file}")"
    if [[ "${cur_state}" != "FROZEN" ]]; then
        echo "error: RFC ${rfc_id} must be in FROZEN state to thaw (current: ${cur_state})" >&2
        exit 1
    fi

    # P4-C3: Thaw verification is harness-side ONLY (host trust boundary)
    if [[ ! -f "${THAW_FLAG_PATH}" ]]; then
        echo "error: human thaw token not found at ${THAW_FLAG_PATH}" >&2
        echo "       (Autonomous self-rewrite remains frozen fail-closed per security mandate)" >&2
        exit 1
    fi

    local flag_rfc_id flag_operator flag_nonce flag_ts
    flag_rfc_id="$(jq -r '.rfc_id // empty' "${THAW_FLAG_PATH}")"
    flag_operator="$(jq -r '.operator // empty' "${THAW_FLAG_PATH}")"
    flag_nonce="$(jq -r '.nonce // empty' "${THAW_FLAG_PATH}")"
    flag_ts="$(jq -r '.timestamp // empty' "${THAW_FLAG_PATH}")"

    if [[ "${flag_rfc_id}" != "${rfc_id}" ]]; then
        echo "error: thaw flag target RFC mismatch: flag specifies '${flag_rfc_id}', target is '${rfc_id}'" >&2
        exit 1
    fi

    # Time-bound: issuance timestamp must be within the trailing 24h window
    # (300s future leeway for clock skew). Design variance note: the stamped
    # design names an `expires_at` field; this implements the equivalent bound
    # as issuance + 24h window. Single-use consumption below is the replay
    # defense; the window bounds a stolen-but-unused flag's lifetime.
    [[ "${flag_ts}" =~ ^[0-9]+$ ]] || { echo "error: thaw flag lacks numeric .timestamp issuance" >&2; exit 1; }
    local now_s age_s
    now_s="$(date +%s)"
    age_s=$(( now_s - flag_ts ))
    if [[ "${age_s}" -lt -300 || "${age_s}" -ge 86400 ]]; then
        echo "error: thaw flag outside 24h validity window (age ${age_s}s)" >&2
        exit 1
    fi

    # Atomically consume flag (delete + nonce log)
    rm -f "${THAW_FLAG_PATH}"
    local thaw_log="${RFCS_DIR}/${rfc_id}.thaw.log"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") thawed by ${flag_operator} (nonce: ${flag_nonce})" >> "${thaw_log}"

    jq --arg op "${flag_operator}" --arg nonce "${flag_nonce}" \
       '.state = "THAWED" | .thaw_info = { operator: $op, nonce: $nonce, timestamp: (now | floor) }' \
       "${rfc_file}" > "${rfc_file}.tmp" && mv "${rfc_file}.tmp" "${rfc_file}"

    echo "[rfc-gate] Thaw token validated and consumed. RFC ${rfc_id} entered state: THAWED"
}

cmd_status() {
    local rfc_id="${1:-}"
    [[ -n "${rfc_id}" ]] || { echo "error: RFC ID required" >&2; exit 1; }

    local rfc_file="${RFCS_DIR}/${rfc_id}.json"
    [[ -f "${rfc_file}" ]] || { echo "error: RFC ${rfc_id} not found" >&2; exit 1; }

    cat "${rfc_file}"
}

main() {
    local cmd="${1:-}"
    shift || true

    case "${cmd}" in
        propose) cmd_propose "$@" ;;
        gate)    cmd_gate "$@" ;;
        thaw)    cmd_thaw "$@" ;;
        status)  cmd_status "$@" ;;
        *)       usage ;;
    esac
}

main "$@"
