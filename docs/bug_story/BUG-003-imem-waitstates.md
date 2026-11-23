# Bug Story (CANDIDATE, не триажирован): IMEM AHB wait-states ломают исполнение

**Bug ID**: SCR1-CANDIDATE-003 (imem-stall corruption)
**Date Discovered**: 2026-11-15 —Coverage-кампания (закрытие stall-кроссов
`x_cat_stall` в `dv/uvm/tb/scr1_fcov_if.sv`)
**Severity**: потенциально High (поведение шины IMEM при легитимных AHB
wait-states; в SoC с реальной памятью/FIFO это рабочий режим)
**Status**: FIXED-PATCH-READY — механизм подтверждён (эксперимент с
mem-агентом ниже + код-ревью): баг легаси `scr1_memory_tb_ahb`, НЕ ядра.
Патч: ветка `fix/mem-tb-imem-stall` @ faec15f (от master 0342a00),
экспорт `barnsley/PROMTS/patches/0001-fix-scr1-gate-IMEM-hready-*.patch`.
Native-верификация патча: baseline hello/isr_sample/a5_1 OK/PASS (без
изменений), imem_pattern=0 / 55555555 / imem+dmem=55555555 — все OK/PASS
(до патча __FAIL). Merge — по решению пользователя.

---

## Executive Summary

При включённых задержках выдачи инструкций (AHB wait-states на IMEM-канале)
ядро SCR1 (CFG=MAX) через несколько сотен циклов ловит трап и уходит в
бесконечный trap-луп (`trap_entry`/0x1C0, mcause=2 illegal instruction),
т.е. выборка инструкций искажается, а не просто замедляется. Задержки на
DMEM-канале (те же механизмы memory tb) работают корректно. Воспроизводится
и в нативном потоке (`make run_verilator imem_pattern=...`), и в UVM.

## Bug Discovery

Закрытие бинов `cp_retire_stall.imem_stall/both_stall` и кросса
категория×stall: прогоны `dv/uvm` c `IMEM_PATTERN`/`DMEM_PATTERN`
(плюсарги `+imem_pattern/+dmem_pattern` → `scr1_memory_tb_ahb`).

## Матрица воспроизведения (hello.hex, CFG=MAX, Verilator 5.053)

| imem_pattern | dmem_pattern | UVM | native (`run_verilator`) |
|---|---|---|---|
| FFFFFFFF (без задержек) | FFFFFFFF | PASS 16990 циклов | PASS |
| 0 (random) | FFFFFFFF | FAIL, trap-луп pc=0x33a (`trap_entry`) | **FAIL (`__FAIL`)** |
| 55555555 | FFFFFFFF | FAIL, timeout pc=0x1C0 | — |
| AAAAAAAA | FFFFFFFF | FAIL, timeout pc=0x1C0 | — |
| FFFFFFFF | 0 (random) | PASS | — |
| 55555555 | 55555555 | FAIL | **FAIL (`__FAIL`)** |
| FFFFFFFF | 0 + isr_sample | PASS (a0=0) | — |

Семантика паттернов (`scr1_memory_tb_ahb.sv:194-205`): `pattern==0` →
`req_ack = $random` (случайные wait-states); иначе `req_ack = pattern[0]`
с ротацией (детерминированные). FFFFFFFF → ack всегда (задержек нет).

## Symptoms

* UVM: `scr1_driver.TIMEOUT ... pc=0x000001c0/0x1c2/0x33a` — ядро крутится
  в default trap vector (нули → illegal → трап → снова 0x1C0) или в
  `trap_entry`-лупе;
* native: `hello.hex OK __FAIL` (watchdog);
* DMEM-only задержки — полностью корректны (hello/isr_sample PASS,
  live dmem stall-бины покрытия биты).

## Hypotheses (не проверены)

1. `scr1_memory_tb_ahb` IMEM FSM: протокол hready/hrdata при случайном
   `req_ack` (данные/ready рассинхронизируются с адресной фазой) — баг TB,
   не ядра;
2. SCR1 IFU: нарушение AHB-рукопожатия при wait-states (реальный баг ядра);
3. Гонка `imem_req_ack_rnd <= $random` (обновление каждый такт) с FSM.

## Next triage steps

* VCD (`make waves` / native `run_verilator_wf`) на первых ~500 тактах
  имем-столлов: сравнить htrans/haddr/hready/hrdata с AHB-протоколом;
* локализовать первую искажённую выборку (расхождение pc/инструкции против
  бесstall-прогона тем же `TRACE_LOGGER`);
* при подтверждении TB-бага — патч memory tb (fork), при ядровом — issue.

## Impact on coverage

Бины `cp_retire_stall.imem_stall/both_stall` и соответствующие ячейки
`x_cat_stall` недостижимы до фиксации; `cp_live_imem_stall.stall_`
наблюдается только транзиентно (арбитраж при dmem-столлах).

---

## Эксперимент с mem-агентом (этап B, 2026-11-15)

Реактивный UVM AHB memory-агент (`dv/uvm`, флаг сборки `MEM_AGENT=1`,
ветка `feat/uvm-mem-agent`) заменяет `scr1_memory_tb_ahb` корректным
AHB-slave: wait-states реализуются как `hready=0` с удержанием адреса/данных
(плюсарги `+AGENT_IMEM_STALL=<N>` / `+AGENT_DMEM_STALL=<N>`, N тактов на
адресную фазу каждой транзакции; `FFFFFFFF`-эквивалент = 0 = тайминги
легаси). Агент НИКОГДА не выдаёт данные при `hready=0` и не возвращает
`hrdata='x` при `hready=1`.

### Результат: core жив при легитимных IMEM wait-states

Команды (из `scr1/dv/uvm`, тулчейн xPack 15.2.0):

```sh
make run MEM_AGENT=1 SW_TEST=hello AGENT_IMEM_STALL=1   # PASS 24233 цикла
make run MEM_AGENT=1 SW_TEST=hello AGENT_IMEM_STALL=3   # PASS 31479 циклов
make run MEM_AGENT=1 SW_TEST=hello AGENT_DMEM_STALL=1   # PASS 20592
make run MEM_AGENT=1 SW_TEST=hello AGENT_DMEM_STALL=3   # PASS 24194
make run MEM_AGENT=1 SW_TEST=hello AGENT_IMEM_STALL=3 AGENT_DMEM_STALL=3  # PASS 38683
make run MEM_AGENT=1 TEST_HEX=sw/build/a5_1.hex AGENT_DMEM_STALL=3   # PASS 18972, keystream идентичен
make run MEM_AGENT=1 TEST_HEX=sw/build/isr_sample.hex AGENT_IMEM_STALL=3  # PASS 535 (3 IRQ)
```

| Прогон (MEM_AGENT=1) | Stall | Циклы | Вердикт |
|---|---|---|---|
| hello | без stall (parity) | 16990 (= легаси) | PASS |
| hello | IMEM=1 | 24233 | **PASS** |
| hello | IMEM=3 | 31479 | **PASS** |
| hello | DMEM=1 / DMEM=3 | 20592 / 24194 | PASS |
| hello | IMEM=3 + DMEM=3 | 38683 | PASS |
| a5_1 | DMEM=3 | 18972 | PASS, keystream `10011101001010000001` |
| isr_sample | IMEM=3 / DMEM=3 | 535 / 477 | PASS, a0=0 |

**ВЫВОД: зависание из матрицы воспроизведения — баг легаси
`scr1_memory_tb_ahb`, а не IFU ядра (гипотеза 1 подтверждена как
механизм).** Код-ревью легаси FSM даёт точный механизм: в IMEM-канале
`imem_hready = 1'b1` БЕЗУСЛОВНО (always_comb, строки ~315-333) — при
`imem_req_ack=0` (random/ротация паттерна) память остаётся в
`SCR1_AHB_STATE_DATA`, НЕ приостанавливая шину, и выдаёт
`imem_hrdata = 'x` (в 2-state Verilator → `0x00000000`) с `hready=1` и
`hresp=OKAY` ⇒ IFU принимает нулевую «инструкцию» ⇒ illegal (mcause=2)
⇒ trap-луп. Это не wait-states, а коррапция выборки: AHB-корректный
аналог (агент) с теми же задержками проходит все прогоны. SCR1 IFU
корректно обрабатывает настоящие wait-states (`hready=0` в адресной
фазе).

Статус кейса оставлен OPEN-CANDIDATE (формальная смена статуса и
патч/fork легаси memory tb — отдельное решение); RTL не правился.

### Побочный результат: stall-покрытие разблокировано

COV-прогон агента (`make run MEM_AGENT=1 COV=1 SW_TEST=hello
AGENT_IMEM_STALL=3 AGENT_DMEM_STALL=3 RUN_TAG=agent_stall` +
`make cov_merge`): merged covergroup **54.9% (339/617)** — впервые
заполнены `cp_retire_stall.imem_stall` (29) и `both_stall` (1784),
imem/both-колонки кросса `x_cat_stall`; `exc_cg.load_access` EC5 (1)
теперь достижим (агент отвечает `hresp=ERROR` на dmem-доступы вне
известных окон — легаси заворачивал их в массив и отвечал OKAY).
