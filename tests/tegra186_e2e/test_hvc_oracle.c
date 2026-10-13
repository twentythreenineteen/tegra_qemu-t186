#include "qemu/osdep.h"
#include "target/arm/cpu.h"
#include "hw/arm/tegra2/tegra186_hv.h"
#include <assert.h>
#include <stdio.h>

int main(void)
{
    ARMCPU cpu;
    memset(&cpu, 0x5a, sizeof(cpu));

    /* Initialize register bank */
    for (int i = 0; i < 32; i++) {
        cpu.env.xregs[i] = 0xdeadbeef00000000ULL | i;
    }

    /* Test HVC #3 (read guest id) */
    bool handled = tegra186_hypercall_handler(&cpu, 3);
    assert(handled == true);
    assert(cpu.env.xregs[0] == 0); /* status: success */
    assert(cpu.env.xregs[1] == 1); /* guest id: 1 */
    /* Assert registers x2..x31 are untouched */
    for (int i = 2; i < 32; i++) {
        assert(cpu.env.xregs[i] == (0xdeadbeef00000000ULL | i));
    }
    printf("PASS: HVC #3 returned w0=0, w1=1 with x2..x31 preserved\n");

    /* Test HVC #5 (read num guests) */
    handled = tegra186_hypercall_handler(&cpu, 5);
    assert(handled == true);
    assert(cpu.env.xregs[0] == 0);
    assert(cpu.env.xregs[1] == 2);
    printf("PASS: HVC #5 returned w0=0, w1=2\n");

    /* Test HVC #2 (get IVC info page IPA) */
    handled = tegra186_hypercall_handler(&cpu, 2);
    assert(handled == true);
    assert(cpu.env.xregs[0] == 0);
    assert(cpu.env.xregs[1] == 0x70c00000ULL);
    printf("PASS: HVC #2 returned w0=0, x1=0x70c00000\n");

    /* Test recognized IVC and notification hypercalls */
    uint32_t recognized[] = {4, 6, 7, 9, 10, 17, 18, 19, 20, 289, 290, 518, 519, 520};
    for (size_t k = 0; k < sizeof(recognized)/sizeof(recognized[0]); k++) {
        uint32_t imm = recognized[k];
        cpu.env.xregs[0] = 0xbad;
        handled = tegra186_hypercall_handler(&cpu, imm);
        assert(handled == true);
        assert(cpu.env.xregs[0] == 0);
    }
    printf("PASS: All %zu recognized hypercall immediates return w0=0\n", sizeof(recognized)/sizeof(recognized[0]));

    /* Test all other 16-bit immediates in 0..65535 (unknown HVCs) */
    size_t unhandled_count = 0;
    for (uint32_t imm = 0; imm <= 0xffff; imm++) {
        /* Check if it is in recognized list */
        bool is_rec = (imm == 2 || imm == 3 || imm == 5);
        for (size_t k = 0; k < sizeof(recognized)/sizeof(recognized[0]); k++) {
            if (imm == recognized[k]) {
                is_rec = true;
                break;
            }
        }

        cpu.env.xregs[0] = 0x12345678ULL;
        handled = tegra186_hypercall_handler(&cpu, imm);
        if (is_rec) {
            assert(handled == true);
        } else {
            /* Must return false for unknown immediates and NOT mutate xregs */
            assert(handled == false);
            assert(cpu.env.xregs[0] == 0x12345678ULL);
            unhandled_count++;
        }
    }
    printf("PASS: Tested all 65,536 immediates. %zu unhandled immediates returned false gracefully.\n", unhandled_count);

    return 0;
}
