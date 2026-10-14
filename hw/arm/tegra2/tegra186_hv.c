/*
 * NVIDIA Tegra186 Hypervisor (tegra_hv) and IVC Emulation.
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

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qemu/timer.h"
#include "target/arm/cpu.h"
#include "tegra186_hv.h"
#include <fcntl.h>
#include <unistd.h>

static uint8_t *s_ivm_base = NULL;
static uint8_t *s_mempool9_ptr = NULL;
static qemu_irq s_ivc66_irq = NULL;
static int s_rootfs_fd = -1;
static QEMUTimer *s_vblk_timer = NULL;
static uint64_t s_total_blocks = TEGRA_HV_VBLK_TOTAL_BLOCKS;
static bool s_sector_mode = false;

static uint64_t tegra186_hv_get_total_blocks(void)
{
    const char *env = getenv("TEGRA_VBLK_TOTAL_BLOCKS");
    if (env && env[0]) {
        uint64_t val = strtoull(env, NULL, 0);
        if (val > 0) {
            return val;
        }
    }
    return s_total_blocks;
}

/*
 * Sector mode: when enabled (TEGRA_VBLK_SECTOR_MODE=1), the vblk device
 * reports block_size=512 and total_blocks in 512-byte sectors. This is
 * required for GPT partition scanning, which the kernel performs using
 * 512-byte sector reads. In default mode (4K blocks), partition scanning
 * reads the wrong offsets and fails to find partitions.
 */
static bool tegra186_hv_get_sector_mode(void)
{
    const char *env = getenv("TEGRA_VBLK_SECTOR_MODE");
    if (env && env[0]) {
        return (strcmp(env, "1") == 0 || strcmp(env, "true") == 0 ||
                strcmp(env, "yes") == 0);
    }
    return s_sector_mode;
}

static uint32_t tegra186_hv_get_block_size(void)
{
    return tegra186_hv_get_sector_mode() ? 512 : TEGRA_HV_VBLK_BLOCK_SIZE;
}

static void tegra186_vblk_timer_cb(void *opaque)
{
    tegra186_hv_process_channel66();
    timer_mod(s_vblk_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 1);
}

static void tegra186_hv_open_rootfs(void)
{
    if (s_rootfs_fd >= 0) {
        return;
    }
    const char *path = getenv("TEGRA_ROOTFS_IMG");
    if (!path || !path[0]) {
        path = "rootfs_ext4.img";
    }
    s_rootfs_fd = open(path, O_RDWR | O_CLOEXEC);
    if (s_rootfs_fd < 0) {
        s_rootfs_fd = open(path, O_RDONLY | O_CLOEXEC);
    }
    if (s_rootfs_fd < 0) {
        warn_report("tegra186_hv: unable to open rootfs image '%s': %s",
                    path, strerror(errno));
    }
}

void tegra186_hv_init(void *ivm_ptr, qemu_irq ivc66_irq)
{
    if (!ivm_ptr) {
        return;
    }

    uint8_t *ivm_base = (uint8_t *)ivm_ptr;
    s_ivm_base = ivm_base;
    s_mempool9_ptr = ivm_base + (TEGRA186_MEMPOOL9_IPA - TEGRA186_IVM_CARVEOUT_BASE);
    s_ivc66_irq = ivc66_irq;

    tegra186_hv_open_rootfs();

    /* Zero the Info Page (4 KiB) */
    memset(ivm_base, 0, 4096);

    /* 1. Info Page Header (offset 0x00) */
    struct tegra_hv_ivc_info_header *hdr = (struct tegra_hv_ivc_info_header *)(ivm_base + 0x00);
    hdr->num_queues = 4;
    hdr->num_givci = 1;
    hdr->num_mempools = 1;
    hdr->pad = 0;

    /* 2. GIVCI Descriptor Array (offset 0x10, stride 24 bytes) */
    struct tegra_hv_ivc_givci_desc *givci = (struct tegra_hv_ivc_givci_desc *)(ivm_base + 0x10);
    givci[0].base_ipa = TEGRA186_GIVCI_BASE_IPA; /* 0x70c10000ULL */
    givci[0].size = TEGRA186_GIVCI_SIZE;         /* 0x100000ULL (1 MiB) */
    givci[0].guest_id = 0;                       /* Peer VMID 0 (Hypervisor) */
    givci[0].offset = 0;

    /* 3. Queue Descriptors Array (offset 0x28, stride 32 bytes) */
    struct tegra_hv_ivc_queue_desc *queues = (struct tegra_hv_ivc_queue_desc *)(ivm_base + 0x28);

    /* Channel 66: tegra_virt_storage0 */
    queues[0].channel_id = 66;
    queues[0].peer_vmid_1 = 1;
    queues[0].peer_vmid_2 = 0;
    queues[0].size = 0x1000;
    queues[0].nframes = 16;
    queues[0].frame_size = 64;
    queues[0].offset = 0x1000;
    queues[0].irq = 141;
    queues[0].reserved = 0;

    /* Channel 67: tegra_virt_storage1 */
    queues[1].channel_id = 67;
    queues[1].peer_vmid_1 = 1;
    queues[1].peer_vmid_2 = 0;
    queues[1].size = 0x1000;
    queues[1].nframes = 16;
    queues[1].frame_size = 64;
    queues[1].offset = 0x3000;
    queues[1].irq = 142;
    queues[1].reserved = 0;

    /* Channel 104: tegra_virt_storage7 */
    queues[2].channel_id = 104;
    queues[2].peer_vmid_1 = 1;
    queues[2].peer_vmid_2 = 0;
    queues[2].size = 0x1000;
    queues[2].nframes = 16;
    queues[2].frame_size = 64;
    queues[2].offset = 0x5000;
    queues[2].irq = 143;
    queues[2].reserved = 0;

    /* Channel 113: tegra_virt_storage10 */
    queues[3].channel_id = 113;
    queues[3].peer_vmid_1 = 1;
    queues[3].peer_vmid_2 = 0;
    queues[3].size = 0x1000;
    queues[3].nframes = 16;
    queues[3].frame_size = 64;
    queues[3].offset = 0x7000;
    queues[3].irq = 144;
    queues[3].reserved = 0;

    /* 4. Mempools Array (offset 0xa8, stride 32 bytes) */
    struct tegra_hv_ivc_mempool_desc *mempool = (struct tegra_hv_ivc_mempool_desc *)(ivm_base + 0xa8);
    mempool[0].vpr = 0;                       /* 0 = standard memory (not VPR) */
    mempool[0].flags = 0;
    mempool[0].ipa = TEGRA186_MEMPOOL9_IPA;   /* 0x70d00000ULL */
    mempool[0].size = TEGRA186_MEMPOOL9_SIZE; /* 0x200000ULL (2 MiB) */
    mempool[0].pool_id = 9;                   /* Checked by tegra_hv_mempool_reserve and printk */
    mempool[0].peer_vmid = 0;

    /*
     * 5. Initialize GIVCI ring buffer queue headers.
     * GIVCI region starts at offset 0x10000 within the IVM carveout (0x70c10000 - 0x70c00000).
     * For each queue, initialize both writer (+0x00) and reader (+0x40) cache lines
     * for both halves (tx at givci + offset, rx at givci + offset + size).
     */
    uint8_t *givci_mem = ivm_base + 0x10000;

    for (int i = 0; i < 4; i++) {
        uint32_t q_offset = queues[i].offset;
        uint32_t q_size = queues[i].size;

        /* Half 0: Guest RX / Host TX */
        struct tegra_hv_ivc_channel_header *hdr0 =
            (struct tegra_hv_ivc_channel_header *)(givci_mem + q_offset);
        memset(hdr0, 0, sizeof(*hdr0));
        hdr0->w_count = 0;
        hdr0->state = TEGRA_HV_IVC_STATE_ESTABLISHED;
        hdr0->r_count = 0;

        /* Half 1: Guest TX / Host RX */
        struct tegra_hv_ivc_channel_header *hdr1 =
            (struct tegra_hv_ivc_channel_header *)(givci_mem + q_offset + q_size);
        memset(hdr1, 0, sizeof(*hdr1));
        hdr1->w_count = 0;
        hdr1->state = TEGRA_HV_IVC_STATE_ESTABLISHED;
        hdr1->r_count = 0;
    }

    /* Start periodic polling timer for Channel 66 requests */
    if (!s_vblk_timer) {
        s_vblk_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, tegra186_vblk_timer_cb, NULL);
        timer_mod(s_vblk_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 1);
    }
}

void tegra186_hv_process_channel66(void)
{
    if (!s_ivm_base) {
        return;
    }

    uint8_t *givci_mem = s_ivm_base + 0x10000;
    struct tegra_hv_ivc_channel_header *guest_rx =
        (struct tegra_hv_ivc_channel_header *)(givci_mem + 0x1000);
    struct tegra_hv_ivc_channel_header *guest_tx =
        (struct tegra_hv_ivc_channel_header *)(givci_mem + 0x2000);

    bool need_irq = false;

    /* Handle state machine sync/reset */
    if (guest_tx->state == TEGRA_HV_IVC_STATE_SYNC) {
        guest_rx->w_count = 0;
        guest_tx->r_count = 0;
        guest_rx->state = TEGRA_HV_IVC_STATE_ACK;
        need_irq = true;
    } else if (guest_tx->state == TEGRA_HV_IVC_STATE_ACK ||
               (guest_tx->state == TEGRA_HV_IVC_STATE_ESTABLISHED &&
                guest_rx->state == TEGRA_HV_IVC_STATE_ACK)) {
        guest_rx->state = TEGRA_HV_IVC_STATE_ESTABLISHED;
        need_irq = true;
    }

    /* Process pending frames */
    while (guest_tx->w_count != guest_tx->r_count) {
        uint32_t r_idx = guest_tx->r_count % 16;
        uint8_t *in_frame = ((uint8_t *)guest_tx) + 0x80 + r_idx * 64;

        uint32_t req_id = *(uint32_t *)(in_frame + 0x00);
        uint32_t type = *(uint32_t *)(in_frame + 0x04);
        uint32_t op = *(uint32_t *)(in_frame + 0x08);
        uint64_t start_block = *(uint64_t *)(in_frame + 0x0c);
        uint32_t num_blocks = *(uint32_t *)(in_frame + 0x14);
        uint32_t mempool_offset = *(uint32_t *)(in_frame + 0x18);

        fprintf(stderr, "[HV_VBLK] req_id=%u type=%u op=%u start=%llu num=%u offset=%u\n",
                req_id, type, op, (unsigned long long)start_block, num_blocks, mempool_offset);

        guest_tx->r_count++;

        uint32_t w_idx = guest_rx->w_count % 16;
        uint8_t *out_frame = ((uint8_t *)guest_rx) + 0x80 + w_idx * 64;
        memset(out_frame, 0, 64);

        if (type == TEGRA_HV_VBLK_CMD_GET_CONFIG) {
            struct tegra_hv_vblk_config_resp_frame *resp =
                (struct tegra_hv_vblk_config_resp_frame *)out_frame;
            resp->req_id = req_id;
            resp->type = 2;
            resp->status = 0;
            resp->dev_type = TEGRA_HV_VBLK_DEV_TYPE_BLOCK; /* 1 */
            resp->block_size = tegra186_hv_get_block_size();
            if (tegra186_hv_get_sector_mode()) {
                /* 512-byte sectors: 8 sectors = 4096 bytes per transfer */
                resp->max_read_blocks = TEGRA_HV_VBLK_BLOCK_SIZE / 512;  /* 8 */
                resp->max_write_blocks = TEGRA_HV_VBLK_BLOCK_SIZE / 512; /* 8 */
            } else {
                resp->max_read_blocks = TEGRA_HV_VBLK_MAX_BLOCKS; /* 16 */
                resp->max_write_blocks = TEGRA_HV_VBLK_MAX_BLOCKS; /* 16 */
            }
            resp->flags = 0x0f; /* bits 0..3: writable, readable, writable, flushable */
            resp->total_blocks = tegra186_hv_get_total_blocks();
            info_report("tegra_hv_vblk: registered /dev/vblkdev0 (%llu blocks x %u bytes, %.2f GiB, %s mode)",
                        (unsigned long long)resp->total_blocks,
                        resp->block_size,
                        (double)resp->total_blocks * resp->block_size / (1024.0 * 1024.0 * 1024.0),
                        tegra186_hv_get_sector_mode() ? "sector" : "4K-block");
        } else if (type == TEGRA_HV_VBLK_CMD_READ) {
            uint32_t blk_sz = tegra186_hv_get_block_size();
            if (op == TEGRA_HV_VBLK_OP_READ) {
                size_t bytes = (size_t)num_blocks * blk_sz;
                off_t offset = (off_t)start_block * blk_sz;
                if (s_mempool9_ptr && mempool_offset + bytes <= TEGRA186_MEMPOOL9_SIZE) {
                    uint8_t *dma_dest = s_mempool9_ptr + mempool_offset;
                    ssize_t nread = 0;
                    if (s_rootfs_fd >= 0) {
                        nread = pread(s_rootfs_fd, dma_dest, bytes, offset);
                    }
                    if (nread < (ssize_t)bytes) {
                        if (nread < 0) {
                            nread = 0;
                        }
                        memset(dma_dest + nread, 0, bytes - nread);
                    }
                } else {
                    warn_report("tegra186_hv: VBLK read DMA out of bounds: offset=%u bytes=%zu",
                                mempool_offset, bytes);
                }
            } else if (op == TEGRA_HV_VBLK_OP_WRITE) {
                size_t bytes = (size_t)num_blocks * blk_sz;
                off_t offset = (off_t)start_block * blk_sz;
                if (s_mempool9_ptr && mempool_offset + bytes <= TEGRA186_MEMPOOL9_SIZE) {
                    uint8_t *dma_src = s_mempool9_ptr + mempool_offset;
                    if (s_rootfs_fd >= 0) {
                        ssize_t nw = pwrite(s_rootfs_fd, dma_src, bytes, offset);
                        (void)nw;
                    }
                }
            } else if (op == TEGRA_HV_VBLK_OP_FLUSH) {
                if (s_rootfs_fd >= 0) {
                    fdatasync(s_rootfs_fd);
                }
            }
            struct tegra_hv_vblk_io_resp_frame *resp =
                (struct tegra_hv_vblk_io_resp_frame *)out_frame;
            resp->req_id = req_id;
            resp->type = 1;
            resp->status = 0;
            resp->rsvd1 = 0;
            resp->completed_blocks = num_blocks;
        }

        guest_rx->w_count++;
        need_irq = true;
    }

    if (need_irq && s_ivc66_irq) {
        qemu_set_irq(s_ivc66_irq, 1);
        qemu_set_irq(s_ivc66_irq, 0);
    }
}

bool tegra186_hypercall_handler(ARMCPU *cpu, uint32_t imm16)
{
    CPUARMState *env = &cpu->env;

    /* Always check channel 66 on hypercalls */
    tegra186_hv_process_channel66();

    switch (imm16) {
    case 3: /* read guest id */
        env->xregs[0] = 0; /* status: success */
        env->xregs[1] = TEGRA186_GUEST_ID_PRIMARY; /* guest id: 1 */
        return true;

    case 5: /* read num guests */
        env->xregs[0] = 0; /* status: success */
        env->xregs[1] = TEGRA186_NUM_GUESTS; /* num guests: 2 */
        return true;

    case 2: /* get IVC info page */
        env->xregs[0] = 0; /* status: success */
        env->xregs[1] = TEGRA186_IVC_INFO_IPA; /* 0x70c00000ULL */
        return true;

    case 4:  /* IVC channel notify / manager op */
    case 10: /* IVC operations (reserve, reset, poll, lifecycle) */
        env->xregs[0] = 0; /* status: success */
        return true;

    case 6:  /* get shared error memory */
    case 7:  /* get guest state */
    case 9:  /* get system info page */
    case 17: /* get error memory address */
    case 18: /* vm-err ack */
    case 19: /* vm-err reason */
    case 20: /* vm-err offender */
    case 289:
    case 290:
    case 518:
    case 519:
    case 520:
        env->xregs[0] = 0; /* status: success */
        return true;

    default:
        /* Unhandled hypercall, fall back to default */
        fprintf(stderr, "[HV] Unhandled HVC imm=%u x0=0x%lx x1=0x%lx\n",
                imm16, (unsigned long)env->xregs[0], (unsigned long)env->xregs[1]);
        return false;
    }
}
