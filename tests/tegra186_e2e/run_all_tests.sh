#!/usr/bin/env bash
# run_all_tests.sh - Master runner for Tegra186 Parker QEMU E2E Test Suite
#
# Usage:
#   bash tests/tegra186_e2e/run_all_tests.sh [OPTIONS]
#
# Options:
#   --tier <1|2|3|4|all>      Run tests belonging to specified tier (default: all)
#   --milestone <m1|m2|m3|m4|all> Run tests scoped to specified milestone (default: all)
#   --log <path>              Use an existing serial boot log (fast execution)
#   --strict                  Fail with exit code 1 if any test is marked TODO (milestone pending)
#   --timeout <sec>           Timeout in seconds for QEMU boot capture (default: 25)
#   -h, --help                Show this help message
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

TIER="all"
MILESTONE="all"
STRICT=0
BOOT_TIMEOUT=25
USER_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tier)
            TIER="$2"
            shift 2
            ;;
        --tier=*)
            TIER="${1#*=}"
            shift
            ;;
        --milestone)
            MILESTONE="$2"
            shift 2
            ;;
        --milestone=*)
            MILESTONE="${1#*=}"
            shift
            ;;
        --log)
            USER_LOG="$2"
            shift 2
            ;;
        --log=*)
            USER_LOG="${1#*=}"
            shift
            ;;
        --strict)
            STRICT=1
            shift
            ;;
        --timeout)
            BOOT_TIMEOUT="$2"
            shift 2
            ;;
        --timeout=*)
            BOOT_TIMEOUT="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--tier <1|2|3|4|all>] [--milestone <m1|m2|m3|m4|all>] [--log <path>] [--strict] [--timeout <sec>]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

export STRICT
if [[ -n "${USER_LOG}" ]]; then
    export TEST_BOOT_LOG="${USER_LOG}"
fi

echo "======================================================================"
echo " Tegra186 Parker QEMU E2E Test Suite Runner"
echo " Environment: Debian WSL"
echo " Target Binary: ${QEMU_BIN}"
echo " Filter: Tier=${TIER}, Milestone=${MILESTONE}, Strict=${STRICT}"
echo "======================================================================"

# Determine test scripts to run
TEST_SCRIPTS=()

add_tier1() {
    TEST_SCRIPTS+=(
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_1_build_clean.sh"
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_2_machine_help.sh"
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_3_hvc_guest_id.sh"
        "${SCRIPT_DIR}/test_challenger_m1_oracle.sh"
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_4_ivc_reservation.sh"
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_5_vblk_device.sh"
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_6_rootfs_mount.sh"
        "${SCRIPT_DIR}/tier1_feature_coverage/test_t1_7_verity_boot.sh"
    )
}

add_tier2() {
    TEST_SCRIPTS+=(
        "${SCRIPT_DIR}/tier2_boundary_corner/test_t2_1_isolation_tegrax1.sh"
        "${SCRIPT_DIR}/tier2_boundary_corner/test_t2_2_isolation_tegrax1plus.sh"
        "${SCRIPT_DIR}/tier2_boundary_corner/test_t2_3_bad_hvc.sh"
        "${SCRIPT_DIR}/tier2_boundary_corner/test_t2_4_nonzero_return.sh"
    )
}

add_tier3() {
    TEST_SCRIPTS+=(
        "${SCRIPT_DIR}/tier3_cross_combinations/test_t3_1_psci_smp_secondary.sh"
        "${SCRIPT_DIR}/tier3_cross_combinations/test_t3_2_ivc_ram_isolation.sh"
        "${SCRIPT_DIR}/tier3_cross_combinations/test_t3_3_smp_4cpus_bringup.sh"
    )
}

add_tier4() {
    TEST_SCRIPTS+=(
        "${SCRIPT_DIR}/tier4_scenarios/test_t4_1_e2e_boot_rootfs_init.sh"
    )
}

case "${TIER}" in
    1) add_tier1 ;;
    2) add_tier2 ;;
    3) add_tier3 ;;
    4) add_tier4 ;;
    all)
        add_tier1
        add_tier2
        add_tier3
        add_tier4
        ;;
    *)
        echo "Unknown tier: ${TIER}" >&2
        exit 1
        ;;
esac

# Pre-generate boot log if needed so individual tests don't re-spawn QEMU
NEED_BOOT_LOG=0
for script in "${TEST_SCRIPTS[@]}"; do
    if grep -q "get_or_run_boot_log" "${script}"; then
        NEED_BOOT_LOG=1
        break
    fi
done

if [[ ${NEED_BOOT_LOG} -eq 1 && -z "${TEST_BOOT_LOG:-}" ]]; then
    # Generate cached boot log once
    log_info "Pre-capturing shared QEMU boot session (timeout: ${BOOT_TIMEOUT}s)..."
    BOOT_LOG_PATH=$(get_or_run_boot_log "${BOOT_TIMEOUT}" 0)
    export TEST_BOOT_LOG="${BOOT_LOG_PATH}"
    log_info "Shared boot log ready at: ${TEST_BOOT_LOG} ($(wc -l < "${TEST_BOOT_LOG}") lines)"
fi

TOTAL=${#TEST_SCRIPTS[@]}
echo "1..${TOTAL}"

PASSED=0
FAILED=0
TODOS=0
TEST_INDEX=1

RESULTS=()

for script in "${TEST_SCRIPTS[@]}"; do
    SCRIPT_NAME=$(basename "${script}")
    # Run test script capturing output
    OUTPUT=$(bash "${script}" "${TEST_INDEX}" 2>&1)
    RET=$?

    # Extract TAP line
    TAP_LINE=$(echo "${OUTPUT}" | grep -E "^(ok|not ok) ${TEST_INDEX}" | tail -n 1)

    if [[ -z "${TAP_LINE}" ]]; then
        if [[ ${RET} -eq 0 ]]; then
            TAP_LINE="ok ${TEST_INDEX} - ${SCRIPT_NAME}"
        else
            TAP_LINE="not ok ${TEST_INDEX} - ${SCRIPT_NAME}"
        fi
    fi

    echo "${TAP_LINE}"

    if echo "${TAP_LINE}" | grep -q "# TODO"; then
        TODOS=$((TODOS + 1))
        RESULTS+=("TODO: ${SCRIPT_NAME}")
    elif [[ ${RET} -eq 0 ]] && echo "${TAP_LINE}" | grep -q "^ok "; then
        PASSED=$((PASSED + 1))
        RESULTS+=("PASS: ${SCRIPT_NAME}")
    else
        FAILED=$((FAILED + 1))
        RESULTS+=("FAIL: ${SCRIPT_NAME}")
        # Echo full error output if failed
        echo "${OUTPUT}" | sed 's/^/# /'
    fi

    TEST_INDEX=$((TEST_INDEX + 1))
done

echo ""
echo "======================================================================"
echo " Test Summary"
echo "======================================================================"
echo " Total Tests:  ${TOTAL}"
echo " Passed:       ${PASSED}"
echo " In-Progress:  ${TODOS} (marked TODO for pending milestones)"
echo " Failed:       ${FAILED}"
echo "======================================================================"

if [[ ${FAILED} -gt 0 ]]; then
    echo -e "${COLOR_RED}RESULT: FAILED (${FAILED} regression/unexpected failures)${COLOR_RESET}"
    exit 1
elif [[ ${STRICT} -eq 1 && ${TODOS} -gt 0 ]]; then
    echo -e "${COLOR_YELLOW}RESULT: STRICT AUDIT FAILED (${TODOS} milestone deliverables pending)${COLOR_RESET}"
    exit 1
else
    echo -e "${COLOR_GREEN}RESULT: PASSED (All currently verifiable features operational)${COLOR_RESET}"
    exit 0
fi
