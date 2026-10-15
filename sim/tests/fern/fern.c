/*
 * Barnsley fern generator for SCR1 (RV32IMC), bare-metal, no libc.
 *
 * Computes the iterated function system (4 affine transforms) and prints an
 * ASCII image to the simulation console port (0xF0000000). Coordinates use
 * Q12 fixed point so only 32-bit integer math is required (no soft-float).
 */

#define SIM_PRINT (*(volatile unsigned char *)0xF0000000u)

static void putc_(unsigned char c) { SIM_PRINT = c; }

static void puts_(const char *s) { while (*s) putc_((unsigned char)*s++); }

static void putnum(unsigned v) {
    char b[10];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i--) putc_((unsigned char)b[i]);
}

#define W 90
#define H 40
#define ITERS 12000

#define FSHIFT 12
#define FONE (1 << FSHIFT)

static unsigned char grid[H][W];

/* Simple 32-bit LCG, returns a 23-bit value in [0, 2^23). */
static unsigned rng = 0x1234567u;
static unsigned rnd(void) {
    rng = rng * 1103515245u + 12345u;
    return (rng >> 9) & 0x7FFFFFu;
}

/* Q12 fixed-point multiply (values stay well within 32-bit range). */
static int fmul(int a, int b) { return (a * b) >> FSHIFT; }

int main(void) {
    int r, c, i;
    int x = 0;
    int y = 0;

    for (r = 0; r < H; ++r)
        for (c = 0; c < W; ++c)
            grid[r][c] = 0;

    for (i = 0; i < ITERS; ++i) {
        unsigned p = rnd();
        int nx, ny;

        /* 1. Stem (1%) */
        if (p < 83886u) {
            nx = 0;
            ny = fmul(655, y);
        }
        /* 2. Small inner leaflets (85%) */
        else if (p < 7214203u) {
            nx = fmul(3482, x) + fmul(164, y);
            ny = -fmul(164, x) + fmul(3482, y) + 6554;
        }
        /* 3. Left side leaves (7%) */
        else if (p < 7801406u) {
            nx = fmul(819, x) - fmul(1065, y);
            ny = fmul(942, x) + fmul(901, y) + 6554;
        }
        /* 4. Right side leaves (7%) */
        else {
            nx = -fmul(614, x) + fmul(1147, y);
            ny = fmul(1065, x) + fmul(983, y) + 1802;
        }

        x = nx;
        y = ny;

        /* Map mathematical coordinates to the ASCII grid. */
        {
            int px = ((x + 10240) * W) / 20480;   /* x in [-2.5, 2.5] */
            int py = ((40960 - y) * H) / 40960;   /* y in [0, 10], flipped */
            if (px >= 0 && px < W && py >= 0 && py < H && grid[py][px] < 255)
                grid[py][px]++;
        }
    }

    puts_("Barnsley fern on SCR1 (RV32IMC), iterations=");
    putnum(ITERS);
    puts_("\n");
    for (r = 0; r < H; ++r) {
        for (c = 0; c < W; ++c)
            putc_(grid[r][c] ? '#' : ' ');
        putc_('\n');
    }

    return 0;
}
