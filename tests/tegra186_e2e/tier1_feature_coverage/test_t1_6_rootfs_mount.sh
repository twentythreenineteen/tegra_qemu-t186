#!/usr/bin/env bash
# test_t1_6_rootfs_mount.sh - Tier 1: Rootfs mount progression (Requirement R3 & R4)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.6: Root filesystem mounts successfully from /dev/vblkdev0 (R3/R4)"
TEST_NUM="${1:-6}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

HAS_VFS_PANIC=0
if grep -E "VFS: Cannot open root device" "${BOOT_LOG}" > /dev/null; then
    HAS_VFS_PANIC=1
fi

HAS_MOUNT_SUCCESS=0
if grep -E "(VFS: Mounted root|EXT4-fs.*mounted filesystem)" "${BOOT_LOG}" > /dev/null; then
    HAS_MOUNT_SUCCESS=1
fi

if [[ ${HAS_MOUNT_SUCCESS} -eq 1 && ${HAS_VFS_PANIC} -eq 0 ]]; then
    log_pass "${TEST_NAME} (Rootfs mounted successfully)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    if [[ "${STRICT}" -eq 1 ]]; then
        log_fail "${TEST_NAME} (Rootfs mount not achieved)"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "VFS rootfs mount failure"
        exit 1
    else
        log_todo "${TEST_NAME} - Pending Milestone M3/M4 (Storage Backend & Rootfs Mount)"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "TODO" "Pending Milestone M3/M4 (Storage Backend & Rootfs Mount)"
        exit 0
    fi
fi
