#!/usr/bin/env bash
# test_t1_5_vblk_device.sh - Tier 1: tegra_hv_vblk block device creation (Requirement R3)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.5: tegra_hv_vblk initializes /dev/vblkdev0 block device (R3)"
TEST_NUM="${1:-5}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

HAS_VBLK_DEV=0
# Look for actual disk creation/partition scan, ignoring command-line and "Waiting for root device"
if grep "vblkdev0" "${BOOT_LOG}" | grep -v -E "(Kernel command line|Waiting for root device)" | grep -E "([0-9]+\s+sectors|vblkdev0:\s+p|registered\s+/dev/vblkdev0|attach.*vblkdev0)" > /dev/null; then
    HAS_VBLK_DEV=1
fi

if [[ ${HAS_VBLK_DEV} -eq 1 ]]; then
    log_pass "${TEST_NAME} (/dev/vblkdev0 recognized)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    if [[ "${STRICT}" -eq 1 ]]; then
        log_fail "${TEST_NAME} (/dev/vblkdev0 not found in boot log)"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "vblkdev0 not initialized"
        exit 1
    else
        log_todo "${TEST_NAME} - Pending Milestone M3 (Virtual Block Device)"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "TODO" "Pending Milestone M3 (Virtual Block Device)"
        exit 0
    fi
fi
