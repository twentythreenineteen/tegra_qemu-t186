#!/usr/bin/env bash
# test_t3_3_smp_4cpus_bringup.sh - Tier 3: Verify SMP PSCI bringup of all 4 cores on Tegra186
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 3.3: SMP PSCI Bringup of CPU1, CPU2, CPU3 (Brought up 4 CPUs)"
TEST_NUM="${1:-15}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

FAILURES=()

# 1. Check CPU1 booted
if grep -q "CPU1: Booted secondary processor" "${BOOT_LOG}"; then
    log_info "  [PASS] CPU1 booted successfully"
else
    FAILURES+=("CPU1 failed to boot")
fi

# 2. Check CPU2 booted
if grep -q "CPU2: Booted secondary processor" "${BOOT_LOG}"; then
    log_info "  [PASS] CPU2 booted successfully"
else
    FAILURES+=("CPU2 failed to boot (psci failed)")
fi

# 3. Check CPU3 booted
if grep -q "CPU3: Booted secondary processor" "${BOOT_LOG}"; then
    log_info "  [PASS] CPU3 booted successfully"
else
    FAILURES+=("CPU3 failed to boot (psci failed)")
fi

# 4. Check 'Brought up 4 CPUs'
if grep -q "Brought up 4 CPUs" "${BOOT_LOG}"; then
    log_info "  [PASS] Found 'Brought up 4 CPUs'"
else
    ACTUAL_CPUS=$(grep "Brought up " "${BOOT_LOG}" || echo "None")
    FAILURES+=("Expected 'Brought up 4 CPUs', got: ${ACTUAL_CPUS}")
fi

# 5. Check for PSCI boot failure errors
PSCI_FAILS=$(grep -E "psci: failed to boot CPU[23]" "${BOOT_LOG}" || true)
if [[ -n "${PSCI_FAILS}" ]]; then
    FAILURES+=("Detected PSCI boot failure: ${PSCI_FAILS}")
fi

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    log_pass "${TEST_NAME} (All 4 CPUs booted via PSCI)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "${TEST_NAME} failed with ${#FAILURES[@]} issues:"
    for f in "${FAILURES[@]}"; do
        log_fail "  - ${f}"
    done
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "${FAILURES[*]}"
    exit 1
fi
