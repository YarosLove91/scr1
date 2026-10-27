# Vendored FreeRTOS-Kernel (subset)

- Source: https://github.com/FreeRTOS/FreeRTOS-Kernel, tag **V11.1.0**
  (commit `dbf70559b27d39c1fdb68dfb9a32140b6a6777a0`).
- Copied subset (no local modifications to kernel sources):
  - `tasks.c`, `queue.c`, `list.c`
  - `include/*.h`
  - `portable/MemMang/heap_4.c`
  - `portable/GCC/RISC-V/{port.c, portASM.S, portmacro.h, portContext.h}`
  - `portable/GCC/RISC-V/chip_specific_extensions/RISCV_no_extensions/freertos_risc_v_chip_specific_extensions.h`
  - `LICENSE.md` (MIT)
- Integration glue lives OUTSIDE the vendor tree:
  `../FreeRTOSConfig.h`, `../app/port_glue.c` (no-op `vPortSetupTimerInterrupt`).
- Configuration highlights (see FreeRTOSConfig.h): cooperative scheduler
  (`configUSE_PREEMPTION=0`), **no tick timer** (`configMTIME_BASE_ADDRESS=0`,
  `configMTIMECMP_BASE_ADDRESS=0`) — execution is deterministic and identical on
  SCR1 RTL and Spike, which is required by the differential oracle.
