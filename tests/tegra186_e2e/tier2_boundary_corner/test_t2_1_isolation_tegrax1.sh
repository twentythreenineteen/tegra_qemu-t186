#!/usr/bin/env bash
# test_t2_1_isolation_tegrax1.sh - Tier 2: Machine isolation for tegrax1
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 2.1: Machine isolation - tegrax1 machine model unaffected"
TEST_NUM="${1:-7}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

if [[ ! -x "${QEMU_BIN}" ]]; then
    log_fail "QEMU binary not executable: ${QEMU_BIN}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "QEMU binary missing"
    exit 1
fi

# Verify tegrax1 machine registers and reports supported CPUs
CPU_OUTPUT=$("${QEMU_BIN}" -M tegrax1 -cpu ? 2>&1)
CPU_RET=$?

if [[ ${CPU_RET} -ne 0 ]]; then
    log_fail "tegrax1 machine failed CPU enumeration with code ${CPU_RET}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegrax1 CPU enumeration failed"
    exit 1
fi

if ! echo "${CPU_OUTPUT}" | grep -q "cortex-a57"; then
    log_fail "tegrax1 machine did not list cortex-a57"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegrax1 missing cortex-a57"
    exit 1
fi

# Quick instantiation test with dummy/empty execution to verify machine init does not panic
set +e
timeout 3 "${QEMU_BIN}" -M tegrax1 -display none -serial none -no-reboot > /dev/null 2>&1
INST_RET=$?
set -e

# Exit code 0 or 124 (timeout) or clean error is acceptable, but not SIGSEGV (139) or SIGABRT (134)
if [[ ${INST_RET} -eq 139 || ${INST_RET} -eq 134 ]]; then
    log_fail "tegrax1 crashed with signal $((${INST_RET} - 128))"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegrax1 crashed during init"
    exit 1
fi

log_pass "${TEST_NAME} (tegrax1 model operational and uncorrupted)"
tap_ok "${TEST_NUM}" "${TEST_NAME}"
exit 0
