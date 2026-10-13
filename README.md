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

You need:
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

## Testing

A 15-test E2E regression suite is included:

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
