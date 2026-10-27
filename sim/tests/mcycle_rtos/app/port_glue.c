/*
 * port_glue.c — SCR1-специфичная обвязка RISC-V порта FreeRTOS.
 *
 * Тик-таймер не используется (кооперативный режим, configMTIME*_BASE_ADDRESS=0):
 * переопределяем weak vPortSetupTimerInterrupt() из port.c пустой функцией,
 * чтобы порт не программировал CLINT/mtime (на Spike его вообще нет по адресу
 * SCR1 TCSR, а на SCR1 лишний источник прерываний сломал бы детерминизм).
 */
#include <FreeRTOS.h>

void vPortSetupTimerInterrupt( void )
{
    /* no-op: no tick in the cooperative differential testbed */
}
