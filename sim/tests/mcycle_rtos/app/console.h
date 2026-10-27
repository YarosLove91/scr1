/* console.h — вывод через SIM_PRINT (0xF0000000), как tb SCR1 перехватывает */
#ifndef MCYCLE_RTOS_CONSOLE_H
#define MCYCLE_RTOS_CONSOLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIM_PRINT (*(volatile unsigned char *)0xF0000000u)

static inline void con_putc(unsigned char c) { SIM_PRINT = c; }

void con_puts(const char *s);
void con_puthex(uint32_t v);
void con_putdec(uint32_t v);

#ifdef __cplusplus
}
#endif

#endif /* MCYCLE_RTOS_CONSOLE_H */
