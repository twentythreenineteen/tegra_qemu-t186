#!/usr/bin/env bash
# test_t2_2_isolation_tegrax1plus.sh - Tier 2: Machine isolation for tegrax1plus
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 2.2: Machine isolation - tegrax1plus machine model unaffected"
TEST_NUM="${1:-8}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

if [[ ! -x "${QEMU_BIN}" ]]; then
    log_fail "QEMU binary not executable: ${QEMU_BIN}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "QEMU binary missing"
    exit 1
fi

CPU_OUTPUT=$("${QEMU_BIN}" -M tegrax1plus -cpu ? 2>&1)
CPU_RET=$?

if [[ ${CPU_RET} -ne 0 ]]; then
    log_fail "tegrax1plus machine failed CPU enumeration with code ${CPU_RET}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegrax1plus CPU enumeration failed"
    exit 1
fi

if ! echo "${CPU_OUTPUT}" | grep -q "cortex-a57"; then
    log_fail "tegrax1plus machine did not list cortex-a57"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegrax1plus missing cortex-a57"
    exit 1
fi

set +e
timeout 3 "${QEMU_BIN}" -M tegrax1plus -display none -serial none -no-reboot > /dev/null 2>&1
INST_RET=$?
set -e

if [[ ${INST_RET} -eq 139 || ${INST_RET} -eq 134 ]]; then
    log_fail "tegrax1plus crashed with signal $((${INST_RET} - 128))"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegrax1plus crashed during init"
    exit 1
fi

log_pass "${TEST_NAME} (tegrax1plus model operational and uncorrupted)"
tap_ok "${TEST_NUM}" "${TEST_NAME}"
exit 0
