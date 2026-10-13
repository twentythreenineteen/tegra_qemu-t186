/*
 * ARM NVIDIA Tegra186 (T186 / Parker) machine emulation.
 *
 * Copyright (c) 2026 QEMU contributors
 *
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/units.h"
#include "qemu/error-report.h"
#include "exec/address-spaces.h"
#include "hw/boards.h"
#include "hw/sysbus.h"
#include "hw/qdev-properties.h"
#include "hw/char/serial-mm.h"
#include "hw/intc/arm_gic.h"
#include "hw/arm/boot.h"
#include "hw/arm/bsa.h"
#include "hw/cpu/cluster.h"
#include "sysemu/sysemu.h"
#include "target/arm/cpu.h"
#include "target/arm/gtimer.h"
#include "target/arm/cpu-qom.h"
#include "tegra186_hv.h"

#define TEGRA186_UART_BASE          0x031F0000ULL
#define TEGRA186_UART_SIZE          0x40ULL
#define TEGRA186_UART_VENDOR_OFFSET 0x20ULL
#define TEGRA186_UART_BAUDRATE      115200
#define TEGRA186_UART_SPI           288
#define TEGRA186_UART_INTID         (TEGRA186_UART_SPI + 32) /* 320 */

#define TEGRA186_GICD_BASE          0x03881000ULL
#define TEGRA186_GICD_SIZE          0x1000ULL
#define TEGRA186_GICC_BASE          0x03892000ULL
#define TEGRA186_GICC_SIZE          0x2000ULL
#define TEGRA186_GIC_NUM_IRQ        352

#define TEGRA186_DRAM_BASE          0x80000000ULL
#define TEGRA186_RAM_SIZE           (4ULL * GiB)
#define TEGRA186_NCPUS              4

static struct arm_boot_info tegra186_binfo;

static void tegra186_cpu_init(MachineState *machine)
{
    static const uint64_t tegra186_cpus_mpidr[TEGRA186_NCPUS] = {
        0x000ULL, /* Cluster 0 CPU 0 */
        0x001ULL, /* Cluster 0 CPU 1 */
        0x100ULL, /* Cluster 1 CPU 0 */
        0x101ULL, /* Cluster 1 CPU 1 */
    };
    Object *cluster;
    unsigned int smp_cpus = machine->smp.cpus;
    int i;

    cluster = object_new(TYPE_CPU_CLUSTER);
    qdev_prop_set_uint32(DEVICE(cluster), "cluster-id", 0);

    for (i = 0; i < smp_cpus; i++) {
        Object *cpuobj = object_new(ARM_CPU_TYPE_NAME("cortex-a57"));

        object_property_add_child(cluster, "cpu[*]", cpuobj);

        /* PSCI conduit: HVC */
        object_property_set_int(cpuobj, "psci-conduit", QEMU_PSCI_CONDUIT_HVC,
                                &error_abort);

        /* Set MPIDR affinity matching Parker dual-cluster DTB topology */
        if (i < ARRAY_SIZE(tegra186_cpus_mpidr)) {
            object_property_set_int(cpuobj, "mp-affinity", tegra186_cpus_mpidr[i],
                                    &error_abort);
        }

        /* Non-secure EL1 direct boot: disable EL3 and EL2 */
        object_property_set_bool(cpuobj, "has_el3", false, &error_abort);
        object_property_set_bool(cpuobj, "has_el2", false, &error_abort);

        /* Secondary CPUs start powered off under PSCI */
        if (i != 0) {
            object_property_set_bool(cpuobj, "start-powered-off", true,
                                     &error_abort);
        }

        qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);
        arm_register_hypercall_hook(ARM_CPU(cpuobj), tegra186_hypercall_handler);
    }

    qdev_realize(DEVICE(cluster), NULL, &error_fatal);
}

static DeviceState *tegra186_gic_init(void)
{
    DeviceState *gic_dev = qdev_new(gic_class_name());
    SysBusDevice *gicbusdev = SYS_BUS_DEVICE(gic_dev);
    int i;

    qdev_prop_set_uint32(gic_dev, "num-cpu", TEGRA186_NCPUS);
    qdev_prop_set_uint32(gic_dev, "num-irq", TEGRA186_GIC_NUM_IRQ);
    qdev_prop_set_uint32(gic_dev, "revision", 2);

    sysbus_realize_and_unref(gicbusdev, &error_fatal);

    /* Distributor: 0x03881000 */
    sysbus_mmio_map(gicbusdev, 0, TEGRA186_GICD_BASE);
    /* CPU interface: 0x03892000 */
    sysbus_mmio_map(gicbusdev, 1, TEGRA186_GICC_BASE);

    /* Wire timer PPIs and CPU interrupt inputs */
    for (i = 0; i < TEGRA186_NCPUS; i++) {
        DeviceState *cpudev = DEVICE(qemu_get_cpu(i));
        int ppi_base = (TEGRA186_GIC_NUM_IRQ - 32) + i * 32;
        static const int timer_irq[] = {
            [GTIMER_PHYS] = ARCH_TIMER_NS_EL1_IRQ, /* INTID 30 */
            [GTIMER_VIRT] = ARCH_TIMER_VIRT_IRQ,   /* INTID 27 */
            [GTIMER_HYP]  = ARCH_TIMER_NS_EL2_IRQ,  /* INTID 26 */
            [GTIMER_SEC]  = ARCH_TIMER_S_EL1_IRQ,   /* INTID 29 */
        };

        for (unsigned irq = 0; irq < ARRAY_SIZE(timer_irq); irq++) {
            qdev_connect_gpio_out(cpudev, irq,
                                  qdev_get_gpio_in(gic_dev,
                                                   ppi_base + timer_irq[irq]));
        }

        sysbus_connect_irq(gicbusdev, i,
                           qdev_get_gpio_in(cpudev, ARM_CPU_IRQ));
        sysbus_connect_irq(gicbusdev, i + TEGRA186_NCPUS,
                           qdev_get_gpio_in(cpudev, ARM_CPU_FIQ));
        sysbus_connect_irq(gicbusdev, i + 2 * TEGRA186_NCPUS,
                           qdev_get_gpio_in(cpudev, ARM_CPU_VIRQ));
        sysbus_connect_irq(gicbusdev, i + 3 * TEGRA186_NCPUS,
                           qdev_get_gpio_in(cpudev, ARM_CPU_VFIQ));
    }

    return gic_dev;
}

static void tegra186_uart_init(MemoryRegion *sysmem, DeviceState *gic_dev)
{
    qemu_irq uart_irq;

    /* GIC SPI 288 (INTID 320) */
    uart_irq = qdev_get_gpio_in(gic_dev, TEGRA186_UART_SPI);

    /* 8250 MMIO UART at 0x031f0000, regshift 2 (4-byte stride), baudbase 115200 */
    serial_mm_init(sysmem, TEGRA186_UART_BASE, 2,
                   uart_irq, TEGRA186_UART_BAUDRATE,
                   serial_hd(0), DEVICE_LITTLE_ENDIAN);

    /* Tegra vendor register range at 0x031f0020 (0x20 bytes) */
    sysbus_create_simple("tegra.uart",
                         TEGRA186_UART_BASE + TEGRA186_UART_VENDOR_OFFSET,
                         NULL);
}

static void tegra186_machine_init(MachineState *machine)
{
    MemoryRegion *sysmem = get_system_memory();
    DeviceState *gic_dev;
    MemoryRegion *ivm_mr;
    void *ivm_ptr;

    /* System RAM at 0x80000000 */
    memory_region_add_subregion(sysmem, TEGRA186_DRAM_BASE, machine->ram);

    /* 76 MiB IVM Carveout at 0x70c00000 matching DTB carveout0 (no-map) */
    ivm_mr = g_new(MemoryRegion, 1);
    memory_region_init_ram(ivm_mr, NULL, "tegra186.ivm",
                           TEGRA186_IVM_CARVEOUT_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, TEGRA186_IVM_CARVEOUT_BASE, ivm_mr);
    ivm_ptr = memory_region_get_ram_ptr(ivm_mr);

    /* Create CPUs */
    tegra186_cpu_init(machine);

    /* Create GICv2 and wire interrupts */
    gic_dev = tegra186_gic_init();

    /* Initialize Hypervisor and wire IVC Channel 66 IRQ (GIC SPI 109 / INTID 141) */
    tegra186_hv_init(ivm_ptr, qdev_get_gpio_in(gic_dev, 109));

    /* Create UART */
    tegra186_uart_init(sysmem, gic_dev);

    /* Configure Linux direct kernel boot */
    tegra186_binfo.ram_size = machine->ram_size;
    tegra186_binfo.loader_start = TEGRA186_DRAM_BASE;
    tegra186_binfo.board_id = -1;
    tegra186_binfo.psci_conduit = QEMU_PSCI_CONDUIT_HVC;
    arm_load_kernel(ARM_CPU(first_cpu), machine, &tegra186_binfo);
}

static void tegra186_machine_class_init(MachineClass *mc)
{
    static const char * const valid_cpu_types[] = {
        ARM_CPU_TYPE_NAME("cortex-a57"),
        NULL
    };

    mc->desc = "ARM NVIDIA Tegra186 (T186/Parker)";
    mc->init = tegra186_machine_init;
    mc->valid_cpu_types = valid_cpu_types;
    mc->default_cpus = TEGRA186_NCPUS;
    mc->min_cpus = TEGRA186_NCPUS;
    mc->max_cpus = TEGRA186_NCPUS;
    mc->ignore_memory_transaction_failures = true;
    mc->default_ram_id = "tegra186.ram";
    mc->default_ram_size = TEGRA186_RAM_SIZE;
}

DEFINE_MACHINE("tegra186", tegra186_machine_class_init)
