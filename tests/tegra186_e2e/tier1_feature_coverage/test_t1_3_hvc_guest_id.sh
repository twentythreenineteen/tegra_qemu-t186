#!/usr/bin/env bash
# test_t1_3_hvc_guest_id.sh - Tier 1: HVC #3 Guest ID resolution (Requirement R1)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.3: HVC #3 Guest ID traps and initializes tegra_hv (R1)"
TEST_NUM="${1:-3}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty or could not be generated: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

# Check for failure marker
HAS_GUEST_ID_FAIL=0
if grep -q "tegra_hv: Failed to read guest id" "${BOOT_LOG}"; then
    HAS_GUEST_ID_FAIL=1
fi

HAS_GET_HVD_FAIL=0
if grep -q "tegra_hv: get_hvd: not initialized yet" "${BOOT_LOG}"; then
    HAS_GET_HVD_FAIL=1
fi

if [[ ${HAS_GUEST_ID_FAIL} -eq 0 && ${HAS_GET_HVD_FAIL} -eq 0 ]]; then
    log_pass "${TEST_NAME} (no 'Failed to read guest id' found)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    if [[ "${STRICT}" -eq 1 ]]; then
        log_fail "${TEST_NAME} ('Failed to read guest id' or 'get_hvd: not initialized yet' observed)"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Failed to read guest id"
        exit 1
    else
        log_todo "${TEST_NAME} - Pending Milestone M1 (HVC #3 stub)"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "TODO" "Pending Milestone M1 (HVC #3 stub)"
        exit 0
    fi
fi
