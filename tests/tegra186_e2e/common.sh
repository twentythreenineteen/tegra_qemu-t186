#!/usr/bin/env bash
# common.sh - Shared assertions and test harness utilities for Tegra186 E2E tests
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Target Binaries and Artifacts
QEMU_BIN="${QEMU_BIN:-${BASE_DIR}/build/qemu-system-aarch64}"
BUILD_DIR="${BUILD_DIR:-${BASE_DIR}/build}"
KERNEL_IMG="${KERNEL_IMG:-${BASE_DIR}/Image-4.9.299-tegra}"
DTB_FILE="${DTB_FILE:-${BASE_DIR}/tegra186_qemu.dtb}"
ROOTFS_IMG="${ROOTFS_IMG:-${BASE_DIR}/rootfs_ext4.img}"

# Shared log cache
CACHED_BOOT_LOG="${TEST_BOOT_LOG:-/tmp/tegra186_e2e_boot.log}"

# Output color codes (disabled if not a tty)
if [[ -t 1 ]]; then
    COLOR_RESET="\033[0m"
    COLOR_GREEN="\033[32m"
    COLOR_RED="\033[31m"
    COLOR_YELLOW="\033[33m"
    COLOR_BLUE="\033[34m"
    COLOR_BOLD="\033[1m"
else
    COLOR_RESET=""
    COLOR_GREEN=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_BOLD=""
fi

# Logging functions
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*"
}

log_pass() {
    echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} $*"
}

log_fail() {
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"
}

log_todo() {
    echo -e "${COLOR_YELLOW}[TODO]${COLOR_RESET} $*"
}

# TAP helpers
tap_ok() {
    local num="$1"
    local desc="$2"
    echo "ok ${num} - ${desc}"
}

tap_not_ok() {
    local num="$1"
    local desc="$2"
    local directive="${3:-}"
    local reason="${4:-}"
    if [[ -n "${directive}" ]]; then
        echo "not ok ${num} - ${desc} # ${directive} ${reason}"
    else
        echo "not ok ${num} - ${desc}"
    fi
}

# Boot QEMU and capture serial output or use existing log
get_or_run_boot_log() {
    local timeout_sec="${1:-20}"
    local force_refresh="${2:-0}"
    shift 2 || true
    local extra_qemu_args=("$@")

    if [[ -n "${TEST_BOOT_LOG:-}" && -f "${TEST_BOOT_LOG}" ]]; then
        echo "${TEST_BOOT_LOG}"
        return 0
    fi

    if [[ "${force_refresh}" -eq 0 && -f "${CACHED_BOOT_LOG}" && -s "${CACHED_BOOT_LOG}" ]]; then
        # Check if QEMU binary is newer than cached log
        if [[ "${QEMU_BIN}" -nt "${CACHED_BOOT_LOG}" ]]; then
            log_info "QEMU binary newer than cached log, re-running boot capture..." >&2
        else
            echo "${CACHED_BOOT_LOG}"
            return 0
        fi
    fi

    log_info "Launching Tegra186 QEMU (timeout: ${timeout_sec}s) to capture boot log..." >&2

    local boot_args=(
        -M tegra186
        -cpu cortex-a57
        -smp 4
        -m 4096M
        -kernel "${KERNEL_IMG}"
        -dtb "${DTB_FILE}"
        -append "earlycon=uart8250,mmio32,0x031f0000 console=ttyS0,115200 earlyprintk ignore_loglevel root=/dev/vblkdev0 rootfstype=ext4 ro init=/sbin/init rootwait"
        -display none
        -serial stdio
        -no-reboot
    )

    if [[ -f "${ROOTFS_IMG}" ]]; then
        boot_args+=(-drive "file=${ROOTFS_IMG},if=none,format=raw,id=rootfs")
    fi

    set +e
    timeout --preserve-status "${timeout_sec}" "${QEMU_BIN}" "${boot_args[@]}" "${extra_qemu_args[@]}" > "${CACHED_BOOT_LOG}" 2>&1
    local ret=$?
    set -e

    # Exit code 124 is standard timeout
    if [[ ${ret} -ne 0 && ${ret} -ne 124 ]]; then
        log_info "QEMU exited with code ${ret} (log captured: $(wc -l < "${CACHED_BOOT_LOG}") lines)" >&2
    fi

    echo "${CACHED_BOOT_LOG}"
}
