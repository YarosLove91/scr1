# Issue #80: запись младшей половины `mcycle` ложно инкрементирует `mcycleh`

- Upstream: https://github.com/syntacore/scr1/issues/80
- Статус в этом дереве: **баг присутствует** (ветка `feat/per-test-traces`, как и `origin/master`
  `56aabbd`). Патч ниже — справочный, **НЕ применён**.
- Тест-репродуктор: `sim/tests/mcycle/` (цель `mcycle` в топ-Makefile; изначально из stash
  `0e1f1edb`, ветка `scr1-run-tests`).

## Симптом

RV32. Запись младшей половины счётчика (`csrw mcycle, x`) изменяет старшую половину `mcycleh`,
хотя 32-битная запись не может дать перенос в биты [63:32]. По спецификации (RISC-V Privileged,
Hardware Performance Counters) `csrw mcycle` влияет только на `mcycle[31:0]`; `mcycleh` меняется
лишь при реальном 64-битном переносе счётчика или явной записи `mcycleh`.

Условие проявления: `mcycle[31:8] == 0xFFFFFF` (любое значение, при котором `+1` в разрядной
сетке [63:8] даёт перенос из битa 31 в бит 32).

## Репродукция

```
cd scr1
make run_verilator CFG=MAX BUS=AHB TARGETS=mcycle
```

Тест: `mcycleh=0; mcycle=0xFFFFFF00; 4×nop; csrw mcycle,0;` чтение `mcycleh/mcycle`;
exit 0 = корректно, 1 = баг.

| Сторона | `mcycleh` после | Консоль | Итог |
|---|---|---|---|
| SCR1 RTL (Verilator 5.052, CFG=MAX BUS=AHB) | **0x00000001** | `BUG #80 reproduced` | `mcycle.hex __FAIL` (a0=1) |
| Spike master `2c300cd9` (тот же `mcycle.elf`) | **0x00000000** | `OK: mcycleh unchanged` | a0=0 |

Прогон Spike (2026-10-24, docker-образ `scr1-spike-verif`, один бинарь на обеих сторонах):

```
spike --no-dm --disable-dtb --pc=0x200 --isa=rv32imc_zicsr_zifencei \
  -m0x0:0x10000,0x480000:0x10000,0x490000:0x1000,0xf0000000:0x1000 \
  -l --log-commits mcycle.elf | sed '/0x000000f8 (0x0000006f)/q'
```

Артефакты дифференциального прогона: `barnsley/docker/scr1-spike/logs/mcycle/` (RESULT.md, логи,
восстановленная консоль Spike, commit-лог).

## Корень проблемы

`src/core/pipeline/scr1_pipe_csr.sv`. Счётчик хранится раздельно: `csr_mcycle_lo_ff` = биты [7:0],
`csr_mcycle_hi_ff` = биты [63:8] (вектор `[63:8]`). `csr_mcycle_hi_new = csr_mcycle_hi_ff + 1'b1`
— это значение «инкремент при переполнении младшего байта», оно корректно ТОЛЬКО в ветке
`csr_mcycle_hi_inc`. Обе **записные** ветки (`csr_mcycle_upd[0]` — запись `mcycle`,
`csr_mcycle_upd[1]` — запись `mcycleh`) ошибочно берут преднакрементированное `..._hi_new`:

- строки 908–909 (`mcycle`): при `mcycle[31:8]=0xFFFFFF` и записи младшей половины
  `hi_new[63:32] = hi_ff[63:32] + 1` → `mcycleh` ложно увеличивается на 1;
  ветка `upd[1]` симметрично портит `mcycle[31:8]` (берёт `hi_new[31:8]` вместо `hi_ff[31:8]`).
- строки 945–946 (`minstret`): **идентичный паттерн** (`csr_minstret_hi_new` в записных ветках) —
  issue #80 упоминает только `mcycle`, но `minstret` поражён так же.

```systemverilog
// текущий (бажный) код, mcycle — строки 903–911:
assign csr_mcycle_hi_new  = csr_mcycle_hi_ff + 1'b1;
...
assign csr_mcycle_hi_next = csr_mcycle_upd[0] ? {csr_mcycle_hi_new[63:32], csr_w_data[31:8]}
                          : csr_mcycle_upd[1] ? {csr_w_data, csr_mcycle_hi_new[31:8]}
                          : csr_mcycle_hi_inc ? csr_mcycle_hi_new
                                              : csr_mcycle_hi_ff;
```

## Патч (НЕ ПРИМЕНЁН — только описание исправления)

```diff
--- a/src/core/pipeline/scr1_pipe_csr.sv
+++ b/src/core/pipeline/scr1_pipe_csr.sv
@@ -905,8 +905,8 @@
 assign csr_mcycle_lo_next = csr_mcycle_upd[0] ? csr_w_data[7:0]
                           : csr_mcycle_lo_inc ? csr_mcycle_lo_ff + 1'b1
                                               : csr_mcycle_lo_ff;
-assign csr_mcycle_hi_next = csr_mcycle_upd[0] ? {csr_mcycle_hi_new[63:32], csr_w_data[31:8]}
-                          : csr_mcycle_upd[1] ? {csr_w_data, csr_mcycle_hi_new[31:8]}
+assign csr_mcycle_hi_next = csr_mcycle_upd[0] ? {csr_mcycle_hi_ff[63:32], csr_w_data[31:8]}
+                          : csr_mcycle_upd[1] ? {csr_w_data, csr_mcycle_hi_ff[31:8]}
                           : csr_mcycle_hi_inc ? csr_mcycle_hi_new
                                               : csr_mcycle_hi_ff;
@@ -942,8 +942,8 @@
 assign csr_minstret_lo_next = csr_minstret_upd[0] ? csr_w_data[7:0]
                             : csr_minstret_lo_inc ? csr_minstret_lo_ff + 1'b1
                                                   : csr_minstret_lo_ff;
-assign csr_minstret_hi_next = csr_minstret_upd[0] ? {csr_minstret_hi_new[63:32], csr_w_data[31:8]}
-                            : csr_minstret_upd[1] ? {csr_w_data, csr_minstret_hi_new[31:8]}
+assign csr_minstret_hi_next = csr_minstret_upd[0] ? {csr_minstret_hi_ff[63:32], csr_w_data[31:8]}
+                            : csr_minstret_upd[1] ? {csr_w_data, csr_minstret_hi_ff[31:8]}
                             : csr_minstret_hi_inc ? csr_minstret_hi_new
                                                   : csr_minstret_hi_ff;
```

Ветка `..._hi_inc ? ..._hi_new` остаётся без изменений — это легитимный путь инкремента при
переполнении младшего байта.

## Проверка после применения патча (когда потребуется)

1. `make run_verilator CFG=MAX BUS=AHB TARGETS=mcycle` → ожидается `PASS` (a0=0).
2. Повторный дифференциальный прогон против Spike (драйвер `run_mcycle.sh` в
   `docker/scr1-spike/logs/mcycle/`) → обе стороны `mcycleh=0`.
3. Регрессия: полный набор тестов не должен менять результатов (счётчики в тестах не
   используются как оракул, кроме самого mcycle).
