#!/usr/bin/env bash
# launch_tegra186.sh - Launch QEMU Tegra186 Parker Emulation under Debian WSL
#
# This is the ONE canonical launch script. tegra_qemu/launch_tegra186.sh is a
# byte-identical copy of this file (keep them in sync).
#
# Usage:
#   ./launch_tegra186.sh [--verity] [--display MODE] [--usb-disk PATH]
#                        [--audio] [-t SECONDS] [extra qemu args...]
#
# Modes:
#   Default (no --verity): Boots with root=/dev/vblkdev0 (raw ext4, no dm-verity).
#     Expects ROOTFS to point to a raw ext4 image (e.g. 1_gos1-fs_7_ext4.img).
#
#   --verity: Boots with root=/dev/dm-0 (full dm-verity verification).
#     Expects ROOTFS to point to a GPT-partitioned disk image
#     (assembled by tools/build_verity_disk.py) containing:
#       Partition 1: ext4 data image (gos1-fs)
#       Partition 2: dm-verity hash tree (verity_rootfs_hash)
#     Uses 512-byte sector mode (TEGRA_VBLK_SECTOR_MODE=1) so the kernel's
#     GPT partition scanner can find /dev/vblkdev0p1 and /dev/vblkdev0p2.
#     Also sets TEGRA_VBLK_TOTAL_BLOCKS to the total 512-byte sector count
#     of the disk image so the vblk backend reports correct disk geometry.
#
#   --display MODE: Host display backend (sdl, gtk, vnc, none, cocoa).
#     Default: none (headless, serial console on stdio).
#
#   --usb-disk PATH: Attach PATH (raw disk image) as a USB mass-storage device
#     (usb-storage) on the existing XHCI USB 3.0 controller. The guest should
#     see it as /dev/sdX (typically /dev/sda). Default: DISABLED (no path given).
#     Also settable via the USB_DISK environment variable. This only attaches a
#     storage drive; USB host enumeration/bring-up is owned by the WS1 team.
#
#   --audio: Attach a USB audio device (usb-audio, a USB sound card) to the
#     existing XHCI bus. Default: DISABLED (OFF). Rationale: USB host
#     enumeration of devices on the XHCI controller is not yet confirmed working
#     (owned by a separate team), so audio is opt-in until that is validated.
#     The device uses the host audio backend selected by AUDIO_BACKEND
#     (default "none" = a silent null backend that needs no host audio device;
#     set AUDIO_BACKEND=wav and/or add a wav path via EXTRA_ARGS for capture).
#
# Environment variables:
#   QEMU             - Path to qemu-system-aarch64 binary
#   KERNEL           - Path to kernel image
#   DTB              - Path to device tree blob
#   ROOTFS           - Path to rootfs/disk image (sets TEGRA_ROOTFS_IMG)
#   USB_DISK         - Raw disk image to attach as usb-storage (same as --usb-disk)
#   AUDIO_BACKEND    - -audiodev backend used by --audio (default: none)
#   VERITY_ROOT_HASH - Override the dm-verity root hash (default: factory value)
#   VERITY_SALT      - Override the dm-verity salt (default: factory value)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QEMU_BIN="${QEMU:-/home/owen/qemu-build-native-t186/qemu-system-aarch64}"
KERNEL_IMG="${KERNEL:-/mnt/c/Users/owens/tegra/Image-4.9.299-tegra}"
DTB_FILE="${DTB:-${SCRIPT_DIR}/tegra186_qemu.dtb}"
ROOTFS_IMG="${ROOTFS:-/mnt/d/ccnc/CCNC_SYSTEM_ALL_USA_0000_00_001_002_260508_090613/system/1_gos1-fs_7_ext4.img}"
export TEGRA_ROOTFS_IMG="${ROOTFS_IMG}"

# Factory dm-verity parameters (from vendor DTB bootargs)
VERITY_ROOT_HASH="${VERITY_ROOT_HASH:-5830e1d5ab8e48dff4e005a812f60b9244b007f0651eb8b0de6c1e518d1ffdb2}"
VERITY_SALT="${VERITY_SALT:-caa1129717e173bfcc27ec028cd8bb5b9471fb4b5d00db401d715b5a3cc4a238}"

AUDIO_BACKEND="${AUDIO_BACKEND:-none}"

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
DISPLAY_MODE="none"
VERITY_MODE=0
AUDIO_MODE=0
USB_DISK="${USB_DISK:-}"
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
        --display)
            DISPLAY_MODE="$2"
            shift 2
            ;;
        --display=*)
            DISPLAY_MODE="${1#*=}"
            shift
            ;;
        --verity)
            VERITY_MODE=1
            shift
            ;;
        --audio)
            AUDIO_MODE=1
            shift
            ;;
        --usb-disk)
            USB_DISK="$2"
            shift 2
            ;;
        --usb-disk=*)
            USB_DISK="${1#*=}"
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate display mode
VALID_DISPLAYS="sdl gtk vnc none cocoa"
if [[ -n "${DISPLAY_MODE}" && "${DISPLAY_MODE}" != "none" ]]; then
    if ! echo "${VALID_DISPLAYS}" | grep -qw "${DISPLAY_MODE}"; then
        echo "[-] Error: Invalid display mode '${DISPLAY_MODE}'." >&2
        echo "    Valid modes: ${VALID_DISPLAYS} (or omit for default 'none')" >&2
        exit 1
    fi
fi

# Validate USB disk path (only when provided)
if [[ -n "${USB_DISK}" && ! -f "${USB_DISK}" ]]; then
    echo "[-] Error: USB disk image not found at: ${USB_DISK}" >&2
    exit 1
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

    APPEND_ARGS="earlycon=uart8250,mmio32,0x031f0000 console=ttyS0,115200 dm=\"${DM_ARGS}\" root=/dev/dm-0 gpt gpt_sector=0x7000 loglevel=3 no_console_suspend=1 fsck.repair=yes rootwait earlyprintk ignore_loglevel"
else
    # Default mode: root=/dev/vblkdev0 (raw ext4, no dm-verity)
    APPEND_ARGS="earlycon=uart8250,mmio32,0x031f0000 console=ttyS0,115200 root=/dev/vblkdev0 rootfstype=ext4 ro init=/sbin/init rootwait earlyprintk ignore_loglevel"
fi

BOOT_ARGS=(
    -M tegra186
    -cpu cortex-a57
    -smp 4
    -m 4096M
    -kernel "${KERNEL_IMG}"
    -dtb "${DTB_FILE}"
    -append "${APPEND_ARGS}"
    -display "${DISPLAY_MODE}"
    -serial stdio
    -no-reboot
)

if [[ -f "${ROOTFS_IMG}" ]]; then
    BOOT_ARGS+=(-drive "file=${ROOTFS_IMG},if=none,format=raw,id=rootfs")
fi

# USB mass storage on the existing XHCI controller (disabled unless a path is given)
if [[ -n "${USB_DISK}" ]]; then
    BOOT_ARGS+=(-drive "file=${USB_DISK},if=none,format=raw,id=usbdisk0")
    BOOT_ARGS+=(-device usb-storage,drive=usbdisk0)
fi

# USB audio (usb-audio) on the existing XHCI bus. OFF by default; see header.
if [[ ${AUDIO_MODE} -eq 1 ]]; then
    BOOT_ARGS+=(-audiodev "${AUDIO_BACKEND},id=usbaudio0")
    BOOT_ARGS+=(-device usb-audio,audiodev=usbaudio0)
fi

echo "[*] Launching Tegra186 QEMU..."
echo "[*] QEMU binary: ${QEMU_BIN}"
echo "[*] Kernel:      ${KERNEL_IMG}"
echo "[*] DTB:         ${DTB_FILE}"
echo "[*] Rootfs:      ${ROOTFS_IMG}"
echo "[*] Display:     ${DISPLAY_MODE}"
if [[ ${VERITY_MODE} -eq 1 ]]; then
    echo "[*] Mode:          dm-verity (root=/dev/dm-0)"
    echo "[*] Disk size:     ${DISK_SIZE_BYTES} bytes (${TOTAL_SECTORS} sectors)"
    echo "[*] Block mode:    512-byte sectors (GPT partition scanning)"
    echo "[*] Root hash:     ${VERITY_ROOT_HASH}"
    echo "[*] Salt:          ${VERITY_SALT}"
    echo "[*] dm= args:      ${DM_ARGS}"
else
    echo "[*] Mode:          direct ext4 (root=/dev/vblkdev0, no dm-verity)"
fi
echo "[*] USB disk:    ${USB_DISK:-disabled}"
if [[ ${AUDIO_MODE} -eq 1 ]]; then
    echo "[*] USB audio:   enabled (audiodev=${AUDIO_BACKEND})"
else
    echo "[*] USB audio:   disabled (pass --audio to enable)"
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
