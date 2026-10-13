#!/usr/bin/env bash
# launch_tegra186.sh - Launch QEMU Tegra186 Parker Emulation under Debian WSL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_BIN="${QEMU:-./build/qemu-system-aarch64}"
KERNEL_IMG="${KERNEL:-./Image-4.9.299-tegra}"
DTB_FILE="${DTB:-${SCRIPT_DIR}/tegra186_qemu.dtb}"
# Rootfs image is NOT included in this repo. Set ROOTFS env var to your own ext4 image.
ROOTFS_IMG="${ROOTFS:-./rootfs_ext4.img}"
export TEGRA_ROOTFS_IMG="${ROOTFS_IMG}"

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

TIMEOUT=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
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

if [[ -f "${ROOTFS_IMG}" ]]; then
    BOOT_ARGS+=(-drive "file=${ROOTFS_IMG},if=none,format=raw,id=rootfs")
fi

echo "[*] Launching Tegra186 QEMU..."
echo "[*] QEMU binary: ${QEMU_BIN}"
echo "[*] Kernel:      ${KERNEL_IMG}"
echo "[*] DTB:         ${DTB_FILE}"
echo "[*] Rootfs:      ${ROOTFS_IMG}"
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
