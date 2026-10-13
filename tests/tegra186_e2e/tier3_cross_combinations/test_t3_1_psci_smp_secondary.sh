#!/usr/bin/env bash
# test_t3_1_psci_smp_secondary.sh - Tier 3: Hypercall hook + PSCI multicore secondary booting
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 3.1: Hypercall hook preserves PSCI HVC #0 for multicore secondary CPU boot"
TEST_NUM="${1:-11}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

# 1. Verify PSCI probe
HAS_PSCI_PROBE=0
if grep -q "psci: PSCIv1.1 detected in firmware" "${BOOT_LOG}"; then
    HAS_PSCI_PROBE=1
fi

# 2. Verify Secondary CPU brought up via PSCI
HAS_CPU1_BOOT=0
if grep -q "CPU1: Booted secondary processor" "${BOOT_LOG}"; then
    HAS_CPU1_BOOT=1
fi

# 3. Verify SMP activation
HAS_SMP_ACTIVATED=0
if grep -E "SMP: Total of [1-9][0-9]* processors activated" "${BOOT_LOG}" > /dev/null; then
    HAS_SMP_ACTIVATED=1
fi

if [[ ${HAS_PSCI_PROBE} -eq 1 && ${HAS_CPU1_BOOT} -eq 1 && ${HAS_SMP_ACTIVATED} -eq 1 ]]; then
    log_pass "${TEST_NAME} (PSCI active, secondary CPU1 booted, SMP activated)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "${TEST_NAME} (PSCI multicore booting failed: probe=${HAS_PSCI_PROBE}, cpu1=${HAS_CPU1_BOOT}, smp=${HAS_SMP_ACTIVATED})"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "PSCI secondary boot failed"
    exit 1
fi
