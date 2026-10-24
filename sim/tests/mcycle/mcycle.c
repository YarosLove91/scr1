/*
 * Reproducer for SCR1 issue #80:
 *   RV32 low-half mcycle write spuriously increments mcycleh without a
 *   32-bit carry.
 *
 * Sequence: set mcycleh = 0, set mcycle[31:8] = all ones, then write the
 * low half (csrw mcycle, 0). No 32-bit carry occurs, so mcycleh must stay 0.
 * The buggy RTL uses a pre-incremented [63:8] value and sets mcycleh = 1.
 *
 * Exit code 0 => correct (mcycleh unchanged); 1 => bug reproduced.
 */

#ifdef MCYCLE_HOST
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
    unsigned hi = 0;
    unsigned lo = 0;

    /* Establish mcycleh = 0, mcycle = 0 */
    __asm__ volatile ("csrw mcycleh, zero");
    __asm__ volatile ("csrw mcycle, zero");

    /* mcycle[31:8] = all ones, mcycle[7:0] = 0 */
    __asm__ volatile ("li t0, 0xffffff00\n\tcsrw mcycle, t0" ::: "t0");

    /* Let the counter tick a few cycles (mcycle[31:8] stays 0xffffff) */
    __asm__ volatile ("nop\n\tnop\n\tnop\n\tnop");

    /* Low-half write with no 32-bit carry: must NOT change mcycleh */
    __asm__ volatile ("csrw mcycle, zero");

    __asm__ volatile ("csrr %0, mcycleh" : "=r"(hi));
    __asm__ volatile ("csrr %0, mcycle"  : "=r"(lo));

    puts_("mcycle  = 0x"); puthex(lo); putc_('\n');
    puts_("mcycleh = 0x"); puthex(hi); putc_('\n');

    if (hi != 0) {
        puts_("BUG #80 reproduced: mcycleh spuriously changed\n");
        return 1;
    }
    puts_("OK: mcycleh unchanged\n");
    return 0;
}
