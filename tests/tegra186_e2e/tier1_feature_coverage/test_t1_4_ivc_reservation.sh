#!/usr/bin/env bash
# test_t1_4_ivc_reservation.sh - Tier 1: IVC Channel Reservation (Requirement R2)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.4: IVC shared-memory and channel reservation succeeds (R2)"
TEST_NUM="${1:-4}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

HAS_IVC_FAIL=0
if grep -E "Failed to reserve IVC channel (66|67|104|113)" "${BOOT_LOG}" > /dev/null; then
    HAS_IVC_FAIL=1
fi

if grep -E "Failed to reserve ivc queue (66|67|104|113)" "${BOOT_LOG}" > /dev/null; then
    HAS_IVC_FAIL=1
fi

if grep -q "tegra_hv: Failed to read guest id" "${BOOT_LOG}"; then
    HAS_IVC_FAIL=1
fi

if [[ ${HAS_IVC_FAIL} -eq 0 ]]; then
    log_pass "${TEST_NAME} (no IVC reservation failures observed on channels 66/67/104/113)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "${TEST_NAME} (target IVC channel reservation failure observed)"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Failed to reserve IVC channel"
    exit 1
fi
