#!/usr/bin/env bash
# test_t1_2_machine_help.sh - Tier 1: Machine help listing contains tegra186
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.2: Machine help lists tegra186 machine model"
TEST_NUM="${1:-2}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

if [[ ! -x "${QEMU_BIN}" ]]; then
    log_fail "QEMU binary not executable: ${QEMU_BIN}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "QEMU binary not found"
    exit 1
fi

HELP_OUTPUT=$("${QEMU_BIN}" -M help 2>&1)

if ! echo "${HELP_OUTPUT}" | grep -E "^tegra186\s+ARM NVIDIA Tegra186 \(T186/Parker\)" > /dev/null; then
    log_fail "Machine 'tegra186' not listed in -M help output"
    echo "${HELP_OUTPUT}" | grep -i tegra || true
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "tegra186 missing from -M help"
    exit 1
fi

log_pass "${TEST_NAME}"
tap_ok "${TEST_NUM}" "${TEST_NAME}"
exit 0
