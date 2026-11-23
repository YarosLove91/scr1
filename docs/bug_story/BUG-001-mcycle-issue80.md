# Bug Story: mcycleh/minstreth stuck after counter write (issue #80)

**Bug ID**: SCR1-CSR-080 (issue #80, ветка-репродуцер `test/mcycle-issue80`)
**Date Discovered**: 2026-10 (дифференциальная верификация в docker `scr1-spike-verif`)
**Severity**: High (архитектурно видимые счётчики; ломает 64-битное чтение
mcycle/minstret после долгой работы — RTOS-профили, тайминг-софт)
**Status**: Подтверждён, НЕ исправлен в нашем дереве (upstream-баг);
закоммичен standalone-репродуцер `sim/tests/issue80_core` (scr1 3c2a6f0)

---

## Executive Summary

Верхние половины машинных счётчиков (`mcycleh`/`minstreth`) обновляются
некорректно при записи нижних половин: после `csrw mcycle, 0` в состоянии
`mcycle[31:8] == 0xFFFFFF ∧ mcycleh == 0` RTL даёт `mcycleh = 1`, тогда как
эталонный Spike даёт `mcycleh = 0` (перенос в старшую половину при записи
обрабатывается неправильно). Симметричный баг подтверждён для
`minstret/minstreth` (фаза E редукции).

## Bug Discovery

- **Среда**: docker-образ `scr1-spike-verif` (свежий Spike master vs SCR1 RTL,
  Verilator), дифференциальное сравнение коммит-потоков.
- **Тест**: `mcycle_rtos` (FreeRTOS + C++ задачи/очереди), **336 694 динамических
  коммита**; расхождение найдено по состоянию CSR (`STATE_DUMP`,
  `<test>_state.txt`): RTL `mcycleh=1` против Spike `mcycleh=0`.
- **Трассировка**: `TRACE_LOGGER` (per-test `.log`) — поток retire с CSR-статусами.

## Initial Symptoms

```
RTL  : console 'R1' (rc = bit0: mcycleh != 0), __FAIL
Spike: console 'R0', a0 = 0, PASS
```

## Technical Analysis

### Root Cause

`src/core/pipeline/scr1_pipe_csr.sv:908` — логика обновления `mcycleh_ff`
при записи `mcycle`: перенос/инкремент старшей половины срабатывает там, где
эталон (Spike) его не делает. Симметрично: `scr1_pipe_csr.sv:945-946`
(`minstreth_ff`).

### Семантика, доказанная редуктором

`csrw mcycle, 0` при `mcycle[31:8] == 0xFFFFFF ∧ mcycleh == 0`
→ RTL: `mcycleh = 1`; Spike: `mcycleh = 0`.
FreeRTOS/задачи/очереди/nops/csrr — НЕ существенны: достаточно
**2 инструкций предусловия + 1 виновной** (`csrw mcycle,zero`, enc `b0001073`).

## Минимизация (instruction reducer, redlib)

| Параметр | Значение |
|---|---|
| Было | 336 694 динамических коммита (mcycle_rtos) |
| Стало | **ядро 11 инструкций в RAM 0x3000, 56 динамических коммитов (−99.983 %)** |
| RTL-прогон ядра | 0.02 c (×30 быстрее полного) |
| Контрастная пара | larger (ядро) = SameBug / smaller (виновная `csrw`→NOP, единственное отличие) = NoBug |
| Эпилог | маркер `R` → outport, `csrr a1,mcycleh; snez a0,a1` (rc = bit0 mcycleh \| bit1 minstreth) |

Побочное открытие фазы D: **TCM (0x480000) недостижим для hex** — tb
`$readmemh` грузит только внешний RAM-массив; TCM заполняется исключительно
crt-релокацией → ядро размещено в RAM 0x3000 (исполняемость RAM доказана
эпилогом фаз A–C).

## Reproduction

```sh
# standalone-репродуцер (C, оба счётчика):
make TARGETS=issue80_core run_verilator CROSS_PREFIX=<...> STATE_DUMP=1
# RTL: __FAIL rc=3 (mcycleh=1, minstreth=1); Spike: PASS
# verify: docker/scr1-spike/verify_issue80_core.sh (лог logs/reducer/issue80_core_build_run.log)
```

Ветка scr1: `test/mcycle-issue80` (коммит 3c2a6f0, `sim/tests/issue80_core/` +
цель в топ-Makefile).

## Evidence

* `docker/scr1-spike/logs/mcycle*` — дифференциальные прогоны;
* `build/trace/mcycle_rtos.log` / `issue80_core.log` — TRACE_LOGGER-трассы;
* `<test>_state.txt` — снапшоты CSR (RTL vs Spike);
* отчёт редуктора: `logs/reducer/RESULT_*.md` (worktree `instruction-reducer`),
  артефакты ядра — `logs/reducer/` (gitignored).

## Lessons

1. Дифференциалка «Spike vs RTL» на длинных RTOS-прогонах находит CSR-баги,
   невидимые коротким тестам (счётчики успевают переполниться).
2. Редукция до 11 инструкций превращает «плавающий» баг большой системы в
   доказуемую семантическую формулу (2 предусловия + 1 виновная инструкция).
3. Контрастная пара larger/smaller с единственным отличием (виновная
   инструкция → NOP) — строгое доказательство причинности.
