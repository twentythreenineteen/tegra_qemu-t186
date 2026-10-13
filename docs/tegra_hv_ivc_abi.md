# Tegra Hypervisor (tegra_hv) / IVC / HSP — Guest↔Hypervisor ABI

**Status:** Research deliverable (Option A — minimal hypervisor stub). Source-verified where possible,
reverse-engineered-from-binary where noted. NOT yet edited into QEMU.

---

## 1. Executive summary

The T186 vendor kernel (`Image-4.9.299-tegra`) is a **hypervisor-guest kernel**. Its only usable storage
path is `CONFIG_TEGRA_HV_BLKDEV=y` → `tegra_hv_vblk`, which talks to a hypervisor over **IVC
(Inter-VM Communication)** shared-memory queues. The first, hard failure in the current QEMU boot is:

```
[ 1.293129] tegra_hv: Failed to read guest id      <- HVC #3 returned an error
[ ...     ] tegra_hv: get_hvd: not initialized yet  <- forever after
[ 9.398255] tegra_hv_vblk tegra_virt_storage0: Failed to reserve IVC channel 66
...
VFS: Cannot open root device "(null)"
```

Root cause: **`HVC #3` ("read guest id") is unhandled by QEMU**, so the `tegra_hv` driver never
initializes its `hvd` (hypervisor device) global, and every later `tegra_hv_ivc_reserve()` returns
`-ENODEV` → no `/dev/vblkdev0` → VFS panic.

The hypervisor interface is **pure HVC** (no hypervisor MMIO). The `/hyp` DT node has no `reg`.
HSP MMIO (doorbells / shared mailboxes) is only needed *later* for data-transfer interrupts, not for
the initial reservation handshake.

---

## 2. Verified HVC call convention

Instruction encoding (standard AArch64): `HVC #imm16` = `0xD4000002 | (imm16 << 5)`.

Return convention observed across all hypercalls:

| Register | Meaning |
|---|---|
| `w0` | status: `0` = success, negative `errno` on failure |
| `x1..x6` | results (IPAs, counts, guest ids, etc.) — hypercall-specific |

All immediates below were extracted by direct byte-scan of the real kernel binary
(`md5 e8f439c50d9b706b59bb854c353e3c90`) for the `HVC` opcode, then cross-referenced against the
enclosing function's referenced diagnostic strings and register setup. **The inherited survey's
"#2/#3/#4/#5" guess is superseded.**

### 2.1 HVC immediate table

| Immediate | Name (recovered) | Call site(s) | Evidence / semantics |
|---|---|---|---|
| `#0` | (boot/firmware only) | `0xcc1c`, `0xcdc0`, `0x10000`… | Not tegra_hv; ignore |
| `#2` | **get IVC info page** | `0x161c9d4` (main probe) | `w0`=status, `x1`=**IPA of IVC info page**. Error string `tegra_hv: failed to obtain IVC info page: %d` |
| `#3` | **read guest id** | `0xa4c534`, `0xa562c4`, `0x161c93c` | `w0`=status, `w1`=**guest id**. Error `tegra_hv: Failed to read guest id` |
| `#4` | IVC mgr op (unreserve/reset variant) | `0xa53cfc` | in tegra_hv IVC manager cluster |
| `#5` | **read num guests** | `0xa562e0` (err-handler) | `w0`=status, `w1`=num guests. String `%s: can't read number of guests. Err %d` |
| `#6` | get shared/err mem for guest id | `0xa4c570` | `x0`=guest id, `x1`=base in/out; `w0`=status, `x1/x2`=addr |
| `#7` | IVC doorbell/notify | `0xa53274` | in IVC manager |
| `#9` | get system info | `0x161d71c` (hvc_sysfs) | `w0`=status, `x1`=IPA (reads `[x+0x850/858/860/868]`) |
| `#10` | **IVC operation** (reserve/unreserve/read/write/reset) | 6 sites `0xa5342c…0xa53be8` | `x0`=command code + args (see §3.2) |
| `#17` | get error memory address | `0xa56318` (err-handler) | `w0`=status, `x1`=base, `x2`=size, `w3/w4/w5`=sub-sizes |
| `#18` | vm-err ack / shutdown | `0xa56090` | `%s: Sending ack failed. Setting bad mode` |
| `#19` | vm-err reason/sample | `0xa55dd8`, `0xa55f68` | `%s: unexpected reason id %u`, `Synchronous/Asynchronous error on vcpu %u` |
| `#20` | vm-err offender/type | `0xa55e48`, `0xa55e88`, `0xa55ecc`, `0xa55f10`, `0xa55f48` | `%s: invalid offender id %u`, `%s: unexpected error Type %d` |
| `#289` | hvc_sysfs feature (trace/nvlog) | `0xa54df0`, `0x161d818` | feature query |
| `#290` | hvc_sysfs feature | `0xa54e18` | feature query |
| `#518` | hvc_sysfs (nvlog/trace) | `0x161d7a4` | optional |
| `#519` | hvc_sysfs (nvlog/trace) | `0x161d8f8` | optional |
| `#520` | hvc_sysfs (nvlog/trace) | `0x161d888` | optional |

> [!IMPORTANT]
> The **critical-for-boot** hypercalls are **`#3` (guest id) and `#2` (IVC info page)**. Without them
> `tegra_hv` never initializes. `#5`, `#17`, `#9`, `#289/#290/#518/#519/#520` are for the
> err-handler / hvc_sysfs drivers and are **optional** (their drivers log a warning and continue).
> `#10` is required once the guest starts actually doing IVC read/write against the vblk queue.

---

## 3. IVC info page + queue layout

### 3.1 Public BSD header (source-verified) — `include/linux/tegra-ivc.h`

```c
struct tegra_hv_ivc_cookie {
    int irq;            /* interrupt this channel uses (both rx/tx) */
    int peer_vmid;      /* guest id of the other end */
    int nframes;        /* number of frames in the queue */
    int frame_size;     /* frame size in bytes */
};

struct tegra_hv_ivc_ops {
    void (*rx_rdy)(struct tegra_hv_ivc_cookie *ivck);
    void (*tx_rdy)(struct tegra_hv_ivc_cookie *ivck);
};

struct tegra_hv_ivm_cookie {
    uint64_t ipa;
    uint64_t size;
    unsigned peer_vmid;
    void *reserved;
};
```

Public API (all backed by HVC #10 under the hood): `tegra_hv_ivc_reserve/unreserve/write/read/
can_read/can_write/tx_frames_available/tx_empty/set_loopback/dump/read_peek/
read_get_next_frame/read_advance/write_poke/write_get_next_frame/write_advance/
channel_notified/channel_reset`, plus `tegra_hv_mempool_reserve/unreserve`.
`tegra_hv_ivc_reserve()` returns `ERR_PTR(-EPROBE_DEFER)` until the IVC driver is loaded.

### 3.2 `struct ivc` / channel header — `include/linux/tegra-ivc-instance.h` (source-verified)

```c
#define IVC_ALIGN 64
struct ivc {
    struct ivc_channel_header *rx_channel, *tx_channel;   /* forward-declared only */
    uint32_t w_pos, r_pos;
    void (*notify)(struct ivc *);
    uint32_t nframes, frame_size;
    struct device *peer_device;
    dma_addr_t rx_handle, tx_handle;
};
```

> [!WARNING] `struct ivc_channel_header` is **proprietary / UNCONFIRMED**.
> It is only *forward-declared* at `tegra-ivc-instance.h:20`. Its field layout lives in
> NVIDIA's closed `tegra_hv_mgr.c` (not in the public `OE4T/linux-tegra-4.9` tree).
> Do **not** fabricate it. The generic `{ w_count; r_count; }` ring-header layout seen in
> mainline `tegra-ivc` (for the *local* non-hv IVC) is NOT source-verified for tegra_hv.

### 3.3 IVC "info page" layout — **recovered from disassembly of `tegra_hv_probe` @ `0x161c8a8`**

After `HVC #2` returns the info-page IPA in `x1`, the driver does:

```asm
161c9fc:  ioremap(x1, 0x1000)            ; map info page (1 page)
161ca24:  ldr w0, [x0, #4]               ; num_ivc = *(u32 *)(info_page + 4)
161ca74:  stride = 0x18 (24 bytes) per channel
161ca78:  x0 = info_page + 0x10          ; channel array base
161ca80:  ldr x0, [x0, idx*24]           ; rx_base (u64) @ entry + 0x00
161ca84:  ldr x1, [x1, #8]               ; tx_base (u64) @ entry + 0x08
161cac4:  ldr w1, [x3, #0x10]            ; frame_size (u32) @ entry + 0x10
161cad8:  ldr x0, [x1, #0x18]            ; offset (u64)    @ entry + 0x18
```

So the synthesized info page must look like:

```
struct tegra_hv_ivc_info_page {          // HVC #2 returns its IPA
    uint32_t num_queues;                 // +0x00  (second loop count, mempool/queue count)
    uint32_t num_ivc_channels;           // +0x04  (channel count)
    uint32_t pad[2];                     // +0x08
    struct {
        uint64_t rx_base;                // +0x00  IPA of RX shared-memory queue
        uint64_t tx_base;                // +0x08  IPA of TX shared-memory queue
        uint32_t frame_size;             // +0x10
        uint32_t rsvd;                   // +0x14
        uint64_t offset;                 // +0x18
    } channels[];                        // +0x10  (stride 0x18 = 24)
};
```

> [!NOTE] This layout is **recovered from the binary**, not from source. The two words at
> `+0x00`/`+0x04` and the 24-byte channel descriptor (`rx_base`, `tx_base`, `frame_size`, `offset`)
> are firmly established by the probe disassembly; the exact role of `+0x00` ("num_queues" vs
> "num_mempools") and `+0x18` ("offset") is inferred and should be validated empirically once QEMU
> serves the page.

---

## 4. HVC #10 — IVC operation sub-command encoding (recovered)

All six `HVC #10` sites build `x0` from a **command code in `x0[31:24]`** plus per-command args:

| `x0` value | Observed at | Likely operation (from tegra-ivc.h API call graph) |
|---|---|---|
| `0x00700000` | `0xa5342c` | channel reset / notify (x1 = 1) |
| `0x00900000` | `0xa535a8` | channel_reset variant (x1 = 1) |
| `0x00b00000 \| w18` | `0xa53704` | write/read advance (x0 = cmd \| frame idx) |
| `0x01100000` | `0xa53858` | queue poll / can_read-can_write |
| `0x04000000 \| w18` | `0xa53ac0` | IVC operation (mempool?) |
| `0x0e000000 \| w18` | `0xa53be8` | IVC operation (mempool?) |

> [!WARNING] The mapping of command-code → API function is **best-effort** (call-graph inference).
> The exact numeric sub-command encoding of the vblk *block I/O* protocol (config messages, read/write
> commands over the shared-memory queue) has **not** been reverse-engineered yet. This is the largest
> remaining unknown for a *functional* (not just probing) storage stub.

---

## 5. DTB facts (from `tegra186_qemu.dtb` decompile)

### 5.1 `/hyp` node — HVC-only, **no MMIO**
```
hyp { compatible = "nvidia,tegra-hv"; status = "okay"; phandle = <0x16>; }
```
All IVC references point at `<0x16 <channel>>` — hypervisor phandle + channel number. The `/chosen`
node carries `nvidia,tegra-hypervisor-mode;` (enables the hypervisor path) and a `root=/dev/dm-0`
bootarg referencing `/dev/vblkdev0p1`/`p2` via `dm=` verity.

### 5.2 Virtual storage channels (from DTB `tegra_virt_storage*` + serial log)
| Node | compatible | instance | `ivc` channel | mempool |
|---|---|---|---|---|
| `tegra_virt_storage0` | `nvidia,tegra-hv-storage` | 0 | **66** (`0x42`) | 9 |
| `tegra_virt_storage1` | `nvidia,tegra-hv-storage` | 2 | **67** (`0x43`) | 12 |
| `tegra_virt_storage7` | `nvidia,tegra-hv-storage` | 1 | **104** (`0x68`) | 14 |
| `tegra_virt_storage10` | `nvidia,tegra-hv-storage` | 3 | **113** (`0x71`) | 28 |
| `tegra_virt_storage2/3/4/5/6/9` | `nvidia,tegra-virt-mtd-storage` | — | 106–110, 112 | 21–27 |

Log matches exactly: `Failed to reserve IVC channel 66/67/104/113` (the `nvidia,tegra-hv-storage`
instances). MTD instances (106–110, 112) also fail later.

Other `tegra_hv_*` consumers (optional): comm (80), net (28), wdt (51), pm_ctl (200),
wdt_handler (204), mobis (202), alt-pcm (56), hv-i2c (53). None of these block boot.

### 5.3 HSP (doorbell / shared mailbox) — needed only for data-transfer interrupts
```
tegra-hsp@b150000  compatible=nvidia,tegra186-hsp  reg=0xb150000/0x90000  irq=SPI 0x8d ("shared1")  reset=0xba
tegra-hsp@c150000  compatible=nvidia,tegra186-hsp  reg=0xc150000/0x90000  irq=SPI 0x85 ("shared1")
tegra-hsp@3c00000  compatible=nvidia,tegra186-hsp  reg=0x3c00000/0xa0000  irq=SPI 0x78 ("shared0")
```
HSP register offsets (mainline `drivers/mailbox/tegra-hsp.c`, source-verified):
`HSP_INT_IE(x)=0x100+x*4`, `HSP_INT_IV=0x300`, `HSP_INT_IR=0x304`, `HSP_INT_DIMENSIONING=0x380`;
per-doorbell `TRIGGER=0x0/ENABLE=0x4/RAW=0x8/PENDING=0xc`; shared mailbox `SHRD_MBOX=0x0 (FULL=bit31)`.

### 5.4 Guest id
`nvidia,vmid = <0x03>` appears on the GPU node (line 7493) and `<0x01>` elsewhere. The authoritative
guest id is whatever `HVC #3` returns — **recommend returning `1`** (a typical service-VM id), but
this must match the hypervisor-side channel `peers` configuration (§7).

---

## 6. Minimal QEMU surface (what to stub)

### 6.1 Immediate (unblocks probe → `/dev/vblkdev0` appears, but no I/O yet)
1. **Run guest with EL2 present** (e.g. `-cpu max`/`cortex-a57` with `virtualization=on`), OR
   intercept `HVC`-at-EL1 as a decoded sync exception and emulate. A true stub means providing a
   minimal EL2 vector that traps `HVC` and returns values.
2. **`HVC #3`** → `x0 = 0`, `x1 = <guest_id>` (try `1`).
3. **`HVC #2`** → `x0 = 0`, `x1 = IPA` of a synthesized info page (§3.3) that lists at least the
   vblk channels 66/67/104/113 with valid `rx_base`/`tx_base` IPAs + `frame_size`.
4. **`HVC #5`** → `x0 = 0`, `x1 = <num_guests>` (e.g. `2`).
5. **`HVC #10`** → return success (`x0 = 0`) for `channel_reset`/`reserve` commands; defer the
   actual data-plane until the block protocol is implemented.

### 6.2 Required for actual storage I/O (larger, later)
- Implement the **vblk IVC block protocol** (config handshake + read/write) over the shared-memory
  ring queues, and **HSP doorbell** MMIO at `0xb150000/0xc150000/0x3c00000` to deliver rx/tx
  interrupts. This is substantial and **not yet reverse-engineered** (see §4 warning).

---

## 7. Evidence index

| Item | Description |
|---|---|
| Kernel binary | `Image-4.9.299-tegra` (vendor kernel, md5 `e8f439c50d9b706b59bb854c353e3c90`) |
| HVC byte scan | Opcode scan of ARM64 `HVC` instructions |
| String→HVC map | Diagnostic string correlation |
| Main probe disasm | Kernel function `0x161c8a8` disassembly |
| HVC #10 disasm | Disassembly of HVC #10 dispatcher |
| Public header | `include/linux/tegra-ivc.h`, `include/linux/tegra-ivc-instance.h` (OE4T/linux-tegra-4.9) |
| DTB decompile | `tegra186_qemu.dts` |
| Serial log | Serial console boot log |

---

## 8. Honesty / open questions

1. **`struct ivc_channel_header` is proprietary** — not in the public tree; layout UNCONFIRMED.
2. **IVC info-page field semantics** (`+0x00`, `+0x18`) are recovered from disasm, not source.
3. **HVC #10 command-code semantics** are best-effort (call-graph inference); the **vblk block I/O
   protocol is NOT yet reverse-engineered** — that is the critical next research task for a *working*
   storage stub (vs. a probe-only stub that just unblocks `/dev/vblkdev0` registration).
4. The **hypervisor `.c` sources** (`tegra_hv.c`, `tegra_hv_mgr.c`, `tegra186-hsp.c`, `tegra_hv_vblk.c`)
   are NVIDIA VDK/proprietary and **absent** from the public `linux-tegra-4.9` tree. Only the
   BSD-licensed IVC header and the DT binding are public.
