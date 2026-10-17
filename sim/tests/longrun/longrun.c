/*
 * Long-running freestanding workload for trace correlation (~250k clocks).
 * Deterministic mixed integer ops (mul/shift/xor/and/or/add/branch) in a loop.
 * No libc. Prints a '.' (via the sim console port) and returns 0.
 */

#define SIM_PRINT (*(volatile unsigned char *)0xF0000000u)

static void putc_(unsigned char c) { SIM_PRINT = c; }

#ifndef LONGRUN_N
#define LONGRUN_N 12600
#endif

int main(void) {
    unsigned x = 0x12345678u;
    unsigned y = 0x9abcdef0u;
    unsigned z = 0;
    int i;

    for (i = 0; i < LONGRUN_N; ++i) {
        x = x * 1103515245u + 12345u;   /* mul */
        y = (y << 1) ^ (x >> 3);        /* shifts + xor */
        z = (x & 0xffffu) | (y & 0xffffu);
        if (z & 1u) {
            x ^= y;
        } else {
            y += z;
        }
    }

    /* Make the computed state observable so -O3 cannot drop the loop */
    putc_((unsigned char)(x ^ y ^ z));
    return 0;
}
