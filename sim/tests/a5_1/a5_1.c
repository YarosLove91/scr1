/*
 * A5/1 stream cipher for SCR1 (RV32IMC), bare-metal, no libc.
 *
 * Port of A5_1.cpp: three LFSRs (19/22/23 bits) with majority clocking.
 * Uses only 32-bit integer math (the 64-bit key is split into two halves),
 * so no libgcc is required. Keystream bits are printed to the simulation
 * console port (0xF0000000).
 *
 * Reference vector: key = 0x123456789ABCDEF0, frame = 0x23456
 * Expected first 20 keystream bits: 10011101001010000001
 */

#ifdef A5_1_HOST
#include <stdio.h>
static void putc_(unsigned char c) { putchar((int)c); }
#else
#define SIM_PRINT (*(volatile unsigned char *)0xF0000000u)
static void putc_(unsigned char c) { SIM_PRINT = c; }
#endif

static void puts_(const char *s) { while (*s) putc_((unsigned char)*s++); }

/* Registers R1 (19), R2 (22), R3 (23) */
static unsigned r1, r2, r3;

#define R1_MASK 0x7FFFFu
#define R2_MASK 0x3FFFFFu
#define R3_MASK 0x7FFFFFu

/* Clock all three registers with an external (key/frame) bit. */
static void step_all(unsigned ext) {
    unsigned fb1 = ((r1 >> 18) ^ (r1 >> 17) ^ (r1 >> 16) ^ (r1 >> 13)) & 1u;
    unsigned fb2 = ((r2 >> 21) ^ (r2 >> 20)) & 1u;
    unsigned fb3 = ((r3 >> 22) ^ (r3 >> 21) ^ (r3 >> 20) ^ (r3 >> 7)) & 1u;
    r1 = ((r1 << 1) | (fb1 ^ ext)) & R1_MASK;
    r2 = ((r2 << 1) | (fb2 ^ ext)) & R2_MASK;
    r3 = ((r3 << 1) | (fb3 ^ ext)) & R3_MASK;
}

/* Majority-clocked step; a register shifts only if its clock bit equals the majority. */
static void step_majority(void) {
    unsigned c1 = (r1 >> 8) & 1u;
    unsigned c2 = (r2 >> 10) & 1u;
    unsigned c3 = (r3 >> 10) & 1u;
    unsigned maj = ((c1 + c2 + c3) >= 2u) ? 1u : 0u;

    if (c1 == maj) {
        unsigned fb = ((r1 >> 18) ^ (r1 >> 17) ^ (r1 >> 16) ^ (r1 >> 13)) & 1u;
        r1 = ((r1 << 1) | fb) & R1_MASK;
    }
    if (c2 == maj) {
        unsigned fb = ((r2 >> 21) ^ (r2 >> 20)) & 1u;
        r2 = ((r2 << 1) | fb) & R2_MASK;
    }
    if (c3 == maj) {
        unsigned fb = ((r3 >> 22) ^ (r3 >> 21) ^ (r3 >> 20) ^ (r3 >> 7)) & 1u;
        r3 = ((r3 << 1) | fb) & R3_MASK;
    }
}

/* Generate one keystream bit (XOR of the three most significant bits). */
static unsigned generate_bit(void) {
    step_majority();
    return ((r1 >> 18) ^ (r2 >> 21) ^ (r3 >> 22)) & 1u;
}

int main(void) {
    /* key = 0x123456789ABCDEF0 -> hi = 0x12345678, lo = 0x9ABCDEF0; frame = 0x23456 */
    unsigned key_lo = 0x9ABCDEF0u;
    unsigned key_hi = 0x12345678u;
    unsigned frame  = 0x23456u;
    unsigned i;

    r1 = r2 = r3 = 0;

    /* 1. Shift in 64 key bits (LSB first) */
    for (i = 0; i < 64; ++i) {
        unsigned b = (i < 32) ? ((key_lo >> i) & 1u) : ((key_hi >> (i - 32)) & 1u);
        step_all(b);
    }
    /* 2. Shift in 22 frame bits (LSB first) */
    for (i = 0; i < 22; ++i) {
        step_all((frame >> i) & 1u);
    }
    /* 3. 100 idle clocks with majority clocking */
    for (i = 0; i < 100; ++i) {
        step_majority();
    }

    puts_("A5/1 keystream (20 bits): ");
    for (i = 0; i < 20; ++i) {
        putc_((unsigned char)('0' + generate_bit()));
    }
    putc_('\n');

    return 0;
}
