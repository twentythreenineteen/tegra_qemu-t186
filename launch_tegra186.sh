#!/usr/bin/env bash
# launch_tegra186.sh - Launch QEMU Tegra186 Parker Emulation under Debian WSL
#
# Usage:
#   ./launch_tegra186.sh [--verity] [-t SECONDS] [extra qemu args...]
#
# Modes:
#   Default (no --verity): Boots with root=/dev/vblkdev0 (raw ext4, no dm-verity).
#     Expects TEGRA_ROOTFS_IMG to point to a raw ext4 image (e.g. 1_gos1-fs_7_ext4.img).
#
#   --verity: Boots with root=/dev/dm-0 (full dm-verity verification).
#     Expects TEGRA_ROOTFS_IMG to point to a GPT-partitioned disk image
#     (assembled by tools/build_verity_disk.py) containing:
#       Partition 1: ext4 data image (gos1-fs)
#       Partition 2: dm-verity hash tree (verity_rootfs_hash)
#     Uses 512-byte sector mode (TEGRA_VBLK_SECTOR_MODE=1) so the kernel's
#     GPT partition scanner can find /dev/vblkdev0p1 and /dev/vblkdev0p2.
#     Also sets TEGRA_VBLK_TOTAL_BLOCKS to the total 512-byte sector count
#     of the disk image so the vblk backend reports correct disk geometry.
#
# Environment variables:
#   QEMU       - Path to qemu-system-aarch64 binary
#   KERNEL     - Path to kernel image
#   DTB        - Path to device tree blob
#   ROOTFS     - Path to rootfs/disk image (sets TEGRA_ROOTFS_IMG)
#   VERITY_ROOT_HASH - Override the dm-verity root hash (default: factory value)
#   VERITY_SALT      - Override the dm-verity salt (default: factory value)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_BIN="${QEMU:-./build/qemu-system-aarch64}"
KERNEL_IMG="${KERNEL:-./Image-4.9.299-tegra}"
DTB_FILE="${DTB:-${SCRIPT_DIR}/tegra186_qemu.dtb}"
# Rootfs image is NOT included in this repo. Set ROOTFS env var to your own image.
ROOTFS_IMG="${ROOTFS:-./rootfs_ext4.img}"
export TEGRA_ROOTFS_IMG="${ROOTFS_IMG}"

# Factory dm-verity parameters (from vendor DTB bootargs)
VERITY_ROOT_HASH="${VERITY_ROOT_HASH:-5830e1d5ab8e48dff4e005a812f60b9244b007f0651eb8b0de6c1e518d1ffdb2}"
VERITY_SALT="${VERITY_SALT:-caa1129717e173bfcc27ec028cd8bb5b9471fb4b5d00db401d715b5a3cc4a238}"

VERITY_MODE=0
TIMEOUT=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verity)
            VERITY_MODE=1
            shift
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT="${1#*=}"
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

if [[ ! -x "${QEMU_BIN}" ]]; then
    echo "[-] Error: QEMU binary not found or not executable at: ${QEMU_BIN}" >&2
    exit 1
fi

if [[ ! -f "${KERNEL_IMG}" ]]; then
    echo "[-] Error: Kernel image not found at: ${KERNEL_IMG}" >&2
    exit 1
fi

if [[ ! -f "${DTB_FILE}" ]]; then
    echo "[*] DTB not found at ${DTB_FILE}, compiling automatically..."
    bash "${SCRIPT_DIR}/build_dtb.sh"
fi

if [[ ${VERITY_MODE} -eq 1 ]]; then
    # dm-verity mode: root=/dev/dm-0 via kernel dm= bootargs
    # Use 512-byte sector mode so the kernel's GPT partition scanner works correctly.
    # In sector mode, total_blocks is in 512-byte sectors (not 4K blocks).
    DISK_SIZE_BYTES=$(stat -c %s "${ROOTFS_IMG}" 2>/dev/null || stat -f %z "${ROOTFS_IMG}" 2>/dev/null || echo 0)
    TOTAL_SECTORS=$(( DISK_SIZE_BYTES / 512 ))
    export TEGRA_VBLK_TOTAL_BLOCKS="${TOTAL_SECTORS}"
    export TEGRA_VBLK_SECTOR_MODE=1

    # Data partition: 24035328 sectors (512B) = 3004416 4K-blocks
    DATA_SECTORS=24035328
    DATA_4K_BLOCKS=3004416

    DM_ARGS="1 vroot none ro 1,0 ${DATA_SECTORS} verity 1 /dev/vblkdev0p1 /dev/vblkdev0p2 4096 4096 ${DATA_4K_BLOCKS} 0 sha256 ${VERITY_ROOT_HASH} ${VERITY_SALT} 1 check_at_most_once"

    BOOT_ARGS=(
        -M tegra186
        -cpu cortex-a57
        -smp 4
        -m 4096M
        -kernel "${KERNEL_IMG}"
        -dtb "${DTB_FILE}"
        -append "earlycon=uart8250,mmio32,0x031f0000 console=ttyS0,115200 dm=\"${DM_ARGS}\" root=/dev/dm-0 gpt gpt_sector=0x7000 loglevel=3 no_console_suspend=1 fsck.repair=yes rootwait earlyprintk ignore_loglevel"
        -display none
        -serial stdio
        -no-reboot
    )

    echo "[*] Launching Tegra186 QEMU (dm-verity mode)..."
    echo "[*] QEMU binary:     ${QEMU_BIN}"
    echo "[*] Kernel:          ${KERNEL_IMG}"
    echo "[*] DTB:             ${DTB_FILE}"
    echo "[*] Disk image:      ${ROOTFS_IMG}"
    echo "[*] Disk size:       ${DISK_SIZE_BYTES} bytes (${TOTAL_SECTORS} sectors)"
    echo "[*] Block mode:      512-byte sectors (GPT partition scanning)"
    echo "[*] Root hash:       ${VERITY_ROOT_HASH}"
    echo "[*] Salt:            ${VERITY_SALT}"
    echo "[*] dm= args:        ${DM_ARGS}"
    echo "[*] root:            /dev/dm-0 (dm-verity verified)"
else
    # Default mode: root=/dev/vblkdev0 (raw ext4, no dm-verity)
    BOOT_ARGS=(
        -M tegra186
        -cpu cortex-a57
        -smp 4
        -m 4096M
        -kernel "${KERNEL_IMG}"
        -dtb "${DTB_FILE}"
        -append "earlycon=uart8250,mmio32,0x031f0000 console=ttyS0,115200 root=/dev/vblkdev0 rootfstype=ext4 ro init=/sbin/init rootwait earlyprintk ignore_loglevel"
        -display none
        -serial stdio
        -no-reboot
    )

    echo "[*] Launching Tegra186 QEMU (direct ext4 mode)..."
    echo "[*] QEMU binary: ${QEMU_BIN}"
    echo "[*] Kernel:      ${KERNEL_IMG}"
    echo "[*] DTB:         ${DTB_FILE}"
    echo "[*] Rootfs:      ${ROOTFS_IMG}"
    echo "[*] root:        /dev/vblkdev0 (raw ext4, no dm-verity)"
fi

if [[ -f "${ROOTFS_IMG}" ]]; then
    BOOT_ARGS+=(-drive "file=${ROOTFS_IMG},if=none,format=raw,id=rootfs")
fi

if [[ -n "${TIMEOUT}" ]]; then
    echo "[*] Timeout:     ${TIMEOUT} seconds"
    set +e
    timeout --preserve-status "${TIMEOUT}" "${QEMU_BIN}" "${BOOT_ARGS[@]}" "${EXTRA_ARGS[@]}"
    RET=$?
    # timeout exit code 124 is normal when hitting bounded duration
    if [[ ${RET} -eq 124 ]]; then
        echo "[*] QEMU execution timed out after ${TIMEOUT}s as requested."
        exit 0
    fi
    exit ${RET}
else
    exec "${QEMU_BIN}" "${BOOT_ARGS[@]}" "${EXTRA_ARGS[@]}"
fi
