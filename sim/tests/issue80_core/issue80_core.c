/*
 * issue80_core — minimal standalone differential reproducer for SCR1
 * issue #80, covering BOTH affected counters:
 *
 *   mcycle   -> mcycleh   (csrw mcycle,0   with mcycle[31:8]==0xFFFFFF)
 *   minstret -> minstreth (csrw minstret,0  with minstret[31:8]==0xFFFFFF)
 *
 * Obtained mechanically by the instruction reducer (barnsley repo,
 * docker/scr1-spike/tools/reducer, phases D/E): the FreeRTOS-based
 * mcycle_rtos counterexample (336,694 dynamic instructions) was reduced to
 * 11-word RAM cores (56 dynamic instructions) with the guilty instructions
 * preserved verbatim (mcycle: b0001073, minstret: b0201073). This file is
 * the human-readable standalone form of both cores: same trigger sequences,
 * standard crt (no patches), SIM_PRINT console.
 *
 * Root cause: scr1_pipe_csr.sv write branches take the pre-incremented
 * csr_*_hi_new (= hi_ff + 1) instead of csr_*_hi_ff:
 *   lines 908-909 (mcycle), lines 945-946 (minstret).
 * With counter[31:8] == 0xFFFFFF the +1 carries from bit 31 into bit 32,
 * so a low-half write spuriously increments the high half.
 *
 * Exit code: bit0 = mcycleh bug, bit1 = minstreth bug.
 * Buggy RTL: a0=3 (__FAIL); correct model (e.g. fresh Spike): a0=0 (PASS).
 */

#ifdef ISSUE80_HOST
#include <stdio.h>
static void putc_(unsigned char c) { putchar((int)c); }
#else
#define SIM_PRINT (*(volatile unsigned char *)0xF0000000u)
static void putc_(unsigned char c) { SIM_PRINT = c; }
#endif

static void puts_(const char *s) { while (*s) putc_((unsigned char)*s++); }

static void puthex(unsigned v) {
    static const char h[] = "0123456789abcdef";
    char b[8];
    int i;
    for (i = 0; i < 8; ++i) { b[7 - i] = h[v & 0xF]; v >>= 4; }
    for (i = 0; i < 8; ++i) putc_((unsigned char)b[i]);
}

int main(void) {
    unsigned mc_h, mc_l, mi_h, mi_l;
    int rc = 0;

    puts_("issue80_core: minimal dual-counter reproducer\n");

    /* --- core 1: mcycle -> mcycleh --- */
    __asm__ volatile ("csrw mcycleh, zero\n\t"
                      "csrw mcycle, zero");
    __asm__ volatile ("li t0, 0xffffff00\n\t"
                      "csrw mcycle, t0" ::: "t0");   /* [31:8] = 0xFFFFFF */
    __asm__ volatile ("csrw mcycle, zero");          /* guilty instruction */
    __asm__ volatile ("csrr %0, mcycleh" : "=r"(mc_h));
    __asm__ volatile ("csrr %0, mcycle"  : "=r"(mc_l));

    /* --- core 2: minstret -> minstreth --- */
    __asm__ volatile ("csrw minstreth, zero\n\t"
                      "csrw minstret, zero");
    __asm__ volatile ("li t0, 0xffffff00\n\t"
                      "csrw minstret, t0" ::: "t0"); /* [31:8] = 0xFFFFFF */
    __asm__ volatile ("csrw minstret, zero");        /* guilty instruction */
    __asm__ volatile ("csrr %0, minstreth" : "=r"(mi_h));
    __asm__ volatile ("csrr %0, minstret"  : "=r"(mi_l));

    puts_("mcycleh   = 0x"); puthex(mc_h); putc_('\n');
    puts_("minstreth = 0x"); puthex(mi_h); putc_('\n');

    if (mc_h != 0u) {
        puts_("BUG #80 (mcycle): mcycleh spuriously changed\n");
        rc |= 1;
    }
    if (mi_h != 0u) {
        puts_("BUG #80 (minstret): minstreth spuriously changed\n");
        rc |= 2;
    }
    if (rc == 0) {
        puts_("OK: high halves unchanged\n");
    }
    puts_("rc = "); puthex((unsigned)rc); putc_('\n');
    (void)mc_l; (void)mi_l;
    return rc;
}
