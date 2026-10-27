/* main.cpp — точка входа: создаёт задачи, ставит mtvec порта FreeRTOS,
 * запускает планировщик. Завершение — через sc_exit() в задаче-репортёре. */
#include <FreeRTOS.h>
#include <task.h>

#include "console.h"
#include "app.hpp"

extern "C" void freertos_risc_v_trap_handler(void);

extern "C" int main(void)
{
    con_puts("boot: mcycle_rtos, FreeRTOS " tskKERNEL_VERSION_NUMBER " cooperative\n");

    app_start();

    /* Порт FreeRTOS сам не ставит mtvec — делаем это до старта планировщика. */
    __asm__ volatile(
        "la t0, freertos_risc_v_trap_handler\n\t"
        "csrw mtvec, t0\n\t"
        :
        :
        : "t0");

    vTaskStartScheduler();

    /* сюда не попадаем: выход через sc_exit() в taskReporter */
    for (;;) { }
    return 0;
}
