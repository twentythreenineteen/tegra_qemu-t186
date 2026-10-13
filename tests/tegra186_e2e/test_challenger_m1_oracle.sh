#!/usr/bin/env bash
# test_challenger_m1_oracle.sh - Challenger Empirical Oracle & Stress Test for M1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TEST_NAME="Challenger M1: Empirical Oracle & Stress Verification for HVC #3 and Immediate Dispatch"
TEST_NUM="${1:-14}"

log_info "Running ${TEST_NAME}..."

# 1. Run compiled C oracle stress test across 65,536 HVC immediates
ORACLE_BIN="${SCRIPT_DIR}/test_hvc_oracle"
if [[ ! -x "${ORACLE_BIN}" ]]; then
    log_info "Compiling test_hvc_oracle..."
    gcc -O2 \
        -I"${BUILD_DIR}/libqemu-aarch64-softmmu.a.p" \
        -I"${BUILD_DIR}" \
        -I"${BASE_DIR}" \
        -I"${BASE_DIR}/target/arm" \
        -I"${BUILD_DIR}/target/arm" \
        -I"${BASE_DIR}/include" \
        -I"${BASE_DIR}/host/include/x86_64" \
        -I"${BASE_DIR}/host/include/generic" \
        -I/usr/include/glib-2.0 \
        -I/usr/lib/x86_64-linux-gnu/glib-2.0/include \
        -DCOMPILING_PER_TARGET \
        -DCONFIG_TARGET=\"aarch64-softmmu-config-target.h\" \
        -DCONFIG_DEVICES=\"aarch64-softmmu-config-devices.h\" \
        "${SCRIPT_DIR}/test_hvc_oracle.c" \
        "${BUILD_DIR}/libqemu-aarch64-softmmu.a.p/hw_arm_tegra2_tegra186_hv.c.o" \
        -o "${ORACLE_BIN}"
fi

ORACLE_OUTPUT=$("${ORACLE_BIN}")
log_info "Oracle output:"
echo "${ORACLE_OUTPUT}" | sed 's/^/  [oracle] /'

# 2. Check live boot log assertions
BOOT_LOG="${TEST_BOOT_LOG:-${CACHED_BOOT_LOG}}"
if [[ ! -s "${BOOT_LOG}" ]]; then
    BOOT_LOG=$(get_or_run_boot_log 20 0)
fi

# Assertions
COUNT_GUEST_ID_FAIL=$(grep -c "tegra_hv: Failed to read guest id" "${BOOT_LOG}" || true)
COUNT_NOT_INIT_YET=$(grep -c "get_hvd: not initialized yet" "${BOOT_LOG}" || true)
COUNT_INITIALIZED=$(grep -c "tegra_hv: initialized" "${BOOT_LOG}" || true)
COUNT_HYP_CONFIG=$(grep -c "hyp_config_init: guest id 1 num guests 2" "${BOOT_LOG}" || true)
COUNT_PSCI_CPU1=$(grep -c "CPU1: Booted secondary processor" "${BOOT_LOG}" || true)

log_info "Boot Log Assertions:"
log_info "  'tegra_hv: Failed to read guest id' occurrences: ${COUNT_GUEST_ID_FAIL} (expected: 0)"
log_info "  'get_hvd: not initialized yet' occurrences:      ${COUNT_NOT_INIT_YET} (expected: 0)"
log_info "  'tegra_hv: initialized' occurrences:             ${COUNT_INITIALIZED} (expected: >= 1)"
log_info "  'hyp_config_init: guest id 1 num guests 2':      ${COUNT_HYP_CONFIG} (expected: >= 1)"
log_info "  'CPU1: Booted secondary processor':              ${COUNT_PSCI_CPU1} (expected: >= 1)"

if [[ ${COUNT_GUEST_ID_FAIL} -eq 0 && ${COUNT_NOT_INIT_YET} -eq 0 && ${COUNT_INITIALIZED} -ge 1 && ${COUNT_HYP_CONFIG} -ge 1 && ${COUNT_PSCI_CPU1} -ge 1 ]]; then
    log_pass "All Challenger M1 assertions verified successfully."
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "One or more Challenger M1 assertions failed!"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Assertion failure"
    exit 1
fi
