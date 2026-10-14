/*
 * NVIDIA Tegra186 Hypervisor (tegra_hv) and IVC Definitions.
 *
 * Copyright (c) 2026 QEMU contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef HW_ARM_TEGRA186_HV_H
#define HW_ARM_TEGRA186_HV_H

#include "target/arm/cpu.h"

#include "hw/irq.h"

#define TEGRA186_IVM_CARVEOUT_BASE  0x70c00000ULL
#define TEGRA186_IVM_CARVEOUT_SIZE  0x04c00000ULL /* 76 MiB */

#define TEGRA186_IVC_INFO_IPA       TEGRA186_IVM_CARVEOUT_BASE
#define TEGRA186_GIVCI_BASE_IPA     0x70c10000ULL
#define TEGRA186_GIVCI_SIZE         0x00100000ULL /* 1 MiB */
#define TEGRA186_MEMPOOL9_IPA       0x70d00000ULL
#define TEGRA186_MEMPOOL9_SIZE      0x00200000ULL /* 2 MiB */

#define TEGRA186_GUEST_ID_PRIMARY   1
#define TEGRA186_NUM_GUESTS         2

#define TEGRA_HV_IVC_STATE_ESTABLISHED 0
#define TEGRA_HV_IVC_STATE_SYNC        1
#define TEGRA_HV_IVC_STATE_ACK         2

/*
 * Virtual block device (tegra_hv_vblk) protocol definitions
 */
#define TEGRA_HV_VBLK_CMD_READ        1
#define TEGRA_HV_VBLK_CMD_GET_CONFIG  2

#define TEGRA_HV_VBLK_OP_READ         1
#define TEGRA_HV_VBLK_OP_WRITE        2
#define TEGRA_HV_VBLK_OP_FLUSH        5
#define TEGRA_HV_VBLK_OP_DISCARD      6

#define TEGRA_HV_VBLK_DEV_TYPE_BLOCK  1
#define TEGRA_HV_VBLK_BLOCK_SIZE      4096
#define TEGRA_HV_VBLK_TOTAL_BLOCKS    3004416ULL
#define TEGRA_HV_VBLK_TOTAL_SECTORS   24035328ULL
#define TEGRA_HV_VBLK_MAX_BLOCKS      16

/*
 * Info Page structures
 */
struct QEMU_PACKED tegra_hv_ivc_info_header {
    uint32_t num_queues;   /* +0x00: 4 */
    uint32_t num_givci;    /* +0x04: 1 */
    uint32_t num_mempools; /* +0x08: 1 */
    uint32_t pad;          /* +0x0c: 0 */
};

struct QEMU_PACKED tegra_hv_ivc_givci_desc {
    uint64_t base_ipa;     /* +0x00: 0x70c10000ULL */
    uint64_t size;         /* +0x08: 0x100000ULL (1 MiB) */
    uint32_t guest_id;     /* +0x10: 1 */
    uint32_t offset;       /* +0x14: 0 */
};

struct QEMU_PACKED tegra_hv_ivc_queue_desc {
    uint32_t channel_id;   /* +0x00: e.g. 66 */
    uint32_t peer_vmid_1;  /* +0x04: 1 */
    uint32_t peer_vmid_2;  /* +0x08: 0 */
    uint32_t size;         /* +0x0c: 0x1000 */
    uint32_t nframes;      /* +0x10: 16 */
    uint32_t frame_size;   /* +0x14: 64 */
    uint32_t offset;       /* +0x18: e.g. 0x1000 */
    uint16_t irq;          /* +0x1c: GIC SPI + 32, e.g. 141 */
    uint16_t reserved;     /* +0x1e: 0 */
};

struct QEMU_PACKED tegra_hv_ivc_mempool_desc {
    uint32_t vpr;          /* +0x00: 0 = standard (not VPR; 1 = VPR) */
    uint32_t flags;        /* +0x04: 0 */
    uint64_t ipa;          /* +0x08: 0x70d00000ULL */
    uint64_t size;         /* +0x10: 0x200000ULL (2 MiB) */
    uint32_t pool_id;      /* +0x18: 9 (checked by tegra_hv_mempool_reserve and printk) */
    uint32_t peer_vmid;    /* +0x1c: 0 */
};

struct QEMU_PACKED tegra_hv_ivc_channel_header {
    /* Cache line 0 (Writer) */
    uint32_t w_count;      /* +0x00 */
    uint32_t state;        /* +0x04: 0 = ESTABLISHED */
    uint8_t  pad0[56];     /* +0x08 .. +0x3f */

    /* Cache line 1 (Reader) */
    uint32_t r_count;      /* +0x40 */
    uint8_t  pad1[60];     /* +0x44 .. +0x7f */
};

struct QEMU_PACKED tegra_hv_vblk_config_resp_frame {
    uint32_t req_id;          /* +0x00: echoed */
    uint32_t type;            /* +0x04: 2 */
    uint32_t rsvd0[5];        /* +0x08 .. +0x1b */
    uint32_t status;          /* +0x1c: 0 (success) */
    uint32_t rsvd1;           /* +0x20: 0 */
    uint32_t dev_type;        /* +0x24: 1 (block device) */
    uint32_t block_size;      /* +0x28: 4096 (TEGRA_HV_VBLK_BLOCK_SIZE) */
    uint32_t max_read_blocks; /* +0x2c: 16 (TEGRA_HV_VBLK_MAX_BLOCKS) */
    uint32_t max_write_blocks;/* +0x30: 16 (TEGRA_HV_VBLK_MAX_BLOCKS) */
    uint32_t flags;           /* +0x34: 0x0f (rw + flushable) */
    uint64_t total_blocks;    /* +0x38: 4K-block count (default 3004416, overridable via TEGRA_VBLK_TOTAL_BLOCKS env) */
};

struct QEMU_PACKED tegra_hv_vblk_io_resp_frame {
    uint32_t req_id;          /* +0x00: echoed req_id */
    uint32_t type;            /* +0x04: 1 */
    uint32_t rsvd0[5];        /* +0x08 .. +0x1b */
    uint32_t status;          /* +0x1c: 0 (success) */
    uint32_t rsvd1;           /* +0x20: 0 */
    uint32_t completed_blocks;/* +0x24: num_blocks transferred */
    uint8_t  pad[24];         /* +0x28 .. +0x3f */
};

void tegra186_hv_init(void *ivm_ptr, qemu_irq ivc66_irq);
bool tegra186_hypercall_handler(ARMCPU *cpu, uint32_t imm16);
void tegra186_hv_process_channel66(void);

#endif /* HW_ARM_TEGRA186_HV_H */
