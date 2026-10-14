# Tegra186 (T186 / Parker) QEMU Port

This branch adds a **Tegra186 (T186 / Parker)** machine model to QEMU, including a
minimal NVIDIA hypervisor (tegra_hv) emulation layer that allows the vendor
`Image-4.9.299-tegra` kernel to boot end-to-end and mount its ext4 rootfs from a
virtual block device (`/dev/vblkdev0`).

It builds on the existing `tegrax1` / `tegrax1plus` machine models in
[`yellows8/tegra_qemu`](https://github.com/yellows8/tegra_qemu) and does **not**
modify those machine models.

## What's included

| File | Description |
|---|---|
| `hw/arm/tegra2/tegra186.c` | Tegra186 machine model: 4× Cortex-A57, GICv2, UART, RAM, PSCI, `arm_load_kernel()` |
| `hw/arm/tegra2/tegra186_hv.c` | Minimal NVIDIA hypervisor stub: HVC trap handler, IVC info page synthesis, IVC shared-memory channels, `tegra_hv_vblk` virtual block device protocol engine |
| `hw/arm/tegra2/tegra186_hv.h` | IVC / vblk structures, constants, and function declarations |
| `hw/arm/tegra2/meson.build` | Build registration (1 line added) |
| `configure` | Build fix: `tests/tcg/$config_host_mak` path duplication (6 lines) |

## Features

- **Machine model**: `-M tegra186` with 4× Cortex-A57, GICv2 @ `0x03881000`/`0x03892000`,
  8250 MMIO UART @ `0x031F0000` (regshift 2), 4 GiB RAM @ `0x80000000`, PSCI v1.1.
- **Hypervisor stub**: Traps `HVC #2` (IVC info page), `HVC #3` (guest id),
  `HVC #5` (num guests), `HVC #10` (IVC operations) via a generic ARM hypercall hook.
- **IVC emulation**: Synthesized IVC info page at `0x70c00000` (76 MiB carveout),
  GIVCI region, 4 storage queues (channels 66, 67, 104, 113), Mempool 9 DMA buffer.
- **Virtual block device**: `tegra_hv_vblk` protocol engine on Channel 66 supporting
  `VBLK_CMD_GET_CONFIG`, `VBLK_CMD_READ`, `VBLK_CMD_WRITE`, `VBLK_CMD_FLUSH`,
  backed by a raw ext4 image file. Interrupts via GIC SPI 109 (INTID 141).
- **Verified boot**: Kernel boots to userspace (`systemd`, `mini-init`, services),
  rootfs mounts as `EXT4-fs (vblkdev0)`.

## Building

```bash
# In a Debian/Ubuntu WSL environment
mkdir build && cd build
../configure --target-list=aarch64-softmmu
ninja -j$(nproc) qemu-system-aarch64
```

Verify the machine is registered:

```bash
./qemu-system-aarch64 -machine help | grep tegra
# Should show: tegra186, tegrax1, tegrax1plus
```

## Running

The canonical way to boot is the launch script, which sets all machine,
bootargs, and device options consistently:

```bash
export ROOTFS=/path/to/rootfs_ext4.img   # or a verity disk image with --verity
./launch_tegra186.sh [flags] [extra qemu args...]
```

| Flag | Meaning | Default |
|---|---|---|
| `--verity` | Boot with dm-verity (`root=/dev/dm-0`). See [dm-verity boot](#dm-verity-boot-verified-rootfs). | off (direct ext4, `root=/dev/vblkdev0`) |
| `--display MODE` | Host display backend: `sdl`, `gtk`, `vnc`, `none`, `cocoa`. | `none` (headless, serial on stdio) |
| `--usb-disk PATH` | Attach a raw disk image as USB mass storage. | disabled |
| `--audio` | Attach a USB audio device (`usb-audio`). | disabled |
| `-t SECONDS` / `--timeout=SECONDS` | Stop the run after N seconds. | none |
| *anything else* | Passed through to `qemu-system-aarch64` as extra args. | — |

Environment variables: `QEMU` (binary), `KERNEL` (kernel Image), `DTB`
(device tree blob), `ROOTFS` (rootfs or disk image), `USB_DISK` (same as
`--usb-disk`), `AUDIO_BACKEND` (`-audiodev` backend for `--audio`, default
`none`), `VERITY_ROOT_HASH` and `VERITY_SALT` (dm-verity overrides).

The launch script's built-in defaults point at a developer's local layout.
Always set `QEMU`, `KERNEL`, and `ROOTFS` explicitly for your own machine.

Examples:

```bash
# Direct ext4 boot, headless
./launch_tegra186.sh

# dm-verity boot with an SDL display window
./launch_tegra186.sh --verity --display sdl

# Add a USB mass-storage drive (guest sees /dev/sda) and USB audio
./launch_tegra186.sh --usb-disk /path/to/usb_disk.img --audio
```

### Raw QEMU invocation (reference)

The launch script wraps the following. You need:
1. **Kernel**: `Image-4.9.299-tegra` (NVIDIA L4T 4.9 kernel for T186)
2. **DTB**: `tegra186_qemu.dtb` (included in this repo, or generate from `tegra186_qemu.dts`)
3. **Rootfs**: An ext4 image file (e.g., NVIDIA L4T sample rootfs). **Not included** —
   you must provide your own.

```bash
export TEGRA_ROOTFS_IMG="/path/to/rootfs_ext4.img"
./qemu-system-aarch64 \
    -M tegra186 \
    -kernel Image-4.9.299-tegra \
    -dtb tegra186_qemu.dtb \
    -m 4096M -smp 4 \
    -append "earlycon=uart8250,mmio32,0x031f0000 console=ttyS0 root=/dev/vblkdev0 rootfstype=ext4 ro init=/sbin/init rootwait" \
    -nographic
```

The vblk backend reads from the ext4 image path specified by the `TEGRA_ROOTFS_IMG` environment variable (defaults to `rootfs_ext4.img` in the working directory if unset).

### dm-verity boot (verified rootfs)

The tegra186 port supports **full dm-verity** boot — the kernel verifies every
block of the rootfs against a SHA-256 hash tree before mounting. This matches
the NVIDIA factory boot flow where the bootloader passes `dm=` kernel arguments
to set up a device-mapper verity target.

#### Two boot modes

| Mode | Flag | Root device | Bootargs |
|---|---|---|---|
| Direct ext4 (default) | *(none)* | `/dev/vblkdev0` | `root=/dev/vblkdev0 rootfstype=ext4 ro` |
| dm-verity | `--verity` | `/dev/dm-0` | `dm="1 vroot none ro 1,0 ... verity 1 /dev/vblkdev0p1 /dev/vblkdev0p2 4096 4096 ... sha256 <root_hash> <salt> 1 check_at_most_once" root=/dev/dm-0 gpt` |

#### Building a verity disk image

Use `tools/build_verity_disk.py` to assemble a GPT-partitioned disk image from
a raw ext4 data image and a dm-verity hash tree image:

```bash
python3 tools/build_verity_disk.py \
    /path/to/data_ext4.img \
    /path/to/verity_hash.img \
    /path/to/verity_disk.img
```

The resulting image has:
- **Partition 1**: ext4 data (the rootfs content)
- **Partition 2**: dm-verity hash tree (raw, no superblock)
- Standard GPT layout (protective MBR, primary/backup GPT headers)

#### Launching with dm-verity

```bash
export ROOTFS=/path/to/verity_disk.img
./launch_tegra186.sh --verity
```

The launch script automatically:
1. Enables 512-byte sector mode (`TEGRA_VBLK_SECTOR_MODE=1`) so the kernel's
   GPT partition scanner works correctly.
2. Computes `TEGRA_VBLK_TOTAL_BLOCKS` from the disk image size in 512-byte
   sectors (so the vblk backend reports correct disk geometry to the guest).
3. Sets `dm=` kernel bootargs with the factory root hash and salt.
4. Sets `root=/dev/dm-0` so the kernel mounts the verified device.

Override the factory hash/salt via environment variables:
```bash
export VERITY_ROOT_HASH="<your_root_hash>"
export VERITY_SALT="<your_salt>"
./launch_tegra186.sh --verity
```

#### How it works

- QEMU serves the GPT disk image via the `tegra_hv_vblk` virtual block device.
- In verity mode, the vblk backend uses **512-byte sector mode**
  (`TEGRA_VBLK_SECTOR_MODE=1`) so the kernel's GPT partition scanner can
  correctly read partition table entries at 512-byte boundaries.
- The guest kernel parses GPT partitions (`CONFIG_EFI_PARTITION=y`), creating
  `/dev/vblkdev0p1` (data) and `/dev/vblkdev0p2` (hash tree).
- The `dm=` bootargs instruct the kernel's built-in device-mapper to create a
  `verity` target (`/dev/dm-0`) that transparently verifies each 4K block
  against the SHA-256 hash tree before passing it to the ext4 filesystem.
- **No QEMU-side crypto is needed** — all verification happens in the guest kernel.

## Peripherals

### Host display (`--display`)

`--display MODE` selects the QEMU display backend: `sdl`, `gtk`, `vnc`,
`none`, or `cocoa` (cocoa is macOS-only). The default is `none`, which is
headless with the serial console on stdio. Any value other than these is
rejected by the launch script.

### USB mass storage (`--usb-disk PATH`)

`--usb-disk PATH` attaches a raw disk image as a `usb-storage` device on the
existing XHCI USB 3.0 controller. The guest should see it as `/dev/sdX`
(typically `/dev/sda`). The flag is disabled unless a path is given. The
`USB_DISK` environment variable is equivalent.

This only attaches the storage device. USB host enumeration and bring-up on
the XHCI controller are owned by the separate USB/host-emulation workstream.

### USB audio (`--audio`)

`--audio` attaches a `usb-audio` device (a USB sound card) to the XHCI bus.
It is **off by default**. USB host enumeration on XHCI is not yet confirmed
working, so audio stays opt-in until that is validated.

The host backend is chosen with `AUDIO_BACKEND` (default `none`, a silent null
backend that needs no host audio device). The script emits
`-audiodev ${AUDIO_BACKEND},id=usbaudio0`, so `AUDIO_BACKEND=wav` selects QEMU's
wav backend. The script does not set a wav output path, so custom capture
paths are not wired in yet; that would need a script change.

## Guest-side tools: openccnc_vnc

`tools/openccnc_vnc/` contains guest payloads for screen capture, touch
injection, and a browser web UI. **These run INSIDE the Tegra186 guest, not on
the QEMU host.** They are not a host-side VNC server.

| Script | Role |
|---|---|
| `frame_server.py` | Captures frames from the guest Wayland socket and serves them over HTTP, along with a tap/swipe and action UI. |
| `uinput_touch.py` | Virtual multitouch touchscreen on `/dev/uinput`, stdlib only. |
| `actions.py` | D-Bus action registry for web UI buttons. |
| `send_keypress.py` | Sends a key event over D-Bus via `ccos.api.hiac`. |

Dependencies on the guest: Python 3 stdlib, plus `python3-dbus` for the D-Bus
scripts. See [`tools/openccnc_vnc/README.md`](tools/openccnc_vnc/README.md).

To run inside the guest after copying the directory onto it:

```sh
# Serve the web UI on port 8080 at 2x downscale
python3 frame_server.py 8080 2

# Send a single tap at guest pixel coordinates (500, 300)
python3 uinput_touch.py 500 300
```

## Testing

A 16-test E2E regression suite is included:

```bash
bash tests/tegra186_e2e/run_all_tests.sh
```

## Reverse-engineered ABI

The hypervisor/IVC ABI was recovered by disassembling the vendor kernel binary.
The full specification is documented in [`docs/tegra_hv_ivc_abi.md`](docs/tegra_hv_ivc_abi.md).

## License

GPL-2.0-only, consistent with QEMU's license. See individual file headers.

## Credits

Developed with AI-assisted reverse engineering and implementation. The ABI was
recovered clean-room from the `Image-4.9.299-tegra` binary; no proprietary NVIDIA
source code was used.
