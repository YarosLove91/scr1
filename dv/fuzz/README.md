# SCR1 fuzz-поток: riscv-dv → UVM + Spike lockstep

Генераторный слой аппаратного фаззинга SCR1 (паттерн из оценки
`riscv-core-dv-uvm`): **seed → riscv-dv (pygen) asm → патч под SCR1 →
gcc → verilog hex → `dv/uvm` прогон с in-process Spike (2B) и CSR RAL →
`SCR1_RESULT` / first-mismatch**.

```
dv/fuzz/
├── Makefile                  # venv / submodule / gen / patch / elf / hex / fuzz
├── riscv-dv/                 # SUBMODULE: github.com/google/riscv-dv (pygen)
├── pygen_ext/                # namespace-overlay таргета (сабмодуль НЕ правится):
│   └── pygen_src/target/scr1/
│       ├── riscv_core_setting.py   # RV32IMC, M-mode, CSR-набор SCR1 (без
│       │                             # mcounteren; +mcycle/minstret/*h)
│       ├── testlist.yaml           # arithmetic_basic, rand_instr, fence, csr_rand
│       ├── iss.yaml                # spike-флаги SCR1 (справочно)
│       └── link.ld                 # ORIGIN 0x200 (reset vector), 64K RAM
├── tools/patch_asm.py        # эпилог write_tohost → 0xF8/a0 + кэп стеков
│                             # + balign64 mtvec_handler + CSR-инъекция
└── work/                     # seed_<N>/ (asm, elf, hex, dump) — gitignored
```

## Быстрый старт

```sh
cd scr1/dv/fuzz
make venv          # один раз: .venv (python3.11) + pyvsc/pyboolector(пины!)
make submodule     # один раз: git submodule update --init
# CROSS_PREFIX и SPIKE_ROOT передаются явно (хардкод путей запрещён):
make fuzz SEED=1 CROSS_PREFIX=<tools>/bin/riscv-none-elf- \
          SPIKE_ROOT=<path>/riscv-isa-sim
make fuzz SEED=7 TEST=riscv_rand_instr_test CROSS_PREFIX=... SPIKE_ROOT=...
make fuzz SEED=42 SPIKE_COSIM=0 CROSS_PREFIX=...   # без косима (SPIKE_ROOT не нужен)
```

Ключи: `TEST`, `SEED`, `STACK_MAX` (кэп `.rept` стеков, дефолт 1000 слов),
`UVM_TEST` (дефолт `scr1_csr_test` — прогоняет и RAL-проверки),
`SPIKE_COSIM` (дефолт 1; требует `SPIKE_ROOT` — дерево riscv-isa-sim с
собранными статическими либами), `CROSS_PREFIX` (дефолт
`riscv64-unknown-elf-` как в корневом Makefile scr1), `VENV` (дефолт
`$(pwd)/.venv`, gitignored).

## Seed-регрессия

```sh
make regress NUM_SEEDS=8 CROSS_PREFIX=... SPIKE_ROOT=...
make regress PRESERVE_SEEDS=1 ...   # повтор того же набора (work/seeds.txt)
```

`tools/gen_seeds.py` пишет N случайных seed'ов в `work/seeds.txt`; каждый seed
проходит полный fuzz-поток, лог — `work/seed_<n>/run.log`; `tools/summarize.py`
печатает сводную таблицу (verdict/commits/diff_mm/csr_mm/uvm_err) и возвращает
ненулевой код при любом FAIL (CI-ready).

### Находка №1 регрессии: mtvec 64B (seed 1140580336)

Первые же случайные seed'ы дали 3 FAIL: SCR1 аппаратно обнуляет
`mtvec.BASE[5:0]` (гранулярность 64B, `scr1_csr.svh`: "bits [5:0] are always
zero"), а riscv-dv линкует `mtvec_handler` без 64B-выравнивания (seed
1140580336: handler на 0xfd0 → SCR1 traps на 0xfc0 = середина `jr t6` →
illegal-instruction trap-луп; Spike при этом исполнял корректный base →
лавина mismatch). Это ограничение интеграции (не баг RTL): `patch_asm.py`
теперь вставляет `.balign 64` перед `mtvec_handler:`. После фикса все три
seed'а PASS (424/904/2285 коммитов, 0 расхождений).

## Адаптации под SCR1 (почему нужен патч и overlay)

1. **Эпилог**: riscv-dv завершает программу `ecall → write_tohost: sw gp,tohost`
   (бесконечный цикл). Конвенция SCR1-tb другая: конец = PC `0xF8`,
   PASS = `a0==0`. `tools/patch_asm.py` заменяет блок `write_tohost`
   на `gp==1 → a0=0 (иначе a0=gp); jr 0xF8`.
2. **64K RAM**: pygen эмитит стеки `.rept 4999/3999` (36 КБ) — вместе с
   текстом переполняют окно RAM 0x0–0xFFFF. Патч кэпит все `.rept N` до
   `STACK_MAX` (дефолт 1000 → 2×4 КБ). Бюджет: текст ≤ ~40 КБ
   (instr_cnt ≤ ~4000 при STACK_MAX=1000).
3. **link.ld**: `ORIGIN = 0x200` (SCR1_ARCH_RST_VECTOR), без TCM-релокации —
   всё исполняется из RAM; hex получается `objcopy -O verilog` (байт-токены
   + `@addr`, как ждёт `$readmemh` memory tb и DPI-загрузчик 2B).
4. **Длина пути вектора**: stage-A загрузчик `dv/uvm` принимает полный SV
   `string`-путь без ограничения длины — Makefile передаёт
   `TEST_HEX=$(abspath $(HEX))` напрямую, никакого копирования в короткое
   имя (старый механизм `test_file logic[255:0]` memory tb лимитил путь
   32 символами; абсолютный путь ~77 символов молча обрезался → нулевая
   память → trap-луп). Драйвер дополнительно делает `$fopen` pre-check и
   readback-верификацию слова на 0x200 после загрузки.
5. **pygen-таргет без правки сабмодуля**: pygen резолвит конфиг как
   `pygen_src.target.<target>.riscv_core_setting`; `pygen_src` — namespace-пакет,
   поэтому `PYTHONPATH=pygen_ext:riscv-dv/pygen` прозрачно добавляет таргет
   `scr1` (файлы сабмодуля не изменяются).
6. **Зависимости pygen**: python3.11 venv; пины из requirements.txt riscv-dv
   критичны для пары pyvsc↔pyboolector: системный `PyBoolector` не имеет
   `BTOR_OPT_INCREMENTAL` → randomize падает; нужен `pyboolector==3.2.4.20240823.1`.
   `run.py` внутри вызывает `python3` — venv должен стоять первым в PATH
   (Makefile это делает).

## Проверено (Verilator 5.053 + in-process Spike, xPack gcc 15.2.0)

| Seed | Тест | Commits (matched/всего) | CSR RAL | Вердикт |
|---|---|---|---|---|
| 1 | riscv_arithmetic_basic_test | 971/971 | 0 расхождений | PASS |
| 7 | riscv_rand_instr_test | 832/832 | 0 расхождений | PASS |
| 42 | riscv_arithmetic_basic_test | 899/899 | 0 расхождений | PASS |
| 999 | riscv_csr_rand_test (12 CSR-inj) | 365/365 | 0 расхождений | PASS, traps=1 |
| 601266182 | riscv_csr_rand_test (репро находки) | 573/573 | 0 расхождений | PASS, traps=1 |
| 1813697294 | riscv_csr_rand_test (репро находки) | 402/402 | 0 расхождений | PASS, traps=1 |
| regress 8 fresh seeds | riscv_csr_rand_test | 319..858/все | 0 расхождений | 8/8 PASS, traps=1 |

(Пропущенные trap-коммиты — фильтруемые scoreboard'ом трапы: 2 на прогон
в таблице записаны ДО легализации j-spin на 0xF8 (commit 1bc8efa) —
`ecall` завершения + illegal-трап дренажа на выборке нулей по 0xF8; после
фикса оставался 1 skip (`ecall`), а после trap-выравнивания (2B, 2026-11-18)
и он перестал быть skip'ом: финальный ecall сверяется с golden TRAP-записью
Spike (mepc+mcause 1:1) — seed 1: 970/970 matched, trap_checked=1, 0 skip;
seed 7: 831/831, trap_checked=1. Контрольный прогон seed 1 на stage-A
загрузчике (string-путь, абсолютный `TEST_HEX`): 969/969 matched,
0 расхождений (числа ДО trap-выравнивания). Фактическое число retire может
быть меньше `+instr_cnt` — riscv-dv считает сгенерированные потоки
по-своему.)

## Автогенерируемое ISA-покрытие (cov_isa, подход ibex get_fcov)

ibex берёт ISA-покрытие НЕ из рукописных covergroup, а из **riscv-dv
coverage flow**: trace CSV → `riscv_instr_cov_test` → pyvsc-covergroup'ы,
автогенерируемые по ISA-реестру таргета (на каждую инструкцию — своя группа:
операнды, знаки,imm-диапазоны, rd/rs…). Мы повторяем этот поток:

```sh
make cov_isa ELFS="work/seed_1/*.elf work/seed_7/*.elf"   # или все seed_* по умолчанию
# отчёт: work/cov/CoverageReport.txt (+ sim_riscv_instr_cov_test_*.log с деталями)
```

Цепочка: ELF → spike `-l --log-commits` (tools/bin/spike) →
`../uvm/tools/spike_log2csv.py --keep-log` → конвертер riscv-dv
`process_spike_sim_log` → trace CSV → `cov.py --iss spike --simulator pyflow
--target scr1` → pyvsc-отчёт.

Грабли riscv-dv, которые обходит Makefile:
* `cov.py` НЕ передаёт `--isa` в run.py → при isa без «c» тот добавляет
  `+disable_compressed_instr=1`, который pygen-argparse не понимает →
  передаём `--opts=--isa=rv32imc` (ibex в get_cov_cmd тоже передаёт --isa);
* `riscv_instr_cov_test` берёт каталог отчёта как
  `log_file_name.split("/")[0]` → абсолютные пути ломаются
  (`/CoverageReport.txt`) → все пути относительны `work/`;
* конвертер spike-лога — FSM, ждущий маркер конца boot-ROM-трамплина
  `pc 0x1010`; мы грузимся `--disable-dtb --pc=0x200` и его не проходим →
  Makefile препендит маркер-строку в каждый лог (конвертер её съедает);
* конвертер останавливается на первом `ecall` (конвенция riscv-dv) —
  в ISA-покрытие попадает тело программы, эпилог/handler не семплируются.

### Результат на 3 векторах (seeds 1, 42, 7)

2427 инструкций, **147 автоген-covergroup, 49 ненулевых, avg 23.5 %**;
addi_cg 86.1 %, sra_cg 80.1 %, add_cg 78.9 %, sub_cg 78.1 %, lui_cg 72.9 %,
ori_cg 71.9 %, auipc_cg 69.8 %, beq_cg 67.6 %, rv32i_misc_cg 60 %.
Нули — инструкции, которых пока не генерируем (data pages выключены,
CSR-инструкции в теле выключены) — цели расширения генерации.

Опция: `--enable_visualization` в cov.py → `cov_db.xml` для pyucis-viewer
(HTML); pyucis ставится в venv отдельно.

## Направленный coverage-вектор (cov_directed)

`sw_directed/scr1_cov_directed.S` детерминированно закрывает трудные бины
fcov: fence/fence.i, ecall, ebreak, c.ebreak, misaligned lw/sw (EC 4/6),
unmapped sw (EC 7) — со своим trap-handler'ом (mepc += 2/4; чтение mepc
байтовыми lbu: lhu на нечётном mepc стрепился бы повторно). Запускается
БЕЗ Spike-lockstep (`SPIKE_COSIM=0` автоматически): Spike исполняет
misaligned-доступы нативно и неминуемо расходится с трапящим SCR1.

```sh
make cov_directed COV=1 CROSS_PREFIX=...
```

В testlist добавлен `riscv_fence_test` (как rand_instr, но БЕЗ `+no_fence`).
**ВНИМАНИЕ (находка 2026-11-18): pygen master фактически НЕ генерирует fence
в теле** — см. баги категорий в секции «CSR-фаззинг» ниже (SYNCH-список
append'ится вложенным списком и недостижим выбором `randrange(0, len-1)`):
seed 77 736/736 PASS — это обычный ALU-микс, fence-бины fcov закрывал
cov_directed, не этот тест. Кандидат-фикс: инъекция fence в patch_asm.py
(тот же механизм, что для CSR) или upstream-фикс pygen.

## CSR-фаззинг (riscv_csr_rand_test + инъекция в patch_asm)

**Баги pygen master (находка 2026-11-18)** — случайное тело НИКОГДА не
генерирует ни CSR-инструкции, ни fence; два независимых дефекта
`build_basic_instruction_list()` (riscv_instr.py:199-205):
1. CSR-категория добавляется при `init_privileged_mode == "MACHINE_MODE"`,
   но `init_privileged_mode` — ПЕРЕЧИСЛЕНИЕ `privileged_mode_t.MACHINE_MODE`;
   сравнение enum со строкой всегда False (то же сравнение в
   `create_csr_filter` оставляет include_reg пустым);
2. списки категорий (SYNCH/CSR) append'ятся в `basic_instr` ВЛОЖЕННЫМИ
   списками, а выбор идёт `random.randrange(0, len(include_instr) - 1)` —
   ПОСЛЕДНИЙ элемент не выбирается никогда; при дефолтах no_wfi/no_ebreak/
   no_dret=1 список SYNCH оказывается последним (см. fence выше), а CSR
   не добавляется вовсе из-за бага 1. Плюс сам 12-битный csr-адрес в pygen
   не ограничен (`csr_c` = TODO) — «починка» только бага 1 дала бы случайные
   CSR-адреса по всему 12-битному пространству (несовпадающие наборы
   реализованных CSR у SCR1/Spike → ложные расхождения). Upstream issue/PR —
   TODO.

Обход БЕЗ правки сабмодуля: `riscv_csr_rand_test` (= rand_instr) +
`CSR_INJECT=12` по умолчанию для этого теста — `tools/patch_asm.py`
инъектирует N случайных CSR-инструкций в тело (между `main:` и
`test_done:`, детерминированно от SEED, метка `# csr-inject`).

Whitelist (безопасность SCR1-vs-Spike lockstep; полный WARL-анализ —
докстринг patch_asm.py):
* **mepc 0x341 / mtval 0x343 — ВСЕ формы** (csrrw/csrrs/csrrc, i-варианты,
  csrr): хранение архитектурно идентично (mepc bit0 маскируется RVC у обеих
  моделей) → read-back'и равны; аппаратно перезаписываются на входе в трап;
  mret в теле не появляется (CSR-категория pygen мертва);
* **mscratch 0x340 — ТОЛЬКО чтение** (csrr): это swap-скретч trap-handler'а
  (`csrrw xB, 0x340, xB`); сам swap симметричен и мусор там пережил бы трап,
  но записи ничего не дают (cp_csr бин и так закрывает handler), а риск
  не нужен;
* **mcause 0x342 — ТОЛЬКО запись** (rd=x0): WARL read-back расходится
  (SCR1 хранит {i,25'b0,ec[5:0]}, Spike шире); сохранённое значение
  кросс-модельно не сверяется (RAL-снапшот DUT-сторонний, следующий трап
  перезаписывает идентично у обеих моделей);
* **mstatus 0x300 — только csrrsi/csrrci с rd=x0** (uimm трогает биты 0-4):
  MPP[12:11] обязан остаться 11 — Spike ЧЕСТНО исполняет MPP в mret (SCR1
  зашил 11), full-width запись увела бы golden-модель в другой privileged
  mode на mret финального ecall. MIE (бит 3) IRQ не поднимет: mie=0.
* пул rd/rs1: x5-x31 минус СТАТИЧЕСКИЕ контракты (x1-x4 ra/sp/gp/tp, x10
  a0-вердикт, x27/x29 — наблюдаемые регистры handler'а) минус ДИНАМИЧЕСКИ
  разобранные из .S dst-регистры `la xR, ...stack...` (база kernel-стека:
  pygen рандомизирует её per-seed — наблюдались x29 И x31; handler читает
  её до первой записи: `add xB, xR`). Остальные регистры handler'а
  (dispatch-темпы, save/restore x1-x31) clobber-безопасны: save/restore
  симметричен → любое значение тела восстанавливается идентично у обеих
  моделей.

**Находка регрессии (seed 601266182, 1813697294)** — инъекция rd=x31 затёрла
`la x31, kernel_stack_end` → сейвы handler'а пошли по мусорному адресу →
SCR1 memory tb СТОРЫ ВНЕ ОКНА ЗАВОРАЧИВАЕТ (index wrap), а Spike faults
(store access fault, mcause=7) → trap-расхождение. Класс дивергенции
«out-of-range store: SCR1 wrap vs Spike fault» задокументирован; фикс —
динамический разбор stack-base регистров (выше).

ИСКЛЮЧЕНЫ осознанно: mtvec 0x305 (гранулярность BASE: SCR1 64B vs Spike 4B
— находка №1 регрессии), misa 0x301 (SCR1 RO vs Spike расширяема), mie/mip
(риск несопоставимых IRQ / RO), счётчики B00/B02/B80/B82/C00-C02/C80-C82
(timing by nature), mcounten 0x7E0 + IPIC 0xBF0-0xBF7 + TDU 0x7A0-0x7A7
(SCR1-only: Spike трапает illegal-instruction — расхождение потока),
F11-F14 mvendorid/marchid/mimpid/mhartid (разные константы моделей).

Результат (SPIKE_COSIM=1, trap-выравнивание включено): оба seed'а находки
после фикса — **PASS** (601266182: 573/573; 1813697294: 402/402, на каждом
trap_checked=1); seed 999 — 365/365; свежая регрессия NUM_SEEDS=8 —
**8/8 PASS**, на каждом seed'е trap_checked=1 при 0 diff/csr расхождениях
(319..858 коммитов); контрольный riscv_arithmetic_basic_test seed 1
(CSR_INJECT=0, путь НЕ изменился): 970/970, trap_checked=1, PASS.
COV=1 seed 777: cp_csr-бины mscratch/mepc/mcause/mtval/mstatus закрыты
инъекцией (были почти нулевые).

## Реактивный memory-агент (MEM_AGENT=1, этап B dv/uvm)

`MEM_AGENT=1` пробрасывается в `../uvm` (цели `run`/`cov_directed`) и
заменяет легаси `scr1_memory_tb_ahb` реактивным UVM-агентом
(подробности — `dv/uvm/README.md`, «Milestone 5 / Этап B»). Рантайм-
knobs агента также пробрасываются: `AGENT_IMEM_STALL=<N>` /
`AGENT_DMEM_STALL=<N>` (N тактов `hready=0` на транзакцию; 0 = выкл =
легаси-тайминги) и `AGENT_DMEM_ERROR_ADDR=<hex>` (инъекция `hresp
ERROR` по слову адреса).

```sh
make fuzz SEED=1 MEM_AGENT=1 SPIKE_COSIM=1 SPIKE_ROOT=... CROSS_PREFIX=...
# lockstep 969/969 PASS — агент прозрачен для Spike-сверки
make cov_directed MEM_AGENT=1 COV=1 CROSS_PREFIX=...
# PASS: unmapped lw/sw (0x20000000) теперь реально трапятся —
# агент отвечает hresp=ERROR вне известных окон (EC5/EC7 бины exc_cg)
```

ВНИМАНИЕ: легаси-плюсарги `IMEM_PATTERN/DMEM_PATTERN` агентом
игнорируются (у него своя семантика wait-states); **любые IMEM
wait-states легаси-паттернов ломают исполнение из-за бага самого
memory tb (hready=1 + hrdata='x при !req_ack) — см. этап-B эксперимент
реактивного memory-агента; stall-покрытие imem
достигается агентом** (`MEM_AGENT=1 AGENT_IMEM_STALL=3 COV=1`).

## Кампании со случайными wait-states (AGENT_RANDOM_STALL)

Knob'ы случайных wait-states агента проброшены во ВСЕ run-цели этого
Makefile (`fuzz`/`regress`/`cov_directed`/`seq_inject`):
`AGENT_RANDOM_STALL=<max>` (0/не задан = выкл = plain-профиль),
`AGENT_STALL_SEED=<n>` (дефолт 1; одинаковый seed = идентичные числа
циклов — воспроизводимость), `AGENT_RANDOM_STALL_CH=imem|dmem|both`
(дефолт both). Механизм (xorshift32 в драйвере, приоритет над
детерминированными `AGENT_<CH>_STALL`) — `dv/uvm/README.md`,
«Milestone 5 / Этап B».

Штатный режим кампании со stall'ами опирается на **timing-инвариантность
Spike-lockstep'а**: wait-states не меняют commit-поток, поэтому регрессия
под случайными stall'ами столь же валидна, как обычная. Штатная команда:

```sh
make regress NUM_SEEDS=8 SPIKE_COSIM=1 AGENT_RANDOM_STALL=2 AGENT_STALL_SEED=7 \
     CROSS_PREFIX=<...> SPIKE_ROOT=<...>
```

Результат (2026-11-21, Verilator 5.053, CFG=MAX, xPack 15.2.0, 8 свежих
seed'ов): **8/8 PASS** (271..2105 коммитов на seed), на каждом seed'е
`matched==checked`, `diff_mismatches=0`, `trap_checked=1`, `csr_diff=12`,
`UVM_ERROR=0`. Контроль на той же сборке (SEED=1, SPIKE_COSIM=1, БЕЗ
stall'ов): PASS **970/970** trap_checked=1 csr_diff=12 — plain-профиль
не дрейфовал.

**Интерпретация чисел коммитов под stall'ами**: число коммитов в
SCR1_RESULT может быть чуть МЕНЬШЕ plain-профиля (эталонный случай
967 vs 970 у seed 1 — хвостовые exit-spin коммиты при imem-stall
попадают за drain-окно scoreboards). При `matched==checked` и
`diff_mismatches=0` это **НЕ расхождение**: lockstep остаётся
timing-инвариантным, «потерянный» хвост — итерации `j .`-спина на 0xF8.

**Смешанные профили (`MIXED_STALL=1`)**: regress чередует seed'ы между
plain-профилем (нечётные позиции, AGENT_RANDOM_STALL=0) и stall-профилем
(чётные позиции, дефолты `MIXED_STALL_MAX=2` / `MIXED_STALL_SEED=7`).
Per-seed значения передаются на командной строке sub-make и побеждают
глобально заданный AGENT_RANDOM_STALL. Проверено: NUM_SEEDS=4
SPIKE_COSIM=1 MIXED_STALL=1 → **4/4 PASS**, профили в таблице 0/2/0/2
(949..2050 коммитов, 0 расхождений).

В сводной таблице `tools/summarize.py` есть колонка **stall** — профиль
AGENT_RANDOM_STALL seed'а из CFG_RANDOM-баннера драйвера (`-` = knob не
задавался).

## Ограничения / следующие шаги

* Только M-mode, без data-pages (`+no_data_page=1`): load/store-стримы
  появятся вместе с настройкой страниц данных в окне RAM (store-поток —
  основа data-sensitive сверки DRVFuzz).
* `+no_csr_instr=1` остаётся во всех тестах: pygen master не генерирует
  CSR-инструкции в теле (upstream-баги enum-vs-string и randrange — см.
  «CSR-фаззинг»); CSR-путь фуззится ИНЪЕКЦИЕЙ patch_asm.py
  (`riscv_csr_rand_test`, whitelist mscratch/mepc/mtval/mstatus/mcause).
  Остаток: fence-инъекция тем же механизмом, cp_csr-бины mie/mtvec/
  счётчиков (directed-векторами; в случайный поток нельзя — WARL/timing
  расхождения), frontdoor RAL-секвенции.
* Трапы precise-exception (ecall/ebreak/illegal/...) СРАВНИВАЮТСЯ со Spike
  (trap-выравнивание 2B: golden TRAP-запись = шаг с сопряжённой записью
  mcause+mepc; сверка mepc+mcause 1:1, trap_checked в SCR1_RESULT);
  IRQ-трапы остаются DUT-only (устройства не смоделированы в 2B).
* **Легаси IMEM wait-states ломают исполнение** (trap-луп; native-репро) —
  баг `scr1_memory_tb_ahb`, НЕ ядра: этап-B эксперимент реактивного
  memory-агента (`MEM_AGENT=1 AGENT_IMEM_STALL=1/3` → PASS).
  Stall-покрытие imem/both
  и EC5 (load access) закрыты агентом; легаси-путь по-прежнему ограничен
  `DMEM_PATTERN=0`.
