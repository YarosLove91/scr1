# SCR1 UVM env vs ibex dv/uvm — структурные отличия

Карта соответствий и СОЗНАТЕЛЬНЫХ отклонений нашего окружения от эталона
`ibex/dv/uvm/core_ibex` (локально: `/home/m.yaroslove/Work/ibex/dv/uvm`).
Актуально для ветки `feat/uvm-agents-common` (2026-11-22). Донорские
паттерны, взятые 1:1, помечены **[1:1]**; адаптации с обоснованием —
**[АДАПТАЦИЯ]**; решения без аналога у ibex — **[НАШЕ]**; не перенесённое
из ibex — **[НЕ ПРИНЯТО]**.

Второй донор (не ibex): ALU-лаба `uvm_lab_ALU_16bit` — оттуда
`scr1_start_reset` (слой начальной инициализации), vseq/Sunburst-паттерн,
report server. Здесь не разбирается.

---

## 1. Раскладка каталогов

| ibex | SCR1 | Статус |
|---|---|---|
| `core_ibex/common/` — агенты-соседи `env/` | `tb/common/` — все агенты + общая commit-шина | **[1:1]** идея раскладки |
| `common/ibex_mem_intf_agent/` (интерфейс внутри) | `tb/common/mem_agent/` (+ `scr1_ahb_mem_if.sv`, `scr1_mem_model{,_pkg}.sv`, протокольный скорборд) | **[1:1]** «интерфейс и чекеры живут с агентом» |
| `common/irq_agent/` (irq_if.sv внутри) | `tb/common/irq_agent/` (+ `scr1_irq_if.sv` внутри — как у ibex) | **[1:1]** |
| `common/ibex_cosim_agent/` (DPI co-located) | `tb/common/cosim_agent/` (+ `spike_cosim_dpi.{cc,svh}` co-located) | **[1:1]** co-location DPI |
| (нет аналога) | `tb/common/csr_agent/` — пассивный CSR-чекер | **[НАШЕ]** §4.4 |
| (нет единого «core agent») | `tb/common/core_agent/` — агент запуска программ | **[НАШЕ]** §4.1 |
| `core_ibex/env/` (env + core_ibex_scoreboard) | `tb/env/environment/` (env + run-verdict скорборд + vseq'и) | **[1:1]** по роли |
| `core_ibex/tests/` (test_lib, base_test, vseq-библиотеки) | `tb/tests/` + `tb/env/sequence/` | **[АДАПТАЦИЯ]** vseq'и в env, не в tests |
| `dv/cosim/` — библиотека Cosim/SpikeCosim + cosim_dpi | (нет) — DPI-обёртка тонкая, сравнение в SV | **[НЕ ПРИНЯТО]** §4.5 |

## 2. Сводная таблица подсистем

| Подсистема | ibex | SCR1 | Статус |
|---|---|---|---|
| Retire-наблюдение | RVFI-шина + `rvfi_monitor` в cosim-агенте | bound `scr1_commit_probe` → `scr1_commit_if` (общая, tb/common/) → мониторы cosim (все ретаи) и csr (CSR-события) | **[1:1]** паттерн; шина общая для двух чекеров — поэтому в нейтральном корне |
| Instr-fetch наблюдение | `ifetch_monitor` + `ifetch_pmp_monitor` | нет | **[НЕ ПРИНЯТО]**: IMEM-ошибки у нас — инжекция mem-агента (`AGENT_IMEM_ERROR_ADDR`) + trap-сравнение; PMP нет в SCR1 |
| Память-агент | request/response — ДВА агента + seq_lib | ОДИН плоский реактивный агент (донор — ibex response agent): per-clock FSM драйвер отвечает автономно, секвенсер — только side-channel инжекции (err/delay) | **[АДАПТАЦИЯ]**: AHB-slave без request-стороны; one-driver-per-clock критичен для Verilator |
| IRQ-агент | `irq_agent` (if/item/monitor/driver/agent) | `scr1_irq_agent` — тот же состав | **[1:1]** состав; внутренности драйвера и рандомизация — **[АДАПТАЦИЯ]** §4.3 |
| CSR-проверки | внутри `core_ibex_scoreboard`/cosim (Spike сравнивает CSR сам) + тесты riscv-dv | отдельный `scr1_csr_agent`: golden-движок (независимый декод, WARL-легилайзеры, RAL-mirror predict, trap/MRET-ресинк, exit-снапшот) | **[НАШЕ]**: у ibex нет CSR-чекера поверх RVFI; у нас — 1638 live-проверок на csr_walk1 независимо от косима |
| Cosim | `ibex_cosim_agent` (cfg+мониторы+scoreboard, сравнение в C++) | `scr1_cosim_agent` (cfg+монитор+scoreboard, сравнение в SV) | **[1:1]** форма; **[АДАПТАЦИЯ]** механика §4.5 |
| RAL | (нет CSR RAL-модели) | `scr1_csr_ral_pkg` (донор — rv_csr_uvm_ral_unloader, не ibex) | **[НАШЕ]** |
| Покрытие | bound fcov-модуль (fcov_bind) | `scr1_fcov_if` + `scr1_bind` (донор — ibex fcov_bind) | **[1:1]** |
| Вердикт | UVM_ERROR-счётчик + test_done + «Co-simulation matched N» | строка-контракт `SCR1_RESULT: PASS|FAIL (counters...)` в final/base_test | **[НАШЕ]** |
| Генерация стимула | riscv-dv + constrained-random (`randomize()`) | riscv-dv (dv/fuzz) + детерминированный LCG для IRQ | **[АДАПТАЦИЯ]** §6 |

## 3. Загрузка вектора (аналог `load_binary_to_dut_mem`)

| ibex | SCR1 |
|---|---|
| ТЕСТ (`core_ibex_base_test.run_phase`): fetch_enable off → `load_binary_to_mems()` (zero-time) → on | ДРАЙВЕР (`scr1_driver.drive_run`): публикация пути в `scr1_cfg_pkg::g_load_path` + пульс `load_req` под сбросом → harness (`scr1_dut.sv`) вызывает `g_mem_model.load_verilog_hex()` → `load_done` |
| `mem.write(addr, byte)` — байтовый пуш из теста в класс памяти | `scr1_mem_model.load_verilog_hex(path)` — `$readmemh`-точный парсер в модели (clear() перед загрузкой — чистый reload для NUM_RUNS>1) |
| `env.cosim_agent.load_binary_to_mem()` — байтовый backdoor в память Spike через DPI (`riscv_cosim_write_mem_byte`) | Spike грузит тот же hex САМ через `scr1_spike_init(cfg.hex_path)` (DPI-init) — **[АДАПТАЦИЯ]**: файловый путь вместо byte-push API |
| `handle_reset`: каждый сброс → flush fifo → `env.reset()` (реинит косима) → reload | NUM_RUNS>1: каждый прогон = новый load-handshake драйвера + `clear()`+reload; RAL-mirror сбрасывает CSR-движок (`RUN_RESET`) |
| Строка пути — аргумент метода | Строка не пересекает vif-границу в Verilator → транспорт через пакетный глобал `g_load_path` (тот же паттерн, что `g_mem_model`) — **[АДАПТАЦИЯ]** |

Следствие файлового косим-лоада: нельзя загрузить в Spike образ, отличный
от DUT (ibex этим пользуется для debug-модуля: `bin_main`+`bin_dm` в разные
базы). Кандидат на будущее при появлении multi-image сценариев.

## 4. Агенты — детальные отличия

### 4.1 core_agent [НАШЕ]
У ibex нет «агента запуска программ»: стимул-оркестрация живёт в base_test
(load/fetch_enable/wait_for_test_done), шина — у mem request-агента. У нас
вся жизненная циклика прогона — в одном агенте: драйвер (load/reset/
watchdog/peek-poke/счётчик циклов) + монитор (arm по сбросу, exit по
`curr_pc==EXIT_PC`, `a0`-вердикт, захват консоли из dmem-тапов).
Дублирование: захват консоли монитором и консольное устройство mem-модели
наблюдают одни store'ы — сознательно (монитор кормит `tr.console`/вердикт и
остаётся единственным путём в legacy MEM_AGENT=0).

### 4.2 mem_agent [АДАПТАЦИЯ]
Один плоский реактивный агент вместо ibex-пары request/response: драйвер —
per-clock FSM, отвечающий на шину автономно (без seq_item на каждый
трансфер); секвенсер — только side-channel для инжекционных сиквенс
(`scr1_mem_err_seq`/`scr1_mem_delay_seq`). Протокольный скорборд живёт в
агенте и создаётся им (ibex-прецедент — cosim-агент; у mem-агента ibex
скорборда нет — проверки в core_ibex_scoreboard).

### 4.3 irq_agent [1:1 состав / АДАПТАЦИЯ внутренности]
Состав ibex-овский: if + seq_item (rand-поля + констрейнт
`num_of_interrupt == $countones(...)`) + sequencer-typedef + driver +
monitor (collect-on-change) + agent. Отличия:
- **Пины**: у ibex линии выделенные; у SCR1 программа сама триггерит/гасит
  IRQ записями в device-регистры (isr_sample) → в `scr1_irq_if` добавлено
  dev-зеркало и combinational OR в пины ядра (один continuous assign —
  MULTIDRIVEN исключён). Аналога у ibex нет.
- **Драйвер**: ibex — `try_next_item → clone → drive(cb) → item_done(rsp)` +
  isolation-fork/`handle_reset` с дренажом seq_item_port; у нас — house-
  структура mem-драйвера: per-clock registered re-drive level-состояния +
  zero-time side-channel `get_next_item→apply→item_done()` (без rsp).
  Причина: уровень нужно ДЕРЖАТЬ между item'ами и ре-драйвить каждый такт —
  cycle-exact с прежним OR-слиянием (baseline 474/401547 бит-в-бит).
- **Clocking**: ibex `default output negedge`; у нас `output #0`
  (registered, house-стиль `scr1_ahb_mem_if`) — требование cycle-exact.
- **Рандомизация**: ibex — solver/`randomize()`; у нас — детерминированный
  LCG-планировщик (ловушка seeded-`$urandom` в Verilator + требование
  бит-в-бит воспроизводимости); констрейнт в item декларативный.
- **Конфиг**: отдельный пакет `scr1_irq_cfg_pkg` (дефолты + bounds +
  дренаж-модель SOFT_GUAR); у ibex — knobs теста/plusargs.
- **Reset-обвес**: ibex isolation-fork + дренаж; у нас очистка состояния в
  per-clock step + молчаливая ресинхронизация монитора (режим «сброс между
  прогонами», mid-run сбросов нет).

### 4.4 csr_agent [НАШЕ — аналога у ibex нет]
Пассивный checker-агент (форма ibex_cosim_agent: monitor+scoreboard, без
driver/sequencer): собственный монитор commit-шины с ФИЛЬТРОМ по
CSR-событиям (trap / MRET / csr_r|w_req — ровно множество, потребляемое
движком), скорборд — golden-движок milestone 3/7 (независимый декод
инструкции, WARL-легилайзеры SCR1, класс-карта адресов ассоциативным
массивом, RAL-mirror predict, trap/MRET-ресинк, exit-снапшот vs live-built
mirror). RAL забирает из config_db сам. Run-end поток — через agent-level
`run_export` (ibex dmem/imem-паттерн). У ibex CSR-корректность проверяется
только сквозным сравнением со Spike; наш чекер ловит класс «write дошёл до
mux, но не до flop» независимо от косима.

### 4.5 cosim_agent [1:1 форма / АДАПТАЦИЯ механика]
Форма ibex-овская: cfg-объект (uvm_object, field-макросы) → монитор →
scoreboard ВНУТРИ агента → агент; DPI co-located. Отличия:

| ibex | SCR1 | Почему |
|---|---|---|
| cfg строит ТЕСТ из knob'ов, config_db scope `"*cosim_agent*"` | cfg строит ENV из плюсаргов (`+SPIKE_HEX` > `+REF_CSV`), тот же config_db-поток | у нас один поток конфигурации — plusargs из Makefile |
| `uvm_tlm_analysis_fifo` ×5 + run_phase-таски (`fifo.get()`) | `uvm_analysis_imp_decl(_commit)/(_run)` + синхронные `write_commit/on_run_end` | fifo вносит delta-cycle и меняет тайминг-семантику проверок; imp_decl на текущем стеке работает (старая ловушка не воспроизвелась) |
| Сравнение В C++ (`riscv_cosim_step`→bool, ошибки копятся в библиотеке, `get_error`) | Сравнение в SV: pull-lockstep (забираем golden запись из ref-бэкенда на каждый DUT-commit), first-mismatch локализация | движок верифицирован бит-в-бит; перенос в C++ — отдельная большая задача |
| `chandle cosim_handle`, инстанс-API | singleton-DPI | один hart, один процесс на симуляцию |
| `notify_dside_access` на каждую dmem-транзакцию (синхронизация памяти Spike с шиной, включая инжекции и uninit-reads) | нет: Spike исполняет store'ы сам, MMIO отсеивается масками сравнения | расхождений нет (970/970, 9418/9418); кандидат при появлении рандомных mem-ответов |
| `ifetch/pmp` мониторы + `iside_error_queue` + prune-логика | нет | fetch-ошибки — инжекция mem-агента + trap-сравнение |
| `agent.reset()`: flush fifo + `reset_e` → `handle_reset` → полный реинит Spike | per-run: драйвер перезагружает hex, `ref_spike` реинициализируется потоком загрузки | другая схема мультирана (драйвер-центричная) |
| `load_binary_to_mem` (byte-push API на агенте) | hex-файл через `scr1_spike_init` | см. §3 |
| `final_phase`: «matched N instructions» + release; `pre_abort()`: cleanup при UVM_EXIT | `final_phase` ref_spike → `scr1_spike_fini`; SUMMARY-строки скорборда; pre_abort нет | кандидат |
| — | **2A CSV-replay бэкенд** (`scr1_ref_csv`) за тем же `scr1_ref_model`-интерфейсом | **[НАШЕ]**: офлайн-реплей логов Spike без линковки |

## 5. Интерфейсы и clocking

- House-стиль clocking: `default input #1step output #0` (registered drive)
  во всех интерфейсах — вместо ibex `default output negedge`. Причина:
  cycle-exact воспроизводимость волн/счётчиков между конфигурациями.
- `scr1_commit_if` — общая шина двух чекер-агентов → нейтральный корень
  `tb/common/` (у ibex rvfi_if принадлежит sole-потребителю).
- Интерфейсы агентов живут в каталогах своих агентов **[1:1 с ibex]**:
  `scr1_if` → `core_agent/`, `scr1_ahb_mem_if` → `mem_agent/`,
  `scr1_irq_if` → `irq_agent/`. Единственное исключение — общая
  `scr1_commit_if` в нейтральном корне `tb/common/` (два агента-
  потребителя: cosim и csr; у ibex rvfi_if принадлежит sole-потребителю).
- Интерфейсы — только read/write через clocking; MULTIDRIVEN запрещён
  дисциплиной «один процедурный драйвер на сигнал» (OR — continuous assign).

## 6. Рандомизация и детерминизм

- ibex: constrained-random через solver (`randomize()`), riscv-dv для
  программ. У нас: riscv-dv (dv/fuzz pygen) для программ; TB-стимул (IRQ,
  mem-задержки, инжекции) — детерминированные LCG/plusarg-схемы.
  Причина: ловушка seeded-`$urandom` в Verilator + контракт «один seed =
  один бит-в-бит лог» (на нём стоят все baseline-сверки).
- `rand`-поля и констрейнты в item'ах присутствуют (ibex-форма), но
  декларативно; solver-путь не обкатан.

## 7. Verilator-специфика (причина большинства отклонений)

| Ограничение/ловушка | Следствие в дизайне |
|---|---|
| string/handle не пересекают vif-границу | пакетные глобалы-транспортёры (`g_load_path`, `g_mem_model`) |
| `uvm_analysis_imp_decl` — считался сломанным | исторически plain-subscriber forwarder'ы; с 2026-11-22 imp_decl ПРОВЕРЕН работающим (csr/cosim агенты), forwarder'ы устранены |
| `uvm_tlm_analysis_fifo` — delta-cycle сдвиг | синхронные function-call входы вместо fifo |
| seeded `$urandom` ненадёжен | детерминированный LCG |
| MULTIDRIVEN = fatal | единственный процедурный драйвер на сигнал; OR-слияния — continuous assign |
| `//`-комментарий, начинающийся со слова «Verilator» | парсится как lint-прагма → BADVLTPRAGMA fatal (не начинать строки комментария с этого слова) |
| 2-state моделирование | X-проверки заменены `===`-сравнениями и явными legalizer'ами |

## 8. Не принято из ibex (осознанно) — кандидаты на будущее

1. C++-сторона сравнения (Cosim-класс с накоплением ошибок, step→bool) —
   перенос SV-движка diff в DPI.
2. chandle-инстанс API косима (нужен при multi-hart).
3. `notify_dside_access`-синхронизация памяти Spike с шиной (нужна при
   рандомных mem-ответах/инжекциях данных).
4. `pre_abort()`-cleanup косима при UVM_EXIT.
5. Test-level backdoor API `load_binary_to_mem` на cosim-агенте (нужен для
   multi-image сценариев, debug-модуль).
6. ifetch-поток (при появлении PMP/icache-подобных проверок).
7. `agent.reset()` с flush+реинитом (при появлении mid-run сбросов).

---

Файл сопровождает `README.md` (архитектура и команды — там; здесь только
дельта относительно эталона). Обновлять при каждом структурном шаге
(агентские рефакторинги, переносы, новые заимствования из ibex).
