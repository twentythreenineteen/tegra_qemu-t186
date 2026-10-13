#!/usr/bin/env bash
# test_t2_3_bad_hvc.sh - Tier 2: Unhandled/Invalid HVC Immediate Call Safety
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 2.3: Unhandled or invalid HVC calls do not panic or crash QEMU"
TEST_NUM="${1:-9}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

# Check for QEMU core dump, assertion abort, or unhandled CPU crash
HAS_CRASH=0
if grep -E "(qemu-system-aarch64:.*Assertion|Fatal error|Aborted|Segmentation fault)" "${BOOT_LOG}" > /dev/null; then
    HAS_CRASH=1
fi

# Check for illegal instruction trap in guest early boot
HAS_ILLEGAL_INSN=0
if grep -E "(Kernel panic - not syncing: Attempted to kill init|Internal error: Oops - undefined instruction)" "${BOOT_LOG}" > /dev/null; then
    HAS_ILLEGAL_INSN=1
fi

if [[ ${HAS_CRASH} -eq 0 && ${HAS_ILLEGAL_INSN} -eq 0 ]]; then
    log_pass "${TEST_NAME} (No emulator assertion crashes or illegal instruction aborts)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "${TEST_NAME} (Crash or undefined instruction exception observed)"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Unhandled HVC exception triggered crash"
    exit 1
fi
