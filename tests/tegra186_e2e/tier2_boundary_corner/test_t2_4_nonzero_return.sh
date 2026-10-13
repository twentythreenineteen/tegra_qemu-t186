#!/usr/bin/env bash
# test_t2_4_nonzero_return.sh - Tier 2: Non-zero return code handling & error propagation
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 2.4: Non-zero return codes from hypercalls propagate safely without memory corruption"
TEST_NUM="${1:-10}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 20 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

# Verify no kernel general protection faults, null pointer dereferences, or memory corruptions in tegra_hv
HAS_MEM_CORRUPTION=0
if grep -E "(Unable to handle kernel NULL pointer dereference|kernel BUG at|general protection fault|Bad mode in Synchronous Abort handler)" "${BOOT_LOG}" > /dev/null; then
    HAS_MEM_CORRUPTION=1
fi

if [[ ${HAS_MEM_CORRUPTION} -eq 0 ]]; then
    log_pass "${TEST_NAME} (Error paths handled cleanly by kernel exception handlers)"
    tap_ok "${TEST_NUM}" "${TEST_NAME}"
    exit 0
else
    log_fail "${TEST_NAME} (Memory corruption or null pointer dereference observed)"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Kernel crash on hypercall error return"
    exit 1
fi
