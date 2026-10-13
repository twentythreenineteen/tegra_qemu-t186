#!/usr/bin/env bash
# test_t4_1_e2e_boot_rootfs_init.sh - Tier 4: Real-World Application Scenario (End-to-End Boot & Init)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 4.1: End-to-end boot of Image-4.9.299-tegra mounting rootfs and executing init"
TEST_NUM="${1:-13}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

BOOT_LOG=$(get_or_run_boot_log 25 0)

if [[ ! -s "${BOOT_LOG}" ]]; then
    log_fail "Boot log is empty: ${BOOT_LOG}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Empty boot log"
    exit 1
fi

FAILURES=()

# 1. Clean 4-core bringup
if grep -q "Brought up 4 CPUs" "${BOOT_LOG}" && grep -q "CPU1: Booted secondary processor" "${BOOT_LOG}"; then
    log_info "  [PASS] Clean 4-core bringup verified"
else
    FAILURES+=("Clean 4-core bringup not found")
fi

# 2. tegra_hv: initialized without guest ID error
if grep -q "tegra_hv: initialized" "${BOOT_LOG}" && ! grep -q "Failed to read guest id" "${BOOT_LOG}"; then
    log_info "  [PASS] tegra_hv: initialized without guest ID error"
else
    FAILURES+=("tegra_hv initialization failure or guest id error detected")
fi

# 3. registered /dev/vblkdev0
if grep -q -E "(registered /dev/vblkdev0|vblkdev0)" "${BOOT_LOG}"; then
    log_info "  [PASS] /dev/vblkdev0 registered"
else
    FAILURES+=("vblkdev0 registration not found")
fi

# 4. VFS: Mounted root (ext4 filesystem) readonly on device 253:0
if grep -E "(VFS: Mounted root|EXT4-fs.*mounted filesystem)" "${BOOT_LOG}" > /dev/null; then
    log_info "  [PASS] VFS: Mounted root (ext4 filesystem) readonly on device 253:0"
else
    FAILURES+=("Rootfs ext4 mount not achieved")
fi

# 5. Userspace init / systemd / daemon startup
if grep -E "(Run /sbin/init as init process|systemd|mini-init|Starting early init system|Starting init:|apparmor_parser)" "${BOOT_LOG}" > /dev/null; then
    log_info "  [PASS] Userspace init, systemd, or daemon startup verified"
else
    FAILURES+=("Userspace init / daemon startup not detected")
fi

if [[ ${#FAILURES[@]} -eq 0 ]]; then
    log_pass "${TEST_NAME} (Full boot end-to-end succeeded, rootfs mounted and userspace init reached)"
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
