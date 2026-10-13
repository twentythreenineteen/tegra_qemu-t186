#!/usr/bin/env bash
# test_t1_1_build_clean.sh - Tier 1: Clean build of QEMU binary
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.1: QEMU builds cleanly in Debian WSL via ninja"
TEST_NUM="${1:-1}"
STRICT="${STRICT:-0}"

log_info "Running ${TEST_NAME}..."

if [[ ! -d "${BUILD_DIR}" ]]; then
    log_fail "Build directory ${BUILD_DIR} does not exist"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Build dir not found"
    exit 1
fi

BUILD_OUTPUT=$(ninja -C "${BUILD_DIR}" -j4 qemu-system-aarch64 2>&1)
BUILD_RET=$?

if [[ ${BUILD_RET} -ne 0 ]]; then
    log_fail "ninja build failed with exit code ${BUILD_RET}:"
    echo "${BUILD_OUTPUT}" >&2
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "ninja build failed"
    exit 1
fi

if [[ ! -x "${QEMU_BIN}" ]]; then
    log_fail "Binary not found or not executable: ${QEMU_BIN}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Binary missing or not executable"
    exit 1
fi

BIN_SIZE=$(wc -c < "${QEMU_BIN}")
if [[ ${BIN_SIZE} -lt 10000000 ]]; then
    log_fail "Binary size ${BIN_SIZE} bytes is suspiciously small"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Binary size suspiciously small"
    exit 1
fi

log_pass "${TEST_NAME} (${BIN_SIZE} bytes)"
tap_ok "${TEST_NUM}" "${TEST_NAME}"
exit 0
