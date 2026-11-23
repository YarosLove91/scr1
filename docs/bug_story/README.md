# SCR1 Bug Stories

Кейсы найденных ошибок в формате `bug_story` (шаблон из
`riscv-core-dv-uvm/bug_story/BUG.md`): Bug ID / detection method / seed или
тест / mismatch-пример / root cause / evidence / lessons.

| ID | Кейс | Класс | Статус |
|---|---|---|---|
| [BUG-001](BUG-001-mcycle-issue80.md) | mcycleh/minstreth после `csrw mcycle,0` (issue #80) | CSR-логика, реальный upstream-баг | Подтверждён, репродуцер `sim/tests/issue80_core` |
| [BUG-002](BUG-002-demo-poison-add.md) | poison_add — data-dependent ADD (+1 при op1[15:8]==0xA5) | ALU, синтетическая инжекция (демо редуктора) | Closed, RTL откачен |
| [BUG-003](BUG-003-imem-waitstates.md) | IMEM AHB wait-states ломают выборку (trap-луп) | IFU/memory-tb, найден coverage-кампанией | **OPEN-CANDIDATE**, native-репро, ждёт VCD-триажа |

Связанные находки интеграции (не RTL-баги):

* **mtvec 64B** — SCR1 аппаратно обнуляет `mtvec.BASE[5:0]`;
  сгенерированные riscv-dv программы без 64B-выравнивания `mtvec_handler`
  ловят trap-луп (seed 1140580336 регрессии `dv/fuzz`). Подробности —
  `dv/fuzz/README.md` → «Находка №1». Оформляется как BUG-003 при первом
  реальном (не генераторном) проявлении.

## Как добавлять кейсы

1. Скопировать структуру BUG-001 (заголовок-блок, Executive Summary,
   Discovery, Symptoms, Analysis/Root Cause, Reproduction, Evidence, Lessons).
2. Обязательно: воспроизводимый идентификатор (seed / тест / коммит),
   пример расхождения (ожидалось vs факт), ссылка на артефакты (логи/VCD/
   отчёты редуктора), контрастная пара для подтверждённых багов.
3. Обновить таблицу выше.

Для находок fuzz-регрессии (`dv/fuzz`) исходные данные берутся из
`work/seed_<n>/run.log` (first-mismatch коммиты печатает
`scr1_diff_scoreboard.MISMATCH` с pc/instr/rd обеих сторон).
