# Bug Story: data-dependent ADD corruption (poison_add) — reducer generalization demo

**Bug ID**: SCR1-DEMO-POISON-ADD (синтетический, преднамеренная инжекция)
**Date Discovered**: 2026-10-30 (демо обобщаемости instruction reducer)
**Severity**: n/a (демо; баг инжектирован локально и откачен, НЕ закоммичен)
**Status**: Closed (демо завершено, RTL чист, контроль после отката пройден)
**Branch**: `demo-addbug` (barnsley, 3c75f85) — только тест-контрпример и отчёты

---

## Executive Summary

Проверка обобщаемости редуктора (redlib) на ДРУГОМ классе аппаратных ошибок:
вместо CSR-бага (issue #80) — data-dependent баг ALU. В `scr1_pipe_ialu.sv`
(mux `CMD_ADD`) инжектировано: результат ADD увеличивается на 1 при
`op1[15:8] == 0xA5`; SUB/branch/slt и адресный сумматор не затронуты.
Редуктор, построенный для issue #80, нашёл виновную инструкцию ТОЧНО без
переобучения (45/120 RTL-прогонов, 2.2 c).

## Bug Discovery

- **Среда**: та же дифференциальная связка Spike vs RTL (docker `scr1-spike-verif`).
- **Контрпример**: `addbug.S` (RAM-only, 70 инструкций): 16 `add` накапливают
  сумму `0xA500`, затем 3 «отравленных» `add` (метка `poison_add` @0x250).

## Initial Symptoms

```
RTL  : sum = 0xA5A8   (+3 = три срабатывания poison-условия)
Spike: sum = 0xA5A5
```

## Reducer Result (демо OK)

| Параметр | Значение |
|---|---|
| Бюджет | 45/120 RTL-прогонов, 2.2 c |
| Хвостовой бинпоиск | failing = `poison_add` ТОЧНО (коммит 21/67) |
| Head-cut | p* = 19 (окно 1 инструкция, setter 33 слова, restore 0B) |
| ddmin | essential = restore `a1=0xA500` (2 слова); restore t1 выброшен (баг op1-условен — ddmin выявил автоматически) |
| Контраст | larger = SameBug / smaller = NoBug |

Обобщение стоило ~120 строк: `oracle.py` — pluggable Signature
(`Signature80.classify_state` перенесена дословно + `SignatureSum/extract_sum`),
`rtl.py` — latin-1 decode + `extract_program_console`, `encode.py` —
add/sub/srli/ori/andi + T4–T6, `demo_addbug.py/.sh` + `rebuild_model.sh`.
Остальной redlib (IR, slicer, spike, trace, ctxsetter, stub/tramp, кэш v6) —
БЕЗ изменений.

## Root Cause (инжектированный)

`src/core/pipeline/scr1_pipe_ialu.sv`, ветка mux `CMD_ADD`:
`sum + (op1[15:8] == 8'hA5)` — 1 строка; откачена сразу после демо
(контроль: scr1 чист, модель пересобрана за 11 c, `issue80_core` снова PASS).

## Evidence

* Отчёт: `logs/reducer/RESULT_demo_addbug.md`;
* Артефакты: `logs/reducer/demo_addbug/` (gitignored; worktree `instruction-reducer`);
* Ветка `demo-addbug` barnsley: контрпример `addbug.S`, скрипты демо.

## Lessons (важно для фаззер-потока)

1. **Verilator `$write("%c", 0)` ГЛОТАЕТ NUL** — сырые байты в консоли RTL
   небезопасны → кодирование digit-парами `'0'..':'` (lossless, без коллизий
   с маркером).
2. Консоль RTL извлекать из региона `---Test:` .. `Test passed/failed/TIMEOUT`
   (`S` в «# Summary» отравлял `rfind`).
3. Trigger-range по PC ловит и сам stub — учитывать в сигнатурах.
4. **Data-dependent баг ⇒ restore операнда существен** (NOP вместо restore →
   NoBug); ddmin выявляет это автоматически.
