/*
 * Conway's Game of Life for SCR1 (RV32IMC), bare-metal, no libc.
 *
 * Port of conway.cpp: toroidal grid, Gosper glider gun start, deterministic
 * evolution for a bounded number of generations. Each generation is printed
 * to the simulation console port (0xF0000000); live cells are '#'.
 *
 * Full-size grid (30x60, as in conway.cpp); neighbor counting avoids
 * division/modulo to stay within the testbench watchdog window.
 */

#ifdef CONWAY_HOST
#include <stdio.h>
static void putc_(unsigned char c) { putchar((int)c); }
#else
#define SIM_PRINT (*(volatile unsigned char *)0xF0000000u)
static void putc_(unsigned char c) { SIM_PRINT = c; }
#endif

static void puts_(const char *s) { while (*s) putc_((unsigned char)*s++); }

static void putnum(unsigned v) {
    char b[10];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i--) putc_((unsigned char)b[i]);
}

#define H 30
#define W 60
#define FRAMES 12

static unsigned char cur[H * W];
static unsigned char nxt[H * W];

/* Toroidal neighborhood count without division. */
static int neighbors(int i, int j) {
    int base = i * W;
    int up   = (i == 0 ? H - 1 : i - 1) * W;
    int dn   = (i == H - 1 ? 0 : i + 1) * W;
    int jl   = (j == 0 ? W - 1 : j - 1);
    int jr   = (j == W - 1 ? 0 : j + 1);
    return cur[up + jl] + cur[up + j] + cur[up + jr]
         + cur[base + jl] + cur[base + jr]
         + cur[dn + jl] + cur[dn + j] + cur[dn + jr];
}

/* Gosper glider gun, offset (r=2, c=2) as in conway.cpp. */
static void init_gun(void) {
    int k, i;
    static const signed char dots[][2] = {
        {4, 0}, {4, 1}, {5, 0}, {5, 1},
        {4, 10}, {5, 10}, {6, 10},
        {3, 11}, {7, 11},
        {2, 12}, {2, 13}, {8, 12}, {8, 13},
        {5, 14},
        {3, 15}, {7, 15},
        {4, 16}, {5, 16}, {6, 16},
        {5, 17},
        {2, 20}, {3, 20}, {4, 20},
        {2, 21}, {3, 21}, {4, 21},
        {1, 22}, {5, 22},
        {0, 24}, {1, 24}, {5, 24}, {6, 24},
        {2, 34}, {3, 34}, {2, 35}, {3, 35}
    };
    for (i = 0; i < H * W; ++i) cur[i] = 0;
    for (k = 0; k < (int)(sizeof(dots) / sizeof(dots[0])); ++k) {
        int r = 2 + dots[k][0];
        int c = 2 + dots[k][1];
        if (r < H && c < W) cur[r * W + c] = 1;
    }
}

static void step(void) {
    int i, j;
    for (i = 0; i < H; ++i) {
        for (j = 0; j < W; ++j) {
            int idx = i * W + j;
            int n = neighbors(i, j);
            nxt[idx] = cur[idx] ? (unsigned char)((n == 2 || n == 3) ? 1 : 0)
                                : (unsigned char)((n == 3) ? 1 : 0);
        }
    }
    for (i = 0; i < H * W; ++i) cur[i] = nxt[i];
}

static unsigned population(void) {
    unsigned p = 0;
    int i;
    for (i = 0; i < H * W; ++i) p += cur[i];
    return p;
}

static void print_board(int gen) {
    int i, j;
    puts_("Gen ");
    putnum((unsigned)gen);
    puts_(" pop=");
    putnum(population());
    putc_('\n');
    for (i = 0; i < H; ++i) {
        for (j = 0; j < W; ++j)
            putc_(cur[i * W + j] ? '#' : ' ');
        putc_('\n');
    }
}

int main(void) {
    int gen;

    puts_("Conway's Game of Life on SCR1 (RV32IMC), mode=GosperGliderGun\n");
    init_gun();

    for (gen = 0; gen < FRAMES; ++gen) {
        print_board(gen);
        step();
    }

    return 0;
}
