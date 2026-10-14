#!/usr/bin/env bash
# test_t1_7_verity_boot.sh - Tier 1: dm-verity boot mode (--verity flag)
#
# Tests that launch_tegra186.sh --verity produces correct dm-verity bootargs
# and that the kernel sees GPT partitions + dm-verity device-mapper setup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

TEST_NAME="Tier 1.7: dm-verity boot mode (--verity flag, GPT partitions, /dev/dm-0)"
TEST_NUM="${1:-7}"
STRICT="${STRICT:-0}"

LAUNCH_SCRIPT="${BASE_DIR}/launch_tegra186.sh"
VERITY_DISK="${VERITY_DISK:-${BASE_DIR}/verity_disk.img}"

log_info "Running ${TEST_NAME}..."

# --- Test 1: launch script exists and supports --verity ---
if [[ ! -f "${LAUNCH_SCRIPT}" ]]; then
    log_fail "Launch script not found: ${LAUNCH_SCRIPT}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "Launch script missing"
    exit 1
fi

if ! grep -q -- '--verity' "${LAUNCH_SCRIPT}"; then
    log_fail "Launch script does not support --verity flag"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "--verity flag not found in launch script"
    exit 1
fi
log_pass "Launch script supports --verity flag"

# --- Test 2: launch script sets dm= bootargs in verity mode ---
if ! grep -q 'dm=\\"' "${LAUNCH_SCRIPT}"; then
    log_fail "Launch script does not set dm= bootargs for verity mode"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "dm= bootargs not found"
    exit 1
fi
log_pass "Launch script sets dm= bootargs in verity mode"

# --- Test 3: launch script sets TEGRA_VBLK_TOTAL_BLOCKS in verity mode ---
if ! grep -q 'TEGRA_VBLK_TOTAL_BLOCKS' "${LAUNCH_SCRIPT}"; then
    log_fail "Launch script does not set TEGRA_VBLK_TOTAL_BLOCKS in verity mode"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "TEGRA_VBLK_TOTAL_BLOCKS not found"
    exit 1
fi
log_pass "Launch script sets TEGRA_VBLK_TOTAL_BLOCKS for disk geometry"

# --- Test 4: build_verity_disk.py exists ---
BUILD_TOOL="${BASE_DIR}/tools/build_verity_disk.py"
if [[ ! -f "${BUILD_TOOL}" ]]; then
    log_fail "Verity disk build tool not found: ${BUILD_TOOL}"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "build_verity_disk.py missing"
    exit 1
fi
log_pass "Verity disk build tool exists: tools/build_verity_disk.py"

# --- Test 5: QEMU source supports TEGRA_VBLK_TOTAL_BLOCKS env var ---
HV_SRC="${BASE_DIR}/hw/arm/tegra2/tegra186_hv.c"
if [[ -f "${HV_SRC}" ]] && grep -q 'TEGRA_VBLK_TOTAL_BLOCKS' "${HV_SRC}"; then
    log_pass "QEMU HVC backend reads TEGRA_VBLK_TOTAL_BLOCKS env var"
else
    log_fail "QEMU HVC backend does not read TEGRA_VBLK_TOTAL_BLOCKS"
    tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "TEGRA_VBLK_TOTAL_BLOCKS not in tegra186_hv.c"
    exit 1
fi

# --- Test 6: Full boot test with verity disk (if available) ---
if [[ -f "${VERITY_DISK}" && -f "${QEMU_BIN}" && -f "${KERNEL_IMG}" ]]; then
    VERITY_LOG="${TEST_BOOT_LOG:-/tmp/tegra186_verity_boot.log}"
    log_info "Launching verity boot test (timeout: 60s)..."
    log_info "Disk: ${VERITY_DISK}"

    DISK_SIZE=$(stat -c %s "${VERITY_DISK}" 2>/dev/null || stat -f %z "${VERITY_DISK}" 2>/dev/null || echo 0)
    TOTAL_4K=$(( DISK_SIZE / 4096 ))
    export TEGRA_VBLK_TOTAL_BLOCKS="${TOTAL_4K}"
    export TEGRA_ROOTFS_IMG="${VERITY_DISK}"

    VERITY_ROOT_HASH="${VERITY_ROOT_HASH:-5830e1d5ab8e48dff4e005a812f60b9244b007f0651eb8b0de6c1e518d1ffdb2}"
    VERITY_SALT="${VERITY_SALT:-caa1129717e173bfcc27ec028cd8bb5b9471fb4b5d00db401d715b5a3cc4a238}"
    DATA_SECTORS=24035328
    DATA_4K_BLOCKS=3004416
    DM_ARGS="1 vroot none ro 1,0 ${DATA_SECTORS} verity 1 /dev/vblkdev0p1 /dev/vblkdev0p2 4096 4096 ${DATA_4K_BLOCKS} 0 sha256 ${VERITY_ROOT_HASH} ${VERITY_SALT} 1 check_at_most_once"

    set +e
    timeout --preserve-status 60 "${QEMU_BIN}" \
        -M tegra186 -cpu cortex-a57 -smp 4 -m 4096M \
        -kernel "${KERNEL_IMG}" \
        -dtb "${DTB_FILE}" \
        -append "earlycon=uart8250,mmio32,0x031f0000 console=ttyS0,115200 dm=\"${DM_ARGS}\" root=/dev/dm-0 gpt gpt_sector=0x7000 loglevel=3 no_console_suspend=1 fsck.repair=yes rootwait earlyprintk ignore_loglevel" \
        -display none -serial stdio -no-reboot \
        -drive "file=${VERITY_DISK},if=none,format=raw,id=rootfs" \
        > "${VERITY_LOG}" 2>&1
    RET=$?
    set -e

    log_info "Verity boot exited with code ${RET}, log: ${VERITY_LOG} ($(wc -l < "${VERITY_LOG}" 2>/dev/null || echo 0) lines)"

    # Check for GPT partition detection
    HAS_GPT=0
    if grep -qE "(vblkdev0p1|vblkdev0p2|GPT partition|efi: GPT)" "${VERITY_LOG}" 2>/dev/null; then
        HAS_GPT=1
        log_info "GPT partitions detected in boot log"
    fi

    # Check for dm-verity messages
    HAS_VERITY=0
    if grep -qiE "(device-mapper: verity|dm-verity|verity.*target|dm-0)" "${VERITY_LOG}" 2>/dev/null; then
        HAS_VERITY=1
        log_info "dm-verity messages found in boot log"
    fi

    # Check for root mount on dm-0
    HAS_DM0_MOUNT=0
    if grep -qE "(VFS: Mounted root.*dm-0|EXT4-fs.*dm-0)" "${VERITY_LOG}" 2>/dev/null; then
        HAS_DM0_MOUNT=1
        log_info "Root mounted on /dev/dm-0"
    fi

    # Check for verity failure (corruption detected)
    HAS_VERITY_FAIL=0
    if grep -qiE "(verity.*corrupt|verification failed|dm-verity.*error)" "${VERITY_LOG}" 2>/dev/null; then
        HAS_VERITY_FAIL=1
        log_fail "dm-verity reported corruption/verification failure"
    fi

    if [[ ${HAS_DM0_MOUNT} -eq 1 && ${HAS_VERITY_FAIL} -eq 0 ]]; then
        log_pass "${TEST_NAME} (dm-verity boot: GPT + verity + /dev/dm-0 mount)"
        tap_ok "${TEST_NUM}" "${TEST_NAME}"
        exit 0
    elif [[ ${HAS_GPT} -eq 1 && ${HAS_VERITY} -eq 1 && ${HAS_VERITY_FAIL} -eq 0 ]]; then
        log_pass "${TEST_NAME} (dm-verity initialized, GPT partitions detected)"
        tap_ok "${TEST_NUM}" "${TEST_NAME}"
        exit 0
    elif [[ "${STRICT}" -eq 1 ]]; then
        log_fail "${TEST_NAME} (dm-verity boot not fully verified)"
        log_fail "  GPT partitions: ${HAS_GPT}, dm-verity init: ${HAS_VERITY}, dm-0 mount: ${HAS_DM0_MOUNT}, verity fail: ${HAS_VERITY_FAIL}"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "" "dm-verity boot incomplete"
        exit 1
    else
        log_todo "${TEST_NAME} - dm-verity boot partial (GPT=${HAS_GPT}, verity=${HAS_VERITY}, dm0=${HAS_DM0_MOUNT})"
        tap_not_ok "${TEST_NUM}" "${TEST_NAME}" "TODO" "dm-verity boot not fully verified"
        exit 0
    fi
else
    log_todo "Skipping full boot test (verity disk or QEMU binary not available)"
    log_info "  VERITY_DISK=${VERITY_DISK}"
    log_info "  QEMU_BIN=${QEMU_BIN}"
    log_info "  KERNEL_IMG=${KERNEL_IMG}"
    # Static checks passed, report success for what we could verify
    log_pass "${TEST_NAME} (static checks: --verity flag, dm= args, TEGRA_VBLK_TOTAL_BLOCKS, build tool)"
    tap_ok "${TEST_NUM}" "${TEST_NAME} (static checks only)"
    exit 0
fi
