#include "console.h"

void con_puts(const char *s)
{
    while (*s) {
        con_putc((unsigned char)*s++);
    }
}

void con_puthex(uint32_t v)
{
    static const char h[] = "0123456789abcdef";
    char b[8];
    int i;
    for (i = 0; i < 8; ++i) { b[7 - i] = h[v & 0xF]; v >>= 4; }
    for (i = 0; i < 8; ++i) { con_putc((unsigned char)b[i]); }
}

void con_putdec(uint32_t v)
{
    char b[10];
    int i = 0;
    if (v == 0) { con_putc('0'); return; }
    while (v) { b[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i--) { con_putc((unsigned char)b[i]); }
}
