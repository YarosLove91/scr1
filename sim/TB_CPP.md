# C++ Verilator Testbenches — Quick Reference

Окружения: `sim/tb_cpp_ahb/` (scr1_top_ahb) и `sim/tb_cpp_axi/` (scr1_top_axi).
Заменяют нативные SV-тестбенчи. Чистый C++ (Verilator `--cc`), без SystemC.

## Структура

```
sim/tb_cpp_common/   общий код обоих тестбенчей:
                     main.cpp, logger.*, elf_load.* (LMA-загрузчик ELF),
                     mem_api.h, state_dump.* (GPR/CSR), trace_logger.*
                     (трейс выполнения) — логика одна, доступ к модели
                     через dut_access.h каждого TB
sim/tb_cpp_ahb/      dut_access.h, ahb.h, tb_ahb_mem.*, testbench.*, makefile'ы
sim/tb_cpp_axi/      dut_access.h, axi.h, tb_axi_mem.*, testbench.*, makefile'ы
```

## Быстрый старт: hello от начала до конца

```bash
# 1. Тулчейн в PATH
export PATH=$PATH:~/Work/TOOLS/xpack-riscv-none-elf-gcc-15.2.0-1/bin

# 2. Собрать тест hello (из корня репо)
cd ~/Work/barnsley/scr1
make hello CROSS_PREFIX=riscv-none-elf- BUS=AHB CFG=MAX
# -> build/hello_AHB_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/hello.elf
# (каталог сборки зависит от цели: `make tests` -> build/tests_AHB_MAX_...)

# 3. Собрать AHB-тестбенч (verilate + модель + test.x)
cd sim/tb_cpp_ahb
make build

# 4. Запустить hello: без VCD, с дампом GPR/CSR и трейсом выполнения
./build/test.x \
    -f ../../build/hello_AHB_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/hello.elf \
    --trace 0 --state 1 --trace_log hello_trace.log
```

Ожидаемый вывод:

```
[+] Running: ../../build/hello_AHB_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/hello.elf
[+] Memory: 0x00000000 - 0x000003ff (Size=1KB) [LOAD vaddr=0x00000000]
[+] Memory: 0x00000400 - 0x00001fdf (Size=6KB) [LOAD vaddr=0x00480000]
[+] Trace log: hello_trace.log
Hello from SCR1!
# SCR1 final architectural state
# sim_status: PASS
...
[+] Exit success!
Cycles: 16997
Sim time:   169970 ns
Printed chars:  17
```

Для AXI — то же самое в `sim/tb_cpp_axi` (шаги 3–4; ELF подходит тот же).

## 0. Окружение (один раз на сессию)

```bash
export PATH=$PATH:~/Work/TOOLS/xpack-riscv-none-elf-gcc-15.2.0-1/bin
verilator --version    # >= 5.x
```

## 1. Сборка тестов (ELF) — из корня репо

Цель `tests` определена в корневом `Makefile` (~/.../scr1),
а не в `sim/tb_cpp_ahb/` — из каталога тестбенча она не работает.

```bash
cd ~/.../scr1
make tests CROSS_PREFIX=riscv-none-elf- BUS=AHB CFG=MAX
# результат: build/tests_AHB_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/*.elf
make hello CROSS_PREFIX=riscv-none-elf-
# только один тест
# TARGETS: riscv_isa riscv_arch riscv_compliance isr_sample hello coremark dhrystone21
# Для gcc 15 в common.mk/sc_print.c применён фикс TLS/emutls-линковки
# (-Wl,--start-group -lc -lgcc -Wl,--end-group, убран static __thread),
# иначе hello/coremark/dhrystone не линкуются (undefined malloc/abort)
```

## 2. Сборка тестбенча

```bash
cd ~/Work/barnsley/scr1/sim/tb_cpp_ahb    # или .../tb_cpp_axi
make build           # 3 стадии: verilate -> архивы модели -> build/test.x
make clean
```

Переменные сборки:

```bash
make build SIM_CFG_DEF=SCR1_CFG_RV32IMC_MAX  # конфигурация ядра (MAX/BASE/MIN...)
make build SIM_TRACE_DEF=SCR1_TRACE_LOG_DIS  # трейс-лог RTL
make build STATE_DUMP=0                      # без --public-flat-rw (быстрее; state/trace_log недоступны)
make build TB_DEFINES="-DTB_NO_IPIC"         # для конфигов без IPIC (ещё: -DTB_NO_DBG)
```

## 3. Запуск

```bash
make run TEST_IMAGE=<path.elf> RUN_OPTS="--trace 0"     # через make
./build/test.x -f <path.elf> [опции]                    # напрямую
```

Опции `test.x`:

| Опция | Описание |
|---|---|
| `-f, --elf FILE` | ELF теста (обязательно) |
| `-c, --cycles N` | лимит циклов (по умолчанию 2 000 000) |
| `-t, --trace 0\|1` | VCD-трейс (по умолчанию 1) |
| `-w, --vcd_name F` | имя VCD (по умолчанию sysc_wave.vcd) |
| `-s, --seed N` | seed (также env `SEED`) |
| `-S, --state 0\|1` | дамп GPR/CSR в лог в конце прогона |
| `-F, --state_file F` | дамп GPR/CSR в файл (формат scr1_final_state.txt) |
| `-L, --trace_log F` | построчный трейс выполнения (инструкция на ретайр) |

Env: `ENABLE_WAVES=no` (без VCD), `WAVES_DELAY_US=N`, `NO_COLOR=1`, `SEED=N`.

Код возврата: `0` — тест дошёл до SIM_STOP (0xF8), `1` — timeout / RTL-ошибка / assertion.

Примеры:

```bash
./build/test.x -f ../../build/tests_AHB_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/hello.elf \
    --trace 0 --state 1 --trace_log trace.log
```

## 4. Пакетный прогон регрессии

```bash
for elf in ../../build/tests_AHB_MAX_imc_IPIC_1_TCM_1_VIRQ_1_TRACE_0/*.elf; do
    ./build/test.x -f "$elf" --trace 0 >/dev/null 2>&1 \
        && echo "PASS $(basename $elf .elf)" \
        || echo "FAIL $(basename $elf .elf)"
done | tee /tmp/results.txt
grep -c PASS /tmp/results.txt; grep FAIL /tmp/results.txt
```

## 5. Форматы вывода

**trace_log** (реплика scr1_trace_logger.sv):

```
     Cycle PC         Opcode     RD write             Status
         6 0x00000200 0x00000093 x1 = 0x00000000
       297 0x000002b4 0x--------                      IRQ  | mcause=0x80000007 mepc=... mtval=... mtvec=... instr=...
       326 0x00000398 0x30200073                      MRET
```

**state_file** — байт-в-байт формат нативного `scr1_final_state.txt`
(GPR с ABI-именами, mstatus/misa/mie/mtvec/mscratch/mepc/mcause/mtval/mip/mhartid/mcycle/minstret).

## 6. Анализ VCD (wavepeek)

```bash
./build/test.x -f <elf> --trace 1 --vcd_name fail.vcd
wavepeek info --waves fail.vcd
wavepeek scope --waves fail.vcd --tree --max-depth 5
wavepeek change --waves fail.vcd \
    --scope TOP.scr1_top_ahb.i_core_top.i_pipe_top \
    --on 'negedge clk' --from 600ps --to 700ps --row-mode dense \
    --signals curr_pc,i_pipe_ifu.exu2ifu_pc_new_req_i,dmem2pipe_resp_i
```

## 7. Отладочная печать AHB-шины

```bash
make -f makefile.build_tb EXTRA_CFLAGS=-DTB_DEBUG_AHB   # AHB (для AXI: -DTB_DEBUG_AXI)
```

## 8. Проверенные результаты (CFG=MAX)

- AHB: 225/225 PASS · AXI: 222/222 PASS
  (riscv_isa, riscv_arch, riscv_compliance, isr_sample, hello, a5_1, mcycle_rtos, fern)
