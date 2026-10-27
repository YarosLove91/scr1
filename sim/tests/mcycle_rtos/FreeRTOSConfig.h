/*
 * FreeRTOSConfig.h — SCR1 (RV32IMC) differential testbed, COOPERATIVE mode.
 *
 * Ключевое: без тик-таймера (configMTIME*_BASE_ADDRESS=0) и без превакции —
 * исполнение детерминировано и побитово идентично на SCR1 RTL и на Spike,
 * что требуется дифференциальному оракулу (один бинарь на двух сторонах).
 */
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/* Scheduler: cooperative, no tick */
#define configUSE_PREEMPTION                    0
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configUSE_TICKLESS_IDLE                 0
#define configCPU_CLOCK_HZ                      ( ( unsigned long ) 1000000 )
#define configTICK_RATE_HZ                      ( ( TickType_t ) 1000 )
#define configMAX_PRIORITIES                    ( 3 )
#define configMINIMAL_STACK_SIZE                ( ( uint16_t ) 192 )
#define configMAX_TASK_NAME_LEN                 ( 12 )
#define configTICK_TYPE_WIDTH_IN_BITS           TICK_TYPE_WIDTH_32_BITS
#define configIDLE_SHOULD_YIELD                 0

/* Features: минимальный набор — tasks + queues */
#define configUSE_TASK_NOTIFICATIONS            0
#define configUSE_MUTEXES                       0
#define configUSE_RECURSIVE_MUTEXES             0
#define configUSE_COUNTING_SEMAPHORES           0
#define configQUEUE_REGISTRY_SIZE               0
#define configUSE_QUEUE_SETS                    0
#define configUSE_TIMERS                        0
#define configUSE_CO_ROUTINES                   0
#define configUSE_TRACE_FACILITY                0
#define configGENERATE_RUN_TIME_STATS           0
#define configUSE_IDLE_HOOK                     0
#define configUSE_TICK_HOOK                     0
#define configCHECK_FOR_STACK_OVERFLOW          0
#define configUSE_MALLOC_FAILED_HOOK            0

/* Memory: dynamic only, heap_4 */
#define configSUPPORT_DYNAMIC_ALLOCATION        1
#define configSUPPORT_STATIC_ALLOCATION         0
#define configAPPLICATION_ALLOCATED_HEAP        0
#define configTOTAL_HEAP_SIZE                   ( ( size_t ) ( 20 * 1024 ) )

/* RISC-V port: no CLINT/MTIMER — tick interrupt не используется и не
   разрешается (port.c включает mie только при ненулевых адресах) */
#define configMTIME_BASE_ADDRESS                ( 0 )
#define configMTIMECMP_BASE_ADDRESS             ( 0 )
#define configISR_STACK_SIZE_WORDS              ( 256 )

#define configASSERT( x )

/* INCLUDE options */
#define INCLUDE_vTaskPrioritySet                0
#define INCLUDE_uxTaskPriorityGet               0
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_xTaskDelayUntil                 0
#define INCLUDE_vTaskDelay                      0
#define INCLUDE_xTaskGetSchedulerState          0
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_xTaskGetIdleTaskHandle          0
#define INCLUDE_eTaskGetState                   0
#define INCLUDE_xTimerPendFunctionCall          0
#define INCLUDE_xTaskAbortSchedule              0
#define INCLUDE_xTaskGetHandle                  0
#define INCLUDE_uxTaskGetStackHighWaterMark     0
#define INCLUDE_xQueueGetMutexHolder            0

#endif /* FREERTOS_CONFIG_H */
