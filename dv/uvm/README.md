# UVM verification environment for the SCR1 core (Verilator)

Окружение UVM для ядра SCR1 на связке **Verilator 5.x + uvm-verilator**
(Accellera UVM 1800.2 2020.3.2, форк chipsalliance). Структура и стилистика —
по образцу `uvm_lab_ALU_16bit`; организация `dv/uvm` — по образцу ibex.

## Milestone 1 (готов): передача тестового вектора через sequence в DUT

```
sequence (scr1_run_prog_seq: путь к .hex)
   -> sequencer -> driver  ($fopen pre-check + string-путь + load_req через scr1_if)
   -> harness scr1_dut     (stage A loader: zeroing 1MB + $readmemh(string) в
                            i_memory_tb.memory, load_done handshake)
   -> driver               (readback-верификация: peek32(0x200) != 0)
   -> DUT: scr1_top_ahb + scr1_memory_tb_ahb (boot 0x200, консоль 0xF0000000)
   -> monitor              (консоль MMIO 0xF0000000 + exit PC 0xF8 + a0)
   -> scoreboard           (a0==0 -> PASS; счётчики вердикта)
```

### Загрузчик векторов (stage A)

Паттерн-донор — riscv-core-dv-uvm (загрузка всего вектора одним вызовом).
Протокол одного прогона (`scr1_driver.drive_run`):

1. **pre-check**: `$fopen(prog_path)` — нечитаемый путь даёт мгновенный
   `uvm_fatal .VECOPEN` (вместо тихого провала и trap-лупа до timeout);
2. **load handshake**: драйвер публикует полный SV `string`-путь в
   `scr1_cfg_pkg::g_load_path` (Verilator не умеет селект string-члена
   через virtual interface — см. «Ловушки») и поднимает `load_req`;
   harness ОБНУЛЯЕТ весь массив `i_memory_tb.memory` (1 МБ) и только
   затем `$readmemh(g_load_path, ...)` — `$readmemh` перезаписывает лишь
   адреса из файла, без zeroing'а предыдущий вектор оставил бы грязь
   (критично для `NUM_RUNS>1`); по завершении — однотактовый `load_done`;
3. **readback-верификация**: backdoor `peek32(0x200)` должен быть != 0 —
   ловит silent-zero провал `$readmemh` (исторический инцидент: путь
   длиннее 32 символов молча обрезался, память оставалась нулевой,
   ядро уходило в illegal-instruction trap-луп до timeout);
4. **reset/run**: `RST_CYCLES` тактов низкого rst_n, освобождение — ядро
   стартует с 0x200; ожидание exit PC 0xF8 или watchdog — без изменений.

Ограничение длины пути снято: `TEST_HEX` любой длины (проверено
77-символьным абсолютным), `dv/fuzz` больше не копирует hex в короткое
имя. Нативный `test_file/test_file_init`-механизм memory tb в UVM-потоке
не используется (файлы DUT не тронуты).

**Backdoor peek/poke** (`scr1_driver.peek32/poke32`): 32-битные
little-endian слова поверх байтового массива памяти через handshake
`peek_req/peek_done/peek_data` и `poke_req` (запись без done-линии).
Основа для верификации загрузки и будущих in-place патчей вектора
(data-pages, инжекция ошибок). XMR в `i_memory_tb.memory` разрешён
только в `tb/scr1_dut.sv` (установленная политика harness'а).

Тесты стартуют сценарии через **виртуальные сиквенсы** (Sunburst-паттерн из
лабы): `scr1_run_prog_vseq` на `env.v_sqr` → внутри реальная
`scr1_run_prog_seq` на `p_sequencer.sqr`. Точка роста для координации
будущих агентов (IRQ-инжекции во время прогона, RAL frontdoor csrrw,
мультипрограммные серии).

Все конкретные тесты наследуются от **`scr1_start_reset`** — абстрактного
слоя начальной инициализации (паттерн `alu_start_reset` из ALU-лабы), а не
напрямую от `scr1_base_test`. Его `run_phase` вставляет `do_reset()` перед
`body_seq()`: пока сброс взведён (`rst_n_req` активен низким с момента 0 —
initial-блок `scr1_if`; снимается драйвером в каждом прогоне), слой
выдерживает окно `RST_CYCLES` (сэмплирование через `mon_cb`), проверяет,
что сброс действительно взведён, очищает устройства модели памяти
(консоль/IRQ-регистры — то же состояние, которое драйвер восстанавливает
на каждом run-сбросе; драйвер IRQ-агента сам гасит свои линии стимула на
сбросе; no-op при MEM_AGENT=0 — null-handle)
и даёт шине успокоиться. Слой НЕ драйвит `rst_n_req` (драйвер остаётся
единственным источником интерфейсных сигналов — правило этапа B);
watchdog `TIMEOUT_CYCLES` считается драйвером от снятия его сброса, поэтому
инициализационные циклы в его бюджет не входят, а счётчики «completed in N
cycles» не меняются.

Один запуск симулятора = один прогон вектора; вердикт — строка
`SCR1_RESULT: PASS|FAIL` (парсится Makefile).

## Быстрый старт

```sh
cd scr1/dv/uvm
make uvm_download                       # клонировать uvm-verilator (один раз)
export CROSS_PREFIX=<toolchain>/bin/riscv-none-elf-
make smoke                              # собрать hello.hex и запустить scr1_smoke_test
make run TEST=scr1_smoke_test SW_TEST=isr_sample   # другой вектор
make run TEST_HEX=/path/to/custom.hex   # готовый вектор без пересборки sw
make run SW_TEST=hello AGENT_IMEM_STALL=3 AGENT_DMEM_STALL=3  # wait states (агент — дефолт)
make run MEM_AGENT=0 SW_TEST=hello      # легаси scr1_memory_tb_ahb (bit-exact контроль)
make waves                              # прогон с VCD (logs/waves.vcd)
```

Ключи конфигурации (см. `tb/scr1_cfg_pkg.sv`, передаются как
`+define+SCR1_CFG_*`): `RST_CYCLES`, `TIMEOUT_CYCLES`, `NUM_RUNS`, `SCB_LOG`.

## Структура

```
dv/uvm/
├── Makefile                  # uvm_download / hex / build / run / waves
├── DESIGN_VS_IBEX.md         # структурные отличия от эталона ibex dv/uvm:
│                             #   карта соответствий, адаптации и их причины
├── dut -> ../../src          # СИМЛИНК на дерево RTL: копий DUT нет, правки
│                             #   разработчиков ядра попадают в окружение напрямую
├── tb/
│   ├── scr1_cfg_pkg.sv       # геометрия DUT, константы и ручки конфигурации,
│   │                         #   representation-типы (typedef sweep, см. ниже)
│   ├── scr1_irq_cfg_pkg.sv   # конфигурация IRQ-стимула: дефолты vseq
│   │                         #   (+IRQ_* переопределяют) и границы
│   │                         #   random-сценариев (bounds, SOFT_GUAR)
│   ├── scr1_tb_pkg.sv        # vif-typedef, счётчики вердиктов, глобал
│   │                         #   g_mem_model (модель — импортом из
│   │                         #   scr1_mem_model_pkg; компилируется ДО RTL)
│   ├── scr1_dut.sv           # harness DUT (единственный файл с `include RTL-
│   │                         #   заголовков через dut/; наружу — чистые порты
│   │                         #   32 бит; реэкспортирует выходы bound-проб)
│   ├── scr1_bind.sv          # bind проб в DUT (ibex fcov_bind-паттерн):
│   │                         #   commit_probe/fcov_if/state_probe → scr1_top_ahb
│   ├── scr1_commit_probe.sv  # RVFI-lite commit-канал (bound, milestone 2)
│   ├── scr1_state_probe.sv   # CSR-снапшот RAL + legacy-тапы (bound)
│   ├── scr1_fcov_if.sv       # функциональное покрытие (bound, ibex fcov)
│   ├── scr1_tb_top.sv        # clk, интерфейс, экземпляр scr1_dut, run_test()
│   ├── common/               # ВСЕ АГЕНТЫ И ИХ ИНТЕРФЕЙСЫ — отдельный
│   │   │                     #   каталог-сосед env/ (раскладка ibex
│   │   │                     #   core_ibex/common: интерфейс живёт
│   │   │                     #   со своим агентом)
│   │   ├── scr1_commit_if.sv # общая commit-шина (RVFI-lite, аналог ibex
│   │   │                     #   rvfi_if): сэмплируется мониторами cosim
│   │   │                     #   (все ретаи) и csr (CSR-события); нейтральный
│   │   │                     #   корень common/ — два агента-потребителя
│   │   ├── core_agent/       # core-агент (запуск программ: load/reset/
│   │   │                     #   peek/poke/watchdog + run/консоль/exit):
│   │   │                     #   scr1_{agent_pkg,agent,sequencer,driver,
│   │   │                     #   monitor}.sv + scr1_if.sv (stimuli, run-статус,
│   │   │                     #   консольные AHB-тапы, csr_snap)
│   │   ├── mem_agent/        # реактивный AHB memory-агент (этап B):
│   │   │                     #   scr1_mem_{agent_pkg,agent,driver,monitor,txn,
│   │   │                     #   scoreboard}.sv + scr1_ahb_mem_if.sv +
│   │   │                     #   scr1_mem_model{,_pkg}.sv (модель физически
│   │   │                     #   здесь; компилируется в СОБСТВЕННОМ пакете ДО RTL
│   │   │                     #   и доходит до потребителей цепочкой импортов:
│   │   │                     #   mem_model_pkg → tb_pkg (g_mem_model) →
│   │   │                     #   harness/агенты/тесты); протокольный
│   │   │                     #   скорборд живёт с агентом И создаётся им —
│   │   │                     #   паттерн cosim_agent)
│   │   ├── irq_agent/        # IRQ-агент (ibex irq_agent-паттерн): scr1_irq_
│   │   │                     #   {agent_pkg,agent,driver,monitor,seq_item,
│   │   │                     #    base_seq,single_seq,random_seq}.sv +
│   │   │                     #   scr1_irq_if.sv (ibex irq_if: линии стимула +
│   │   │                     #   device-зеркало + OR в пины ядра)
│   │   ├── csr_agent/        # CSR-агент-чекер (ibex cosim_agent-паттерн,
│   │   │                     #   пассивный — без driver/sequencer): scr1_csr_
│   │   │                     #   {agent_pkg,agent,monitor,scoreboard}.sv
│   │   │                     #   (движок M3/M7 CSR;
│   │   │                     #   СОБСТВЕННЫЙ монитор commit-канала — ibex
│   │   │                     #   rvfi_monitor-паттерн; RAL из config_db)
│   │   └── cosim_agent/      # агент опорной модели (ibex ibex_cosim_agent):
│   │                         #   scr1_cosim_{agent_pkg,agent,cfg,monitor,
│   │                         #   scoreboard}.sv (СОБСТВЕННЫЙ монитор commit-шины —
│   │                         #   rvfi_monitor-паттерн; TLM-входы скорборда через
│   │                         #   `uvm_analysis_imp_decl(_commit)/(_run)`) +
│   │                         #   scr1_ref_{model,spike}.sv (бэкенды 2A CSV / 2B
│   │                         #   Spike) + spike_cosim_dpi.{cc,svh} — DPI-библиотека
│   │                         #   CO-LOCATED с агентом (ibex-паттерн)
│   ├── env/
│   │   ├── sequence/         # scr1_{seq_pkg,transaction,commit_tr,base_seq,run_prog_seq}.sv
│   │   └── environment/      # scr1_{env_pkg,env,scoreboard,
│   │                         #   report_server,vsequencer,
│   │                         #   base_vseq,run_prog_vseq,irq_run_vseq,
│   │                         #   seq_inject_vseq,seq_delay_vseq}.sv
│   └── tests/                # scr1_{test_pkg,base_test,start_reset,
│                             #   smoke_test,csr_test,irq_test,seq_*_test}.sv
├── sw/                       # сборка векторов из ../../sim/tests (sw/build/)
└── uvm-verilator/            # UVM-библиотека (gitignored, make uvm_download)
```

Политика DUT: окружение НЕ хранит копий файлов ядра — RTL, заголовки и
`scr1_memory_tb_ahb.sv` подключаются через симлинк `dut -> ../../src`
(file-листы `dut/core.files`, `dut/ahb_top.files`, `+incdir+dut/includes`).
Изменение DUT инженерами-разработчиками автоматически меняет сборку окружения;
единственная ручная точка синхронизации — разводка портов в `tb/scr1_dut.sv`
(при рассинхроне портов сборка падает с ошибкой elaboration).

Компиляционные единицы в порядке зависимостей: `uvm_pkg -> scr1_cfg_pkg ->
scr1_irq_cfg_pkg -> интерфейсы (common/core_agent/scr1_if ->
common/mem_agent/scr1_ahb_mem_if -> common/irq_agent/scr1_irq_if ->
common/scr1_commit_if) -> common/mem_agent/scr1_mem_model_pkg
(собственный пакет модели памяти+устройств) -> scr1_tb_pkg
(импортирует mem_model_pkg и объявляет глобал g_mem_model: harness
зовёт методы модели через него, поэтому оба ДО RTL) -> RTL ->
scr1_commit_probe -> scr1_state_probe -> scr1_dut -> scr1_fcov_if ->
scr1_bind (bind-директивы, после определений проб и RTL) -> scr1_csr_ral_pkg
-> scr1_seq_pkg -> scr1_agent_pkg -> scr1_mem_agent_pkg ->
scr1_irq_agent_pkg -> scr1_csr_agent_pkg (imp_decl(_csr) -> scoreboard
-> monitor -> агент; зависит от ral_pkg/seq_pkg/tb_pkg —
компируется после них) -> scr1_cosim_agent_pkg (imp_decl(_commit)/(_run)
-> cfg -> DPI-импорты ->
ref-бэкенды -> monitor -> scoreboard -> агент; DPI-импорты живут в пакете агента,
env_pkg видит их через wildcard import) -> scr1_env_pkg ->
scr1_test_pkg -> scr1_tb_top`; классы подключаются `` `include `` в свои
пакеты (как в лабе-образце). Правило окружения: **`` `include `` RTL-заго-
ловков — только внутри harness** (`scr1_dut.sv`); bind-файл проб
include-свободен (нужные кодировки зеркалятся в `scr1_cfg_pkg`), остальные
файлы UVM-среды (интерфейс, классы, топ) включают только `import`.

## Привязка проб (bind, паттерн ibex core_ibex_fcov_bind)

Наблюдательные модули НЕ разводятся XMR-цепочками из harness'а, а
**биндятся** внутрь DUT (`tb/scr1_bind.sv`, паттерн ibex
`dv/uvm/core_ibex/fcov/core_ibex_fcov_bind.sv`):

```
bind scr1_top_ahb scr1_commit_probe i_commit_probe (...);  // RVFI-lite коммиты
bind scr1_top_ahb scr1_fcov_if      i_fcov         (...);  // fcov (автономен)
bind scr1_top_ahb scr1_state_probe  i_state_probe  (...);  // CSR-снапшот + тапы
```

* **Цель bind — `scr1_top_ahb`, не `scr1_pipe_top`**: stall-бины fcov
  определены на уровне AHB-шины (`htrans != IDLE && !hready`), а порты AHB
  видны только на топе; `scr1_top_ahb` — наименьшая область видимости,
  откуда доступны И шины, И вся иерархия ядра (аналог у ibex — `ibex_core`,
  который так же «видит всё» для своего fcov).
* Все тапы (issue/retire/MPRF writeback/CSR trap/LSU/pipe_csr-регистры/
  mprf_int[10]) подключаются в bind-файле короткими путями от области
  `scr1_top_ahb` (`i_core_top.i_pipe_top.*`); harness `scr1_dut.sv` только
  РЕЭКСПОРТИРУЕТ выходы bound-экземпляров (`i_top.i_commit_probe.*`,
  `i_top.i_state_probe.*`) — XMR-цепочек в иерархию ядра в harness'е больше
  нет (единственное исключение — backdoor легаси-памяти
  `i_memory_tb.memory`, сохранён по политике stage A).
* `scr1_fcov_if` полностью автономен внутри DUT: питается выходами
  bound commit-пробы и живыми шинами, covergroups сэмплируют внутри
  интерфейса, `coverage.dat` пишется на `$finish` — на UVM-стороне для
  fcov нет ни проводов, ни портов (6 fcov-портов harness'а и инстанс
  fcov_if в tb_top удалены).
* Bind-файл include-свободен (политика окружения): кодировки, нужные
  тапам, зеркалятся в `scr1_cfg_pkg` — `HTRANS_IDLE` (AHB), `MEM_CMD_WR`
  (type_scr1_mem_cmd_e), `MEPC_PAD` (1 с RVC / 2 без — выведен из C-бита
  MISA; параметр `scr1_commit_probe`, заменивший `ifdef SCR1_RVC_EXT`
  в harness'е).
* Проверено (Verilator 5.053): bind внутри НЕинстанцированного
  модуля-обёртки (`module scr1_bind;` — как у ibex) применяется;
  bound-экземпляр может читать выходы другого bound-экземпляра той же
  цели (`i_fcov` ← `i_commit_probe.*`); struct-выход (`snap_o`) проходит
  через границу bind; регрессия cycle-exact (hello 16990 / isr_sample 457
  / a5_1 17184) и COV-бины идентичны pre-bind базовым.

## Соглашения DUT

* a0 (x10) == 0 на exit PC `0xF8` — тест PASS (конвенция нативного tb SCR1);
* консоль — один символ на store по адресу `0xF0000000`;
* вектор — `objcopy -O verilog` hex, грузится harness'ом: zeroing всего
  массива + `$readmemh(string)` по handshake `load_req/load_done` пока
  rst_n LOW (legacy-путь `test_file/test_file_init` memory tb не используется);
* путь вектора — SV `string` без ограничения длины (`scr1_cfg_pkg::
  g_load_path`): Verilator не поддерживает string-члены интерфейса при
  доступе через virtual interface, поэтому транспорт — глобал пакета,
  который harness читает в момент загрузки;
* сборка вектора наследует флаги нативного потока: `ARCH/ABI/TCM/IPIC/
  VECT_IRQ` по CFG (MAX/BASE → imc/ic, TCM=1, IPIC=1, VECT_IRQ=1) —
  isr_sample без `-DIPIC_ENABLED -DVECT_IRQ_ENABLED` не проходит (ext IRQ
  не принимается: линия IPIC не настроена);
* `RTC_HALF=5` (default) — темп rtc_clk как в нативном потоке (там `#500`
  выбрасывался Verilator без --timing); таймер по умолчанию всё равно
  считается от clk (`timer_clksrc_rtc=0` после сброса), ручка нужна для
  тестов с CLKSRC=rtc.

## Проверено (milestone 1, хост Verilator 5.053 + uvm-verilator 2020.3.2)

| Вектор | Циклы (UVM / native) | Результат |
|---|---|---|
| hello | 16990 / 16985 | PASS, console "Hello from SCR1!" |
| a5_1 | 17184 / 17179 | PASS, keystream идентичен native |
| isr_sample | 457 / 452 | PASS, 3 IRQ (timer/ext-IPIC/soft), a0=0 |

## Ловушки Verilator+UVM (найдено при отладке)

* `rand string` в uvm_sequence_item — Verilator 5.053 генерирует
  `VL_RANDOM_RNG_N`, которого нет в runtime → не объявлять string-поля
  как rand (поле `prog_path` задаётся последовательностью напрямую);
* комментарий, НАЧИНАЮЩИЙСЯ со слова "verilator" (любой регистр) —
  мета-комментарий → `%Error-BADVLTPRAGMA`;
* `string`-член интерфейса + virtual interface — `%Error-UNSUPPORTED:
  virtual interface trigger on 'string'`: string-данные между классами и
  модулями передаются через глобал пакета (`scr1_cfg_pkg::g_load_path`)
  или DPI, не через vif;
* `$readmemh` при ошибке (неверный путь, обрезанное имя) молча оставляет
  память нулевой → illegal instruction @0x200 → trap-луп до timeout —
  закрыто pre-check'ом `$fopen` (`.VECOPEN`) и readback-верификацией
  `peek32(0x200) != 0` (`.VECEMPTY`) в драйвере;
* `$readmemh(<packed vector>)` (legacy нативного tb): конвертация
  вектор→имя файла идёт от старшего ненулевого байта (строка
  right-justified, как после `$fgets` + `>> 8`); UVM-поток вместо этого
  использует string-путь без ограничения длины;
* **initial-блок интерфейса vs clocking-drive** (этап B): сигнал,
  записанный `initial` и позже драйвимый clocking-блоком, перестаёт
  обновляться (multidriven-слияние, подавленное `-Wno-MULTIDRIVEN`) —
  у сигнала должен быть РОВНО ОДИН источник; детали в «Milestone 5».

## Cosim-агент (готов): опорная модель в упаковке ibex ibex_cosim_agent

Вся опорная модель milestone 2 (2A/2B) живёт в ОДНОМ агентском каталоге
`tb/common/cosim_agent/` по образцу `ibex/dv/uvm/core_ibex/common/
ibex_cosim_agent` — cfg → scoreboard → agent, DPI-библиотека CO-LOCATED
с агентом:

```
scr1_env (build_phase)
   |  scr1_cosim_cfg (uvm_object, field-макросы; ibex core_ibex_cosim_cfg):
   |    mode spike|csv|none из +SPIKE_HEX/+REF_CSV (SPIKE_HEX побеждает),
   |    hex_path/csv_path + isa/start_pc/mtvec_reset/mstatus_reset
   |    (дефолты — константы scr1_cfg_pkg: SPIKE_ISA/RST_VECTOR/
   |     MTVEC_RST_VAL/MSTATUS_RST_VAL)
   |  uvm_config_db::set("cosim_cfg") -> create cosim_agt
   v
scr1_cosim_agent (PASSIVE: драйвера/секвенсера нет — Spike ничего не
   |              драйвит, UVM_ACTIVE не используется; ibex-агент тоже
   |              monitor+scoreboard)
   |  cosim_agt.mon — САМ сэмплирует commit-шину (ibex rvfi_monitor-
   |     паттерн) --> scb.commit_imp        (фаза A: lockstep)
   |  run_export <- agt.mon.ap --> scb.run_imp (фаза B: exit CSR snapshot)
   |     |  TLM-входы скорборда: `uvm_analysis_imp_decl(_commit)/(_run)`
   |     |  (проверено на Verilator 5.053 — forwarder-компонентов нет)
   v     v
scr1_cosim_scoreboard (uvm_scoreboard ВНУТРИ агента; ibex
   |   ibex_cosim_scoreboard) — движок milestone 2: фаза A per-commit
   |   lockstep + фаза B on_run_end exit-кросс-чек; get-ит cfg из
   |   config_db и строит ref-бэкенд (ibex init_cosim)
   v
scr1_ref_model (единый pull-интерфейс get_next/remaining/supports_*)
   ├── scr1_ref_spike (2B, +SPIKE_HEX) --DPI--> spike_cosim_dpi.cc/.svh
   └── scr1_ref_csv   (2A, +REF_CSV)  <- tools/spike_log2csv.py
```

Маппинг ibex → SCR1 и осознанные отличия:

| ibex | SCR1 | Комментарий |
|---|---|---|
| `core_ibex_cosim_cfg` (uvm_object, field-макросы) | `scr1_cosim_cfg` | 1:1 по роли; поля — SCR1-специфика (hex/CSV-путь, калибровка reset-состояния Spike) |
| `ibex_rvfi_monitor` + `ibex_rvfi_seq_item` (собственный сэмплер RVFI-шины) | `scr1_cosim_monitor` (собственный сэмплер commit-шины — RVFI-аналог `scr1_commit_probe` → выделенный `scr1_commit_if.mon_cb` в `tb/common/`) | 1:1 (rvfi_monitor-паттерн): read-only #1step-сэмплирование, публикация КАЖДОГО ретая без фильтра (фаза A сравнивает каждую инструкцию) |
| `ibex_ifetch_monitor`/`ifetch_pmp_monitor` | НЕТ | у SCR1 нет ifetch-потока для cosim (IMEM-ошибки — забота mem-агента) |
| `ibex_cosim_scoreboard` (uvm_scoreboard внутри агента, tlm-fifo + run_phase-таски) | `scr1_cosim_scoreboard` (uvm_scoreboard внутри агента) | движок сохранён как был: синхронные функции (write_commit/on_run_end) через TLM-входы `uvm_analysis_imp_decl(_commit)/(_run)` вместо tlm-fifo/тасков — pull-lockstep с first-mismatch локализацией, поведение бит-в-бит прежнее |
| `uvm_analysis_imp_decl`-порты (dmem/imem/rvfi в одном scoreboard) | `uvm_analysis_imp_decl(_commit)/(_run)` | 1:1 — старая ловушка «imp_decl сломан под uvm-verilator» НЕ воспроизвелась на Verilator 5.053 + текущем uvm-verilator |
| `spike_cosim_dpi.cc/.svh` в каталоге агента, `chandle cosim_handle` | `spike_cosim_dpi.cc/.svh` в каталоге агента; singleton-DPI (без chandle) | CO-LOCATION 1:1; API остался singleton-ом (один hart, один процессор на симуляцию) — механика SPIKE_HOME(.so+rpath)/SPIKE_ROOT(.a) не менялась |
| только in-process Spike | второй ref-бэкенд `scr1_ref_csv` (2A) за тем же `scr1_ref_model`-интерфейсом | у ibex офлайн-реплея нет; CSV-путь сохранён (триаж без cosim-сборки), отличие задокументировано в 2A-секции |
| cfg создаёт тест (`core_ibex_base_test`) | cfg создаёт `scr1_env` | в house-иерархии тесты не знают про косим; env — единая точка plusarg-конфигурации |

Агент инертен при `mode=none` (ref_m==null): дифференциальные проверки
выключены ровно как раньше при непустом `ref_m==null` в env; SCR1_RESULT-
счётчики (`g_diff_*`/`g_csr_diff_*` в `scr1_tb_pkg`) и формат вердикта не
изменились. Остальные scoreboard'ы env (scb и агентские csr_agt.scb /
mem_agt.scb) не затрагиваются.

## Milestone 2A (готов): дифференциальная сверка со Spike (офлайн-реплей)

```
sequence (.hex) -> driver -> DUT
                              |  commit-шина (RVFI-lite, scr1_commit_probe)
                              v
                 cosim_agt.mon (собственный монитор, rvfi-паттерн)
                        --ap--> scb.commit_imp
                                              |
                                   scr1_cosim_scoreboard <-- ref_m (pull)
                                              ^
                                   scr1_ref_csv (cfg.csv_path <- +REF_CSV=<csv>)
                                              ^
                     tools/spike_log2csv.py | Spike --log-commits
```

* `scr1_commit_probe` (env-файл, тапы копируют проверенную инстанцию
  `scr1_trace_logger`): один commit на retire — pc/instr (byte-accurate FIFO
  {pc,instr} из потока IDU), rd writeback (exu2mprf), trap (mepc/mcause,
  instr=0xFFFFFFFF), LSU-транзакция load/store (FIFO глубины 4, pop по retire).
* `scr1_cosim_scoreboard` (в `tb/common/cosim_agent/`, до агент-рефакторинга —
  env-уровневый `scr1_diff_scoreboard`) — lockstep pull-сверка (первое
  расхождение = точка триажа, логика редуктора): pc/instr/rd_addr/rd_data; фильтры (skipped):
  DUT IRQ trap-коммиты и — в 2A — все DUT trap-коммиты (в CSV нет
  trap-записей; в 2B precise-exceptions сверяются 1:1, см. «Trap-выравнивание»
  в разделе 2B), rd-value у чтений таймерных CSR (mcycle/minstret/... —
  timing by nature) и у load из MMIO (0xF0000000/0x00490000 —
  device-dependent), пост-exit спин на 0xF8.
* `scr1_ref_csv` — golden-поток из CSV: `tools/spike_log2csv.py` гоняет Spike
  (`--no-dm --disable-dtb --pc=0x200 -m0x0:0x10000,0x480000:0x10000,
  0x490000:0x1000,0xf0000000:0x1000 -l --log-commits`, флаги из
  docker/scr1-spike/compare_state.py; `--no-dm` авто-детект) и пишет
  `pc,instr,wr,rd,val` до первого PC=0xF8. ОТЛИЧИЕ ОТ IBEX: у ibex-агента
  офлайн-бэкенда нет (только in-process Spike); CSV-реплей сохранён как
  ВТОРОЙ ref-бэкенд за тем же интерфейсом `scr1_ref_model` (триаж без
  cosim-сборки/линковки libriscv): `supports_traps()=0` (в CSV нет
  trap-записей — трапы скипаются) и `supports_csr_read()=0` (нет живого
  CSR-состояния — exit-кросс-чек фазы B пропускается). Путь CSV передаётся
  через cfg-объект агента (`cfg.csv_path`), не собственным plusarg-чтением.
* Spike-бинарь: `make spike_extract` извлекает проверенный (октябрьский
  master, с `--no-dm`) из docker-образа `scr1-spike-verif` в `tools/bin/`
  (gitignored). Хостовый `riscv-isa-sim`@сен не годится: DM без опции
  отключения занимает [0,0x1000) и перекрывает RAM@0.

Запуск:

```sh
make run REF=1 SW_TEST=hello CROSS_PREFIX=<...>   # CSV строится автоматически
```

### Результаты 2A (хост Verilator 5.053, Spike из scr1-spike-verif)

| Вектор | Golden commits | Matched | Mismatches | Вердикт |
|---|---|---|---|---|
| hello | 9412 | 9412 | 0 | PASS |
| a5_1 | 11291 | 11291 | 0 | PASS |

`isr_sample` под 2A не сверяется (IRQ-устройства spike не моделируются:
IPIC-custom CSR, timer как RAM) — зона IRQ agent + device-моделей (2B+).

## Milestone 2B (готов): Spike in-process через DPI-C (lockstep)

```
DUT commit → cosim_agt.mon (rvfi-паттерн) → scb.commit_imp → scr1_cosim_scoreboard
                                                        --get_next()--> scr1_ref_spike
                                                                            | DPI-C
                                            tb/common/cosim_agent/spike_cosim_dpi.cc
                                             processor_t (libriscv .so/.a)
                                            + плоская память-модель
```

* `tb/common/cosim_agent/spike_cosim_dpi.cc` (CO-LOCATED с агентом — ibex-
  паттерн; DPI-импорты в `spike_cosim_dpi.svh` там же, подключаются в
  `scr1_cosim_agent_pkg`): `scr1_spike_init(hex, isa, start_pc, mtvec_reset,
  mstatus_reset)` — verilog-hex
  грузится в байтовые области RAM 0x0:64K / TCM 0x480000:64K / TIMER
  0x490000:4K / SIM 0xF0000000:4K (таймер и консоль — plain RAM, устройства
  не моделируются); `scr1_spike_step(...)` — один шаг = один golden-коммит
  (pc, raw instr из памяти, GPR writeback из `log_reg_write`, trap по записи
  mcause). simif_t реализован поверх областей (addr_to_mem/mmio_load/store).
* Ловушка версии: `enable_log_commits()` в свежем spike ПЕЧАТАЕТ каждый коммит
  в log_file процессора — с nullptr это segfault в `fprintf`; принтер
  запаркован на `/dev/null`, record-мапы (log_reg_write/log_mem_*) независимы.
* Линковка — ДВА режима (комментарий в Makefile; машинно-специфичных
  дефолтов нет, при обоих заданных SPIKE_HOME побеждает):
  - `SPIKE_HOME=<install prefix>` — **shared-библиотеки .so (предпочтительный)**:
    `include/` + `lib/libriscv.so` (тот же префикс, что использует линия
    C++-тестбенчей snippy: `sim/tb_cpp_ahb/makefile.build_tb`). Линковка
    `-L$(SPIKE_HOME)/lib -Wl,-rpath,$(SPIKE_HOME)/lib -lriscv -lfesvr
    -ldisasm -lsoftfloat` — rpath снимает прежний «load error» .so
    (ловушка про `-lriscv` без rpath ниже остаётся в силе). `libriscv.so`
    дополнительно тянет хостовый `libboost_regex` (его DT_NEEDED).
    Verilator кладёт пользовательский `-LDFLAGS` в LDLIBS (после
    объектов) — порядок `-l`-цепочки корректен, `--as-needed` не выбросит.
  - `SPIKE_ROOT=<дерево riscv-isa-sim>` — legacy-статика: только `.a`
    полными путями внутри `--start-group` (`-lriscv` поднял бы
    `libriscv.so` из дерева → падение при загрузке без rpath).
* **Trap-выравнивание (2B)**: шаг Spike, записавший `mcause` И `mepc`
  одновременно (take_trap), — trap-entry; `get_next()` возвращает для него
  golden TRAP-запись (trap=1, mcause, pc=mepc, instr=маркер FFFFFFFF —
  конвенция DUT trap-коммита), и scoreboard сверяет trap-коммиты
  precise-exception (ecall/ebreak/illegal/...) 1:1 по mepc+mcause
  (instr не сверяется: маркер против реальной инструкции). Детектор по
  ПАРЕ mcause+mepc отличает trap-entry от программных `csrw mcause`/
  `csrw mepc` (один шаг = одна инструкция = один записанный CSR — критично
  для CSR-фаззинга). IRQ-трапы DUT (mcause[31]=1) остаются skip: в модели
  2B нет IRQ-устройств, golden их не порождает. Exit-спин на 0xF8
  сравнивается живо (обе стороны крутят тот же `j .`).
* **CSR-diff (2B, замыкание остатка milestone 7)**: кросс-модельное сравнение
  DUT-поток vs Spike-поток в двух фазах (дополняет, НЕ дублирует golden-
  проверки scr1_csr_scoreboard):
  - **Фаза A (per-commit)**: `scr1_spike_step` получил выходы golden
    CSR-write события НЕтраповых шагов (`csr_w_valid/csr_w_addr/csr_w_value`
    из `log_reg_write` type-4; значение — ИТОГ записи, у DUT `csr_w_data` —
    ОПЕРАНД, поэтому значения здесь не сверяются). На trap-шагах событие не
    эмитируется (траповые записи mepc/mcause/mstatus покрыты trap-
    выравниванием и M7-ресинком); MRET-шаги подавляются (Spike логирует
    аппаратный mstatus(+mstatush), у DUT mret не несёт exu2csr_w_req —
     аппаратный путь минует CSR-шину). `scr1_ref_spike.get_next()` кладёт
     событие в golden commit_s, cosim-scoreboard на каждой не-траповой паре
     сверяет НАЛИЧИЕ записи (dut.csr_w_req == ref.csr_w_req) и АДРЕС;
    расхождение — `UVM_ERROR .CSR_DIFF` + `g_csr_diff_mismatches`.
  - **Фаза B (run-exit)**: новая DPI `scr1_spike_get_csr(addr, val)` (peek-
    чтение живого состояния Spike; `processor_t::get_csr` бросает на
    невалидных адресах — обёрнута try/catch) + virtual-пара
     `scr1_ref_model.supports_csr_read()/get_csr_value()` (CSV-модель — 0,
     exit-сверка молча пропускается). Поток run-транзакций приходит в агент
     через `cosim_agt.run_export` (env-подписка `agt.mon.ap`) прямо в
     `scb.run_imp` (`uvm_analysis_imp_decl(_run)` → `write_run` →
     `on_run_end`; до imp_decl-рефакторинга — forwarder
     `scr1_cosim_run_sub`, ещё раньше — env-уровневый
     `scr1_csr_exit_sub`) и вызывает
     `scb.on_run_end(tr)`: снапшот DUT сверяется со Spike по INCLUDE-списку
    с масками легальных расхождений: mstatus 0x1888 (MIE/MPIE/MPP; S/U-биты
    Spike не сравниваются, MPP совпадает — Spike M-only легализует MPP=11
    как SCR1), mie 0x888, mtvec 0xFFFFFFC1 (BASE[31:6]: SCR1 64B-
    гранулярность vs Spike 4B; + bit0 MODE; bit1 игнорируется — у SCR1 MODE
    1-битный), mepc ~((1<<MEPC_PAD)-1) (bit0 маскирован RVC у обоих),
    mcause 0x8000_000F (бит i + ec[3:0] — SCR1 хранит ec в 4-битном
    type_scr1_exc_code_e, легальный WARL-срез, находка e46329b), mscratch —
    полное. Расхождение — `UVM_ERROR .CSR_EXIT_DIFF` + `g_csr_diff_mismatches`.
  - ИСКЛЮЧЕНЫ из exit-списка: счётчики B00/B02/B80/B82 (free-running
    timing), mip 0x344 (у DUT device-линии, у Spike устройств нет),
    mcounten 0x7E0 (кастомный SCR1 CSR — Spike не знает, get_csr бросит),
    misa 0x301 и F11-F14 (константы моделей различаются; против SCR1-правды
    их проверяет M3/M7 RAL), mtval 0x343 (trap-value-семантика моделей
    различается на части классов исключений; live-трекается M7).
   - КАЛИБРОВКА RESET-СОСТОЯНИЯ: `scr1_spike_init` получил параметры
     `mtvec_reset`/`mstatus_reset` (передаются из cfg-объекта агента, чьи
     дефолты — MTVEC_RST_VAL/MSTATUS_RST_VAL из scr1_cfg_pkg):
    mtvec и mstatus — implementation-defined reset (SCR1: mtvec=0x1C0,
    mstatus.MPIE=1 → 0x1880; Spike: mtvec=0, MPIE=0 → 0x1800). Первый же
    прогон hello вскрыл расхождение MPIE (0x1880 vs 0x1800) — легальный
    reset-дивергенс, устранён калибровкой golden-состояния (MPP=11 Spike
    легализует сам — M-only). Без калибровки exit-сверка давала бы ложные
    расхождения на программах, не пишущих эти CSR.
   - Счётчики: `g_csr_diff_checked` (сравненные CSR-события фазы A +
     сравненные значения фазы B) и `g_csr_diff_mismatches` — в
     SCR1_RESULT (`csr_diff=`/`csr_diff_mm=`) и в SUMMARY cosim-scoreboard
     (счётчики живут в `scr1_tb_pkg` — формат вердикта не менялся).

Запуск:

```sh
make run SPIKE_COSIM=1 SPIKE_HOME=<prefix> SW_TEST=hello CROSS_PREFIX=<...>
```

`+SPIKE_HEX` (cosim) имеет приоритет над `+REF_CSV` (2A) — приоритет
фиксирует `scr1_cosim_cfg.mode` в `scr1_env.build_phase`; оба режима дают
один и тот же pull-интерфейс `scr1_ref_model`, и при обоих отсутствующих
агент инертен (`mode=none`, дифференциальные проверки выключены).

### Результаты 2B (хост Verilator 5.053, libriscv.a из riscv-isa-sim@4ffd6ba8)

| Вектор | Режим | Commits | Matched | Mismatches | Вердикт |
|---|---|---|---|---|---|
| hello | 2B DPI lockstep | 9418 (9412 + 6 спин) | 9418 | 0 | PASS |
| a5_1 | 2B DPI lockstep | 11297 | 11297 | 0 | PASS |
| hello | 2A CSV replay | 9412 | 9412 | 0 | PASS |

Trap-выравнивание (2026-11-18): fuzz seed1 — **970/970 matched,
trap_checked=1** (финальный ecall mcause=0xB), 0 skip (было 969 + 1 skip);
seed7 — 831/831, trap_checked=1; `regress NUM_SEEDS=8` + SPIKE_COSIM=1 —
**8/8 PASS**, на каждом seed'е trap_checked=1 при 0 mismatches (249..1966
коммитов). НЕГАТИВ-КОНТРОЛЬ dec_fence.hex (RTL ветки НЕ патчен фиксом #81):
ожидаемый FAIL — traps compared 5, первый mismatch
`trap[dut=EXC(mcause=0x00000002) ref=NORMAL]` ровно на трапящей fence.tso
@0x0048030a (триаж указывает сам трап, а не 854-каскад). Контроль
mcycle.hex (не патчен для #80): сигнатура без дрейфа (126 mismatches/1636,
traps=0). 2A (CSV) сохраняет прежнее skip-поведение для всех трапов
(`supports_traps()=0`): hello 9412/9412 PASS, skipped=6 (exit-спин).

CSR-diff (2026-11-19, Verilator 5.053, CFG=MAX, xPack 15.2.0): hello
(cosim) **PASS 9418/9418**, csr_diff=6 (только exit-фаза — hello не пишет
CSR), 0 расхождений; fuzz seed1 **PASS 970/970 trap_checked=1** csr_diff=12;
`regress NUM_SEEDS=8 TEST=riscv_csr_rand_test` + SPIKE_COSIM=1 — **8/8 PASS**
(свежие seed'ы 228..1065 коммитов, trap_checked=1 на каждом, csr_diff=13..23
— CSR-инъекции mepc/mtval/mcause/mstatus реально нагружают фазу A), 0
CSR_DIFF/CSR_EXIT_DIFF. Контроли: 2A CSV hello **PASS 9412/9412** skipped=6
— exit-сверка пропущена инфо-сообщением «no CSR read API» (csr_diff=0);
non-cosim isr_sample **PASS 457** csr_live=14 csr_diff=0 (ref null — новый
код инертен). НАХОДКА калибровки: первый прогон hello вскрыл легальный
reset-дивергенс mstatus.MPIE (SCR1 0x1880 vs Spike 0x1800, см.
SCR1_CSR_MSTATUS_MPIE_RST_VAL) — закрыт калибровкой reset-состояния Spike
(mtvec/mstatus), маска mstatus 0x1888 сохранена полностью.

## Milestone 3 (готов): CSR RAL (uvm_reg-зеркало M-mode CSR)

```
harness XMR (агрегированные флопы pipe_csr, те же имена, что читает
проверенный STATE_DUMP) -> scr1_csr_snap_s -> scr1_if -> monitor
   (сэмпл на exit PC) -> scr1_transaction.csr -> scr1_csr_scoreboard:
      predict() в RAL-зеркало + shadow[addr] + check_ral_vs_shadow()
      + константы (mvendorid/marchid/mimpid/mhartid/misa)
      + инварианты (MPP==3, minstret>0, mcycle>=minstret)
```

* Модель (`tb/ral/`, стиль `rv_csr_uvm_ral_unloader/src/csr`, RV32/n_bits=32):
  `scr1_csr_top_block` = submap'ы **Sm** (mstatus 0x300 с полями MIE/MPIE/MPP,
  misa 0x301 RO per-CFG, mie 0x304, mtvec 0x305 MODE/BASE, mscratch 0x340,
  mepc 0x341, mcause 0x342 EC/IRQ, mtval 0x343, mip 0x344 RO volatile,
  mcounten 0x7E0 CY/IR, mvendorid/marchid/mimpid/mhartid F11-F14 RO) и
  **Cnt** (mcycle B00, minstret B02, mcycleh B80, minstreth B82 — volatile).
  Reset-константы — в `scr1_cfg_pkg` per-CFG (misa MAX 0x40001104 / BASE
  0x40000104 / MIN 0x40000014, mimpid 0x22011200, marchid 8, mtvec 0x1C0,
  mcounten 0x5).
* Env строит модель по образцу их `env.sv`: create → build → lock_model →
  reset → config_db set (`uvm_root`, `"*"`, `"reg_top_model"`); scoreboard
  (живёт в `scr1_csr_agent`, `csr_agt.scb`) забирает handle из config_db САМ
  в `build_phase` (паттерн «агент владеет своей моделью», как ibex cosim).
* Предсказание: **explicit predict снапшота** (аналог probe_scoreboard:
  predict + shadow + consistency check). Классического `uvm_reg_predictor`
  с адаптером нет: CSR-шины в UVM не существует (доступ к CSR — только
  инструкциями ядра); frontdoor-адаптер (csrrw-секвенции) и live-поток
  CSR-записей из pipe_csr — backlog.
* RAL-проверки сразу поймали баг harness'а: `csr_mcause_ec_ff` в pipe_csr
  шириной 31 бит — конкатенация `{i_ff, 25'b0, ec_ff}` давала 57 бит, IRQ-бит
  терялся при truncated assign, а ec[29] протекал в снапшот (0x20000003
  вместо 0x80000003 на isr_sample). Фикс: брать `ec_ff[5:0]` (как порт
  trace_logger). RAL vs shadow разошёлся ровно на этом — check сработал.

Запуск: `make run TEST=scr1_csr_test SW_TEST=<t>` (RAL-проверки активны
в ЛЮБОМ тесте — CSR-скорборд `csr_agt.scb` подписан на run-транзакции
через `csr_agt.run_export`).

### Результаты milestone 3

| Вектор | Комбинация | CSR snapshot | Вердикт |
|---|---|---|---|
| hello | RAL | 18 регистров, 0 расхождений | PASS |
| a5_1 | RAL + SPIKE_COSIM (2B) | 0 расхождений + 11297/11297 коммитов | PASS |
| isr_sample | RAL | 0 расхождений (реальные записи mtvec/mie/mscratch/mepc/mcause) | PASS |

## Milestone 4 (готов): функциональное покрытие (ibex fcov паттерн)

По образцу `ibex/dv/uvm/core_ibex/fcov/core_ibex_fcov_if.sv` (golden standard):
покрытие живёт в **RTL-стороне интерфейса** `tb/scr1_fcov_if.sv`, а не в UVM-
классах — Verilator 5.053 НЕ поддерживает covergroup внутри классов
(«Expecting a data type»), но полноценно поддерживает интерфейсные:
clocked `@(posedge clk)`, `with function sample`, `iff`, enum/диапазон/
массив bins, `cross`, `option.per_instance`; отчёт — `verilator_coverage
--annotate`.

Разделение как в ibex (ISA vs uarch):
* **uarch_cg** (цикловый): категория инструкции на retire (ibex
  InstrCategory-паттерн: ALU/MUL/DIV/Branch/Jump/Load/Store/LuiAuipc/CSR/
  ECall/EBreak/MRet/WFI/Fence/FenceI + RVC CAlu/CLdSt/CBranch/CJump/Other),
  per-instruction stall-тип (imem/dmem/both — sticky-флаги в commit_probe
  между ретаями), **cross категория×stall** (ibex-идея), живые stall шины,
  redirect, trap;
* **insn_cg** (per retire): major opcodes, RVC-квадранты, ALU/M funct3,
  branch funct3, load/store funct3, rd[0:31], rs1[0:31], **CSR-адреса**
  (18 SCR1 M-mode + счётчики), cross opcode×rd;
* **exc_cg** (per trap): mcause EC bins (0..8, 11), IRQ-бит, cross.

Источники сигналов: commit-шина (`scr1_commit_probe`) + живые AHB-stall
сигналы и redirect — ВСЁ через bind внутри DUT (`tb/scr1_bind.sv`): fcov_if
привязан к `scr1_top_ahb` и питается выходами bound commit-пробы (до
bind-рефакторинга fcov_if инстанцировался в tb_top отдельными проводами от
портов harness'а; сэмплинг всегда был RTL-side, как в ibex).

Запуск и отчёты:

```sh
make run COV=1 SW_TEST=isr_sample ...        # logs/<test>.<tag>.coverage.dat + annotate
cd ../fuzz && make fuzz SEED=7 COV=1 ...     # RUN_TAG=fuzz_<seed> автоматически
make cov_merge                               # ibex merge_cov-паттерн: все .dat -> merged + annotate
```

Stall-режимы (рантайм-плюсарги, пересборка не нужна): `IMEM_PATTERN=`/
`DMEM_PATTERN=` → `+imem_pattern/+dmem_pattern` (семантика memory tb:
`0` = random wait-states, `FFFFFFFF` = без задержек (дефолт), иначе бит[0]
ротационной маски). **ВНИМАНИЕ: любые IMEM wait-states ломают исполнение
(trap-луп) — reproduced и в native-потоке, см. docs/bug_story/BUG-003;
для stall-покрытия используйте DMEM_PATTERN=0.**

### Результаты 2026-11-15 (merged: hello/isr_sample base, directed vector,
isr_sample dmem-stall, fence seed 77, fuzz seeds 1/7)

**covergroup 52.7 % (325/617)**; закрыты сверх стартовых: EC bins 3/4/6/7/11
(breakpoint 12, misaligned ld/st 3/3, store_access 6, ecall_m 14),
fence 6 / fence_i 3, trap-категории ecall 8 / ebreak 6, live dmem/imem
stall-бины, x_cat_stall (dmem-колонки).

Недостижимые/заблокированные бины:
* `cp_retire_stall.imem_stall/both_stall` + imem-колонки кросса —
  **BUG-003 candidate** (IMEM wait-states → trap-луп, native-репро);
* EC 0 (INSTR_MISALIGN) — архитектурно недостижим с RVC: jal/jalr очищает
  bit0 цели по спеке, mepc[0] hardwired 0;
* EC 8 (ecall_u) — нет U-mode; EC 1/5 (fetch/load access) — memory tb не
  возвращает ERROR на чтение вне регионов (только на запись).

Направленный вектор `dv/fuzz/sw_directed/scr1_cov_directed.S`
(`make cov_directed`): fence/fence.i, ecall, ebreak, c.ebreak, misaligned
lw/sw (EC 4/6), unmapped sw (EC 7) + собственный trap-handler (mepc += 2/4,
байтовое чтение mepc — lhu на нечётном mepc стрепился бы снова). Гоняется
БЕЗ Spike-lockstep (Spike исполняет misaligned нативно → расхождение).

## Milestone 5 / Этап B (готов): реактивный AHB memory-агент (MEM_AGENT=1 — ДЕФОЛТ)

Легаси `scr1_memory_tb_ahb` (RTL-модуль из дерева DUT, вне UVM-контроля)
заменяется реактивным UVM-агентом по образцу `ibex_mem_intf_agent`
(ibex dv/uvm, response-agent-паттерн). Флаг сборки **`MEM_AGENT=1`** →
`+define+SCR1_MEM_AGENT` (compile-time, входит в CFG-штамп).

**С 2026-11-19 агент — ДЕФОЛТ** (dv/uvm и dv/fuzz) после накопления
parity-регрессий (hello/a5_1/isr_sample cycle-exact Δ=0, stall-матрица,
NUM_RUNS=2, агент-эксклюзивы irq_ext/fetch_fault) и валидационной
кампании переключения (включая первый fuzz-lockstep на агенте).
Легаси-путь сохраняется бит-в-бит явным **`MEM_AGENT=0`** (контроль
расхождений; единственная известная легаси-девиация агента: unmapped
dmem → ERROR вместо wrap — см. cov_directed 156→200). DUT-файлы не
тронуты; нативный flow не затронут (он всегда на легаси memory tb).

```
                       +------------------ scr1_mem_agent (env) --------------+
scr1_dut (harness)     |  scr1_mem_driver        scr1_mem_monitor             |
  i_top <== AHB imem/dmem ==> (реактивный FSM      ==> ap (scr1_mem_txn:       |
   ^   ^                   |  через drv_cb,          канал/addr/wr/size/       |
   |   +-- irq_lines/soft_irq <--+ без sequencer)     wdata/rdata/resp)        |
   |                       |        |                    задел store-потока   |
   |  load/peek/poke       |        v                    DRVFuzz              |
   +-- handshake (без изменений) -> scr1_tb_pkg::g_mem_model <-+---------------+
                                    (scr1_mem_model: 1MB + устройства)
```

### Состав

* **`tb/common/mem_agent/scr1_mem_model.sv`** (физически с агентом;
  компилируется в собственном `scr1_mem_model_pkg` и доходит до
  потребителей ЦЕПОЧКОЙ ИМПОРТОВ: `mem_model_pkg → scr1_tb_pkg`
  (глобал `g_mem_model`) `→ scr1_dut/mem_agent_pkg/test_pkg`;
  компиляция ДО RTL, т.к. harness потребляет модель через
  `g_mem_model`) — память +
  устройства: байтовый массив 1 МБ (индексы заворачиваются как в легаси),
  `load_verilog_hex(string)` — парсер с ТОЧНОЙ `$readmemh`-семантикой наших
  векторов (байт-токены 2 hex-цифра, `@addr` = байтовый адрес, `//`+`/* */`
  комментарии; clear() перед загрузкой — чистая перезагрузка для NUM_RUNS>1),
  `peek32/poke32` (LE-слова, backdoor), `read_word/write_word` с byte-enable
  (зеркало `scr1_read_mem/scr1_write_mem/scr1_be_form`), device-состояние:
  консоль (`$write("%c")` + счётчик), `irq_lines`/`soft_irq` (сброс в 0 при
  rst_n low — легаси-семантика). Транспорт к harness'у — пакетный глобал
  `scr1_tb_pkg::g_mem_model` (агент выставляет в build_phase; прецедент —
  `scr1_cfg_pkg::g_load_path`): ПРОТОКОЛ ДРАЙВЕРА НЕ ИЗМЕНИЛСЯ (load
  handshake / VECOPEN / VECEMPTY — те же).
* **`tb/common/mem_agent/scr1_ahb_mem_if.sv`** — интерфейс агента: ровно сигналы, которые
  потребляет легаси memory tb (imem: htrans/haddr/hsize → hready/hrdata/
  hresp; dmem: + hwrite/hwdata; hprot/hburst/hmastlock игнорируются как в
  легаси) + `irq_lines[31:0]`/`soft_irq` — ЗЕРКАЛА device-регистров
  (программный источник IRQ; с 2026-11-21 уходят не напрямую в ядро, а в
  `scr1_irq_if`, где OR-сливаются с линиями стимула IRQ-агента) + `rst_n`;
  clocking-блоки в стиле `scr1_if` (drv_cb/mon_cb, `#1step`).
* **`tb/common/mem_agent/`** — ОДИН плоский реактивный агент (ibex
  response-паттерн, request/response-пары НЕ размножались):
  * `scr1_mem_driver` (extends uvm_component) — **milestone-выбор: БЕЗ
    sequencer/seq_item-потока** — реактивный slave: FSM-зеркало легаси
    memory tb в режиме без задержек, каждый такт через drv_cb
    (registered-output семантика = always_ff+always_comb легаси):
    адресная фаза принимается при `hready=1 && htrans=NONSEQ`, data-фаза
    1 такт, pipelined-адреса (NONSEQ во время завершающейся data-фазы)
    принимаются в тот же такт (DATA→DATA легаси); асимметрия откликов
    легаси сохранена (imem hresp=OKAY всегда; dmem hresp=ERROR по
    умолчанию, OKAY/ERROR на такте завершения); commit записи data-фазы
    dmem выполняется ДО latch чтения того же такта (аналог w_hazard
    forwarding легаси store→fetch).
  * `scr1_mem_monitor` — analysis-порт `scr1_mem_txn` (одна транзакция на
    завершённый transfer, pipelining учтён) — задел store-потока DRVFuzz.
  * `scr1_mem_txn` — один seq_item (channel/addr/write/size/wdata/rdata/
    resp_err/rdelay), без иерархий.
* **harness `scr1_dut.sv`** под `ifdef SCR1_MEM_AGENT`: `i_memory_tb` НЕ
  инстанцируется; AHB-шины i_top уходят на порты harness'а (→ tb_top →
  интерфейс), `irq_lines/soft_irq` — входы от интерфейса (IPIC-геометрию
  harness поглощает внутри — порты фиксированной ширины); load/peek/poke
  вызывают методы `g_mem_model`. Без define — прежний путь (XMR
  `i_memory_tb.memory`).
* **`scr1_tb_top.sv`**: инстанцирует `scr1_ahb_mem_if`, `assign
  mem_vif.rst_n = vif.rst_n_req`, передаёт vif через config_db (`mem_vif`).
  **`scr1_env`** создаёт `mem_agt` (active). Порядок компиляции:
  `scr1_tb_pkg` перемещён ПЕРЕД RTL/harness (harness зовёт методы модели
  через пакетный глобал).
* **Makefile**: `MEM_AGENT ?= 1` (**ДЕФОЛТ с 2026-11-19**; `0` = легаси
  `scr1_memory_tb_ahb`, бит-в-бит; define + CFG-штамп). Рантайм-плюсарги
  (без пересборки): `AGENT_IMEM_STALL=<N>` / `AGENT_DMEM_STALL=<N>` —
  N тактов `hready=0` на транзакцию (0 = выкл = parity-тайминги);
  `AGENT_RANDOM_STALL=<max>` + `AGENT_STALL_SEED=<n>` (дефолт 1) +
  `AGENT_RANDOM_STALL_CH=imem|dmem|both` (дефолт both) — случайные
  wait-states 1..max на транзакцию от внутреннего xorshift32-PRNG
  (детерминированно от seed: одинаковый seed → идентичный счётчик циклов;
  на включённом канале отменяет детерминированный knob; 0 = выкл =
  прежнее поведение бит-в-бит);
  `AGENT_DMEM_ERROR_ADDR=<hex>` — инъекция `hresp=ERROR` по слову адреса
  (EC5/EC7-бины); `AGENT_IMEM_ERROR_ADDR=<hex>` — то же на fetch (EC1,
  пара — sim/tests/fetch_fault). `dv/fuzz` пробрасывает `MEM_AGENT`/`AGENT_*`.
* **Sequencer-инжекция** (feat/uvm-agent-evolve): у mem-агента есть
  секвенсер (`scr1_mem_sequencer`, `scr1_mem_err_seq.add_err(addr, count,
  is_imem)`, поле `err_count` в `scr1_mem_txn`).
  Драйвер форкает ДВА процесса: прежний per-clock FSM (не блокируется!) и
  side-channel `get_next_item` → карта {word-addr → count}, которую FSM
  потребляет неблокирующе через `take_injection()` на address-accept.
  `v_sqr.mem_sqr` открыт для vseq. Демо: `scr1_seq_inject_test` + вектор
  `dv/fuzz/sw_directed/scr1_seq_inject.S` (`make -C dv/fuzz seq_inject`)
  → PASS 90, 3× `mcause=7` — идентично plusarg-пути.
* **Sequencer rdelay-модуляция wait-states** (feat/uvm-agent-remain):
  зарезервированное поле `rdelay` задействовано — `scr1_mem_delay_seq.
  add_delay(lo, hi, dmin, dmax, ch, count)` вооружает ОКНА модуляции
  {байтовый диапазон [lo,hi], канал dmem|imem|both, min..max wait-states,
  count совпавших транзакций (0 = бессрочно)} через тот же неблокирующий
  side-channel (`delay_mod`-item'ы → очередь окон в драйвере; FSM читает её
  чистым lookup'ом при выборе `stall_tgt` на wcnt==0 — per-clock FSM не
  блокируется). **Приоритет**: совпавшее окно OVERRIDE'ит и
  `AGENT_RANDOM_STALL`, и детерминированный `AGENT_<CH>_STALL` на данной
  транзакции (первое вооружённое совпавшее окно выигрывает); несовпавшие
  транзакции сохраняют knob-поведение; нет окон — FSM бит-в-бит прежний
  (parity- fast-path). **Детерминизм**: draw в [min,max] — из СОБСТВЕННОГО
  xorshift32-потока драйвера (отдельное состояние, seed = `AGENT_STALL_SEED`;
  поток random-knob не возмущается); min==max — фиксированное значение из
  item'а без draw; идентичный стимул → идентичное число циклов. Окна НЕ
  чистятся на reset (TB-стимул, как injection-карты). **Побочный эффект
  gating'а**: пока на канале вооружено окно, его idle-циклы держат hready=0
  (ack-гейтинг паттерна легаси random-режима) — hready цикла X драйвится
  раньше, чем становится известен адрес мастера цикла X, поэтому КАЖДАЯ
  транзакция с idle-старта на этом канале стоит +1 цикл даже при draw=0;
  pipelined-адреса не модулируются (легаси DATA→DATA). Демо:
  `scr1_seq_delay_test`/`scr1_seq_delay_vseq` (hello + окно all-dmem 0..3,
  overrides: `+SEQ_DELAY_MIN/MAX/CH/LO/HI/COUNT`, контроль
  `+SEQ_DELAY_DISABLE=1`): PASS **21579** циклов (> 16990; 1801
  модулированная dmem-транзакция = +1801 gating + ~1.55 avg draw), повтор
  бит-в-бит идентичен (лог совпадает полностью кроме walltime-строк),
  mem-scoreboard violations=0; с `+SEQ_DELAY_DISABLE=1` тот же тест даёт
  ровно **16990** (harness-путь ничего не добавляет); parity/plusarg-пути
  не затронуты (hello 16990, random-stall 33166×2, seq_inject 90, irq_ext
  474).
* **Mem-scoreboard** (`scr1_mem_scoreboard` в `scr1_mem_agent_pkg` —
  протокольный чекер живёт вместе с агентом и СОЗДАЁТСЯ им:
  `mem_agt.scb`, подключение `mon.ap → scb.analysis_export` внутри
  `scr1_mem_agent.connect_phase`; иерархия в логах:
  `uvm_test_top.env_h.mem_agt.scb`):
  легитимность `hresp=ERROR` (ERROR законен iff WIN_UNMAPPED или адрес в
  per-run реестре инжекций модели `err_injected` — пишут и плюсарг, и
  sequencer), запрет транзакций в reset, warning на нестандартный hsize;
  счётчики total/imem/dmem/read/write/OKAY/ERROR(unmapped vs injected)/
  violations в SUMMARY. Data-integrity (wdata vs образ) сознательно не
  дублируется — это задел store-потока DRVFuzz (тот же ap-хук).

### Отклонения от легаси (осознанные)

1. **dmem вне известных окон** (RAM 1 МБ / 0xF0000000 / 0xF0000100 /
   0xF0000200) → `hresp=ERROR` (легаси заворачивал адрес в массив и
   отвечал OKAY; ERROR у легаси возникал только как артефакт stall-FSM).
   Следствие: EC5 (load access) впервые достижим; `cov_directed` идёт
   200 циклов вместо 156 (unmapped lw/sw теперь реально трапятся).
   На запись ERROR не коммитится. imem — всегда OKAY (чтение вне RAM
   заворачивается, как в легаси под 2-state).
2. **Wait-states вставляются в АДРЕСНУЮ фазу** (а не в data-фазу): мосты
   ядра опускают `htrans=IDLE` при `hready=0` в data-фазе, поэтому
   data-phase stall невидим fcov-бинам (`htrans!=IDLE && !hready`);
   легаси random-режим заполнял те же бины гейтингом IDLE-состояния.
   Pipelined-адреса не столлятся (как в легаси DATA-состоянии).
3. Чтение консоли (0xF0000000) возвращает 0 (легаси alias'ил его в
   обёрнутый RAM); тесты консоль не читают, cosim-scoreboard MMIO-чтения
   фильтрует.

### Parity и результаты (хост, Verilator 5.053 + uvm-verilator, CFG=MAX)

| Прогон | MEM_AGENT=0 (легаси) | MEM_AGENT=1 (агент) | Δ |
|---|---|---|---|
| hello | PASS 16990 | PASS 16990, console 17 chars | **0** |
| a5_1 | PASS 17184, keystream `10011101001010000001` | PASS 17184, keystream идентичен | **0** |
| isr_sample | PASS 457 (a0=0) | PASS 457 (a0=0, 3 IRQ через агента) | **0** |
| fuzz SEED=1 + SPIKE_COSIM=1 | — | PASS 969/969 matched, 0 mismatch | — |
| NUM_RUNS=2 hello | PASS 16990×2 | PASS 16990×2 (чистая перезагрузка модели) | 0 |
| cov_directed | PASS 156 | PASS 200 (EC5/EC7 через агента) | +44 (трапы) |

Stall-матрица агента (все PASS): hello IMEM=1 → 24233, IMEM=3 → 31479,
DMEM=1 → 20592, DMEM=3 → 24194, IMEM3+DMEM3 → 38683; a5_1 DMEM=3 →
18972 (keystream идентичен); isr_sample IMEM=3 → 535, DMEM=3 → 477.
**ГЛАВНЫЙ ВЫВОД (BUG-003): легитимные IMEM wait-states НЕ ломают ядро —
зависание легаси-паттернов есть баг `scr1_memory_tb_ahb` (при
`req_ack=0` imem-канал держит `hready=1` и выдаёт `hrdata='x` → в
2-state `0x00000000` → illegal → trap-луп); детали и команды —
`docs/bug_story/BUG-003-imem-waitstates.md`, секция «Эксперимент с
mem-агентом (этап B)».** COV-прогон (IMEM=3+DMEM=3, RUN_TAG=agent_stall)
+ `cov_merge`: merged **54.9% (339/617)** — впервые закрыты
`cp_retire_stall.imem_stall` (29) / `both_stall` (1784), imem/both-колонки
`x_cat_stall`, `exc_cg.load_access` EC5 (1); EC7 (9).

Инъекция ошибок: `AGENT_DMEM_ERROR_ADDR=f0000000` на hello → TRAP
`mcause=0x7` на первом console-store (механизм готов; для PASS-прогонов
нужен вектор с trap-handler — EC5/EC7 штатно закрывает cov_directed).

**IMEM error-инжекция (EC1, 2026-11-18)**: `AGENT_IMEM_ERROR_ADDR=<hex>` —
hresp ERROR на FETCH соответствующего слова; мост/IFU (scr1_imem_ahb →
`ifu2idu_imem_err_o`) превращают его в instruction access fault (mcause=1).
Парный вектор `sim/tests/fetch_fault` (требует MEM_AGENT=1): прыжок на
POISON_ADDR=0x3000, handler проверяет mcause РАВНО 1, переписывает mepc на
after_fault и делает mret; вердикт a0=0 только если EC1 реально случился.
БЕЗ инъекции тот же вектор FAIL (нули по 0x3000 = illegal instruction,
mcause=2 → a0=1) — встроенный негатив-контроль причины. Запуск:
`make run SW_TEST=fetch_fault MEM_AGENT=1 AGENT_IMEM_ERROR_ADDR=3000`.
Результаты: ON → PASS 65 циклов (csr_live=6, csr_mm=0); OFF → FAIL
failed=1; parity hello MEM_AGENT=1 16990 и irq_ext 474 без изменений
(драйвер правился); COV=1 → `exc_cg.cp_ec.fetch_access=1`. Все
access-fault EC-бины (1/5/7) закрыты.

### Ловушка этапа B (добавлена в общий список)

* **initial-блок в интерфейсе конфликтует с clocking-drive**: значения,
  записанные `initial` в сигналы, которые затем драйвит clocking-блок,
  НЕ обновляются (multidriven-слияние подавлено `-Wno-MULTIDRIVEN`;
  драйвер «видел» свои значения, DUT — начальные). Симптом: parity-режим
  работает случайно (драйв==initial), а любой отличающийся драйв (0 при
  stall) игнорируется. Правило: сигнал интерфейса — РОВНО ОДИН источник
   (clocking-драйвер ИЛИ assign/initial, не оба).

## Milestone 6 (готов): IRQ-агент — асинхронные ext/soft прерывания из UVM

До этого прерывания в среде мог поднимать только сам тестируемый код
(store'ом в device-окна `EXT_IRQ_ADDR`/`SOFT_IRQ_ADDR`, как `isr_sample`).
IRQ-агент добавляет **асинхронный TB-стимул**: тестбенч независимо от потока
программы поднимает линии ext/soft IRQ, проверяя латентность, векторный/прямой
режимы и сам путь обслуживания прерываний.

**С 2026-11-21 (ветка feat/uvm-irq-agent-ibex) агент выделен в ОТДЕЛЬНЫЙ
`scr1_irq_agent` в стиле ibex** (донор: `ibex/dv/uvm/core_ibex/common/
irq_agent`; второй донор стиля — `uvm_lab_ALU_16bit`): собственный интерфейс
`scr1_irq_if`, seq_item / sequencer / driver / monitor / agent в
`tb/common/irq_agent/` (пакет `scr1_irq_agent_pkg`) и реальные сиквенсы стимула
на `v_sqr.irq_sqr`. Прежний инжекционный слой mem-агента (`inj_ext`/`inj_soft`
в `scr1_mem_model` + OR-слияние в mem-драйвере) УПРАЗДНЁН.

```
 scr1_irq_test --body_seq--> scr1_irq_run_vseq (на v_sqr)
                                  |  fork
             +--------------------+---------------------+
             |                                          |
   scr1_run_prog_seq (на agt.sqr)          per-run цикл (rst_fall-выравнивание
             |                             на irq_vif; seed+run_index)
   scr1_driver: load/reset/run                          | start на v_sqr.irq_sqr
             |                          scr1_irq_single_seq | scr1_irq_random_seq
             |                                          | send_state (joint state)
             |                              scr1_irq_driver: ЕДИНСТВЕННЫЙ драйвер
             |                                линий стимула (per-clock registered
             |                                drive + zero-time side-channel)
             v                                          v
   DUT ядро <== sim_irq_lines / sim_soft_irq ==  scr1_irq_if:
             core_* = линии агента | device-зеркало (combinational OR)
                                                 ^
   mem-агент: device-регистры irq_lines/soft_irq (программные store'ы
   в EXT_IRQ_ADDR / SOFT_IRQ_ADDR; зеркалятся mem-драйвером каждый такт)
```

* **Разделение источников пинов (по анализу device-регистров)**: у SCR1 ДВА
  легальных источника interrupt-пинов: (а) TB-стимул агента — вектора
  irq_ext/irq_stress сами линии НЕ пишут, только ждут инъекцию и гасят
  pending через IPIC SOI/EOI (0xBF4/0xBF5); (б) device-регистры mem-модели,
  которые пишет САМА программа — `isr_sample` сам триггерит ext (store маски
  в `EXT_IRQ_ADDR` 0xF0000100) и soft (store 1 в `SOFT_IRQ_ADDR` 0xF0000200),
  а его handler'ы гасят pending записью в те же регистры. Семантика
  обслуживания IRQ программами СОХРАНЕНА: пины ядра = combinational OR обоих
  источников ВНУТРИ `scr1_irq_if` (`core_ext_lines = ext_lines |
  dev_ext_lines`, `core_soft_irq = soft_irq | dev_soft_irq`), при этом каждый
  сигнал имеет РОВНО ОДИН процедурный драйвер (линии стимула —
  `scr1_irq_driver` через driver_cb; device-зеркало — mem-драйвер через свой
  drv_cb), multidriven исключён, RTL и harness-порты не менялись (tb_top
  подаёт `core_*` на прежние 32-битные `sim_irq_lines`/`sim_soft_irq`,
  IPIC-геометрию поглощает harness).
* **Драйвер** (`scr1_irq_driver`): структура проверенного реактивного
  mem-драйвера — ДВА независимых процесса: (а) per-clock зарегистрированный
  драйв линий из level-состояния через driver_cb (`default input #1step
  output #0` — RTL-flop-семантика легаси OR-слияния) и (б) zero-time
  side-channel `get_next_item → apply → item_done` (никогда не блокирует
  тактовый контур). На сбросе состояние и линии обнуляются — стимул не
  протекает между прогонами NUM_RUNS (политика прежнего `reset_devices()`).
* **seq_item** (`scr1_irq_seq_item`, донор ibex `irq_seq_item`): rand-биты
  источников — ext-маска `ext_mask[IRQ_LINES_NUM-1:0]` + `soft_irq` — и
  ibex-констрейнт `num_of_interrupt == $countones({ext_mask, soft_irq})`;
  сценарные метаданные `delay`/`width` (циклы до взведения / ширина импульса).
  Один item несёт ПОЛНОЕ совместное состояние обоих каналов (level-семантика:
  держится до следующего item) — единственная replay-нить не может
  перезаписать соседний канал. Детерминизм стимула — НЕ через `randomize()`
  (seeding-ловушка Verilator), а через LCG-расписание сиквенсы; границы и
  дефолты — `scr1_irq_cfg_pkg` (единый дом конфигурации, +IRQ_* plusargs
  переопределяют в рантайме).
* **Монитор** (`scr1_irq_monitor`, донор ibex `irq_monitor`): один item на
  ИЗМЕНЕНИЕ пинов ядра (collect-on-change, не каждый такт), сэмплирование
  race-free через monitor_cb; пока сброс взведён — молчаливая ресинхронизация
  (никаких item'ов на run-границах NUM_RUNS). Analysis-порт `ap` — свободный
  хук для подписчиков (IRQ-покрытие сэмплируется от commit-потока в
  `scr1_fcov_if`, не от монитора).
* **Сиквенсы** (в `scr1_irq_agent_pkg`, паттерн `scr1_mem_err_seq`):
  `scr1_irq_base_seq` — сетка тактов `irq_vif.wait_clks` + `send_state` /
  raise/clear-хелперы; `scr1_irq_single_seq` — легаси одиночный ext+soft
  импульс (путь irq_ext, бит-в-бит); `scr1_irq_random_seq` — LCG-планировщик
  перенесён ДОСЛОВНО (rng_seed/rng_next/rng_range, single-pass
  `build_random_schedule`, mask_mode fixed9/random16/all16, guaranteed
  concurrent soft через `est_first_quiet()` + SOFT_GUAR_*); прежние ДВА
  replay-потока (ext/soft писали два поля модели) слиты в ОДНУ event-
  таймлину совместных состояний (границы импульсов, sort+dedup) — те же точки
  posedge-сетки, форма волны и длина прогонов идентичны, поток один →
  один sequencer.
* **vseq** (`scr1_irq_run_vseq`): координатор на v_sqr — форкает прогон
  программы (`scr1_run_prog_seq` на `agt.sqr`) и per-run цикл стимула
  (выравнивание на снятие сброса + `rst_fall_watch` на `irq_vif`, как раньше
  на mem_vif), стартуя сиквенсу сценария на `v_sqr.irq_sqr` (новый хендл
  `scr1_vsequencer`, wiring в `scr1_env`). random-режим пересеивается
  `seed+run_index`. Все +IRQ_* плюсарги `scr1_irq_test` сохранены без
  изменений.
* **Линия ext**: `scr1_cfg_pkg::EXT_IRQ_LINE` (9 для IPIC-сборок MAX/BASE —
  совпадает с `IPIC_IRQ_LINE9` в векторе; 0 для MIN без IPIC). `IPIC_EN`
  выведен в cfg_pkg из CFG-define (env-файлы не видят `SCR1_IPIC_EN` из
  RTL-заголовков — include-политика).
* **Вектор** `sim/tests/irq_ext/` (прямой+векторный режимы, ext+soft; БЕЗ
  таймера — machine timer IRQ генерирует встроенный RTL-таймер scr1_timer
  внутри scr1_top_ahb на внутреннем dmem-роутере (окно 0x0049_0000 НЕ
  выходит на внешний AHB, агент его не видит), он не агент-стимул и покрыт
  isr_sample): ставит handler, включает
  MEIE/MSIE+MIE, крутится в bounded-spin (SPIN_LIMIT) ожидая инъекцию;
  handler сохраняет a1/a5/t0 через mscratch (без kernel-стека), считает
  прерывания в s2/s3, делает IPIC SOI/EOI. Pass = оба счётчика ≥1 (a0=0);
  bounded-spin гарантирует завершение даже без инъекции. Раскладка
  (trap-таблица @0x1C0, `_start`@0x200) зеркалит `isr_sample`.
* Требуется **MEM_AGENT=1** (IRQ-агент и `scr1_irq_if` строятся под
  `SCR1_MEM_AGENT`; легаси MEM_AGENT=0 сохраняет нативное device-окно
  `scr1_memory_tb_ahb` бит-в-бит); Spike-lockstep для IRQ-прогонов ВЫКЛЮЧЕН
  (модель 2B не содержит IRQ-устройств, cosim-scoreboard остаётся выключенным,
  IRQ-трапы в нём и так скипаются).

### Результаты IRQ-агента (Verilator 5.053, CFG=MAX, xPack 15.2.0)

| Прогон | Результат |
|---|---|
| irq_ext, MEM_AGENT=1, инъекция ON | PASS, 474 цикла (done=1), a0=0 → оба IRQ обслужены; ext-линия 0x200 (бит 9) |
| irq_ext, MEM_AGENT=1, COV=1 | впервые закрыт `exc_cg.cp_irq.interrupt` (mcause[31]=1) + cross `x_irq_ec` interrupt×{ec=3 soft, ec=11 ext} |
| hello, MEM_AGENT=1 (инъекция OFF) | PASS 16990 — parity не изменилась (`X | 0 = X`) |

**Ре-верификация ibex-агента (2026-11-21, feat/uvm-irq-agent-ibex)** — всё
cycle-exact с прежним инжекционным слоем: irq_ext PASS 474 (csr_live=16,
таймстемпы стимула ns-в-ns совпали с контрольным прогоном нетронутого
981b148); irq_stress `IRQ_RANDOM=6 IRQ_SEED=1 IRQ_MASK_MODE=random16` PASS
401547 (csr_live=139), повтор IDENTICAL (full-log diff чист кроме строк
walltime); isr_sample PASS 457 (csr_live=14 — программный device-самотриггер
сохранён через OR в `scr1_irq_if`); hello 16990 / a5_1 17184+keystream /
csr_walk1 6963 live=1638 / fetch_fault 65 / seq_inject 90 (ERROR 3 injected,
violations 0) / seq_delay 21579 и DISABLE→16990; irq_ext NUM_RUNS=2:
runs_checked=2, оба прогона 474, csr_live=32 — идентично контрольному
прогону нетронутой базы (расхождение с записью «978/live=34» в handoff —
устаревшее число: на pristine 981b148 воспроизводится 474+474/live=32,
см. тело коммита f5591e6).

### IRQ-агент: случайные многоимпульсные сценарии (irq_stress)

Развитие IRQ-агента от одиночных ext+soft импульсов до случайных серий:
случайное число/интервалы/ширины ext-импульсов, случайные маски IPIC-линий,
включая ОДНОВРЕМЕННЫЕ ext+soft (арбитраж/приоритеты IPIC).

* **Вектор** `sim/tests/irq_stress/` (по образцу `irq_ext`: trap-таблица @0x1C0,
  `_start`@0x200, handler с mscratch-сейвом БЕЗ стека, bounded-spin, direct +
  vectored `#ifdef`): включает ВСЕ 16 IPIC-линий (цикл `IPIC_IDX=n`,
  `ICSR=IE|IM`, edge-mode) + MSIE + MIE, считает ext-трапы (`s2`) и soft-трапы
  (`s3`) в общем handler'е. Handler делает IPIC SOI/EOI: при нескольких
  одновременно взведённых линиях IPIC search-one отдаёт по SOI приоритетную
  (наименьший индекс), а после EOI следующая pending-линия перезапрашивает →
  k-битная маска даёт k последовательных ext-трапов. Вектор САМ не триггерит
  линии (никаких store в `TRIG_*_IRQ_ADDR`) — только ждёт инъекцию TB. Критерий
  PASS: `s2 ≥ 1 && s3 ≥ 1` (a0=0); точные количества — логом trap-счётчиков на
  UVM-стороне (`csr_live`, `exc_cg.cp_irq`). Полный спин (без раннего выхода)
  досчитывает все трапы серии; bounded `SPIN_LIMIT` гарантирует выход без hang.
* **Режим случайных сценариев** (`scr1_irq_random_seq`, стартует из
  `scr1_irq_run_vseq` на `v_sqr.irq_sqr`; opt-in): плюсарги
  `+IRQ_RANDOM=<n ext-импульсов>` `+IRQ_SEED=<n>` `+IRQ_MASK_MODE=<fixed9|
  random16|all16>`. `IRQ_RANDOM=0`/не задан → легаси-путь одиночных ext+soft
  СОХРАНЁН бит-в-бит (irq_ext 474 PASS). Сценарий: n случайных ext-импульсов
  (маски из включённых линий, случайные интервалы/ширины в циклах) + ≥2
  soft-импульса, из них один ПРИНУДИТЕЛЬНО перекрывает окно ext[0]
  (одновременные ext+soft в каждом прогоне). Каждый импульс логируется
  `uvm_info` (маска/цикл/ширина). Тайминг от `irq_vif.clk`, как в легаси.
* **Детерминизм**: расписание считается ОДНИМ однопоточным проходом
  (`build_random_schedule`) после единственного `rng_seed(+IRQ_SEED)`; replay
  только потребляет очереди (без ГСЧ): границы импульсов обеих очередей слиты
  в ОДНУ отсортированную event-таймлину совместных состояний (sort+dedup),
  которая реплеится одной нитью через единственный sequencer — те же точки
  posedge-сетки, что и прежние два потока. Используется собственный LCG
  (Numerical Recipes, mod 2**32), а НЕ `$urandom(seed)`: seeded-`$urandom` в
  Verilator не пересевает последующий поток `$urandom_range` (разные seed
  давали идентичное расписание). Одинаковый seed → идентичный лог стимулов;
  другой seed → другой лог. Ширины ограничены сверху (`*_W_MAX`), edge-mode
  ext не даёт level-шторма, soft-линия level-чувствительна но ширина мала →
  re-trap-шторм ограничен.
* **Concurrent-soft с гарантированным обслуживанием** (`+IRQ_SOFT_GUAR=<0|1>`,
  knob `IRQ_SOFT_GUAR`, дефолт **1** в random-режиме): короткий soft-пульс
  во время ext-шторма легитимно истекает необслуженным — MEI>MSI, soft-трап
  откладывается до дренажа ext-очередки (~15 циклов/трап), что дольше ширины
  пульса. С включённым `soft_guar` принудительный concurrent-пульс (старт —
  по-прежнему ВНУТРИ окна ext[0], перекрытие сохраняется) расширяется до
  ожидаемого первого «тихого» окна ext-дренажа + запас:
  `est_first_quiet()` — детерминированная модель дренажа по уже построенному
  ext-расписанию (`SOFT_GUAR_PER_LINE=24` цикла/линию ≈ измеренные ~15 + 60%,
  `SOFT_GUAR_MARGIN=100`), чистая арифметика БЕЗ дополнительных обращений к
  LCG (детерминизм и «один проход» сохранены). MSI остаётся взведённым, когда
   MEI-очередь иссякает → ≥1 soft-трап гарантирован; остаток ширины даёт
   ограниченный soft-re-trap-хвост (level-линия; handler'ский clear
   device-регистра не сбрасывает линию стимула агента — OR в `scr1_irq_if`).
   Свободные soft-пульсы
  планируются после гарантированного. `IRQ_SOFT_GUAR=0` воспроизводит
  прежнее расписание бит-в-бит. Результат (random16, IRQ_RANDOM=6, seeds
  1..5): 5/5 PASS, s3≥1 каждый раз (seed1 COV: `exc_cg.cp_ec.breakpoint`
  (ec=3=soft) = **38** soft-трапов против 1 без гарантии; ext-трапы не
  изменились — `ecall_m`(ec=11)=28), длина прогона выросла лишь на ~1.3k
  циклов (401547 против 400216).
* **Запуск** (плюсарги runtime, rebuild не нужен; knob'ы проброшены в Makefile):

  ```
  make run TEST=scr1_irq_test SW_TEST=irq_stress \
       IRQ_RANDOM=6 IRQ_SEED=1 IRQ_MASK_MODE=random16 CROSS_PREFIX=<...>
  ```

### IRQ-агент: NUM_RUNS>1 — стимул повторяется для каждого прогона

`NUM_RUNS` (compile-time knob: `+define+SCR1_CFG_NUM_RUNS` через
`CFG_DEFINES`, входит в штамп сборки — смена значения пересобирает бинарник)
заставляет драйвер делать load+reset+run для КАЖДОГО прогона; ресет виден на
`irq_vif.rst_n`. `scr1_irq_run_vseq` для каждого прогона заново стартует
сиквенсу сценария на `v_sqr.irq_sqr` (`run_stimulus`):

* выравнивание на снятие ресета каждого прогона (run 0 — как раньше,
  бит-в-бит); между прогонами — ожидание СПАДА `rst_n` через счётчик
  clk-сэмплируемого watcher'а (`rst_fall_watch`): спад может попасть ВНУТРЬ
  хвоста расписания (irq_ext выходит сразу после обслуживания обоих IRQ,
  раньше окончания ширины soft-пульса), поэтому простой level-wait границу
  прогонов мог бы пропустить;
* random-режим пересчитывает расписание на каждый прогон с
  `seed = IRQ_SEED + run_index` (по-прежнему ОДИН однопоточный LCG-проход;
  прогон 0 бит-идентичен прежнему однопрогонному расписанию того же seed,
  детерминизм сохранён);
* стимул между прогонами не «протекает»: IRQ-драйвер каждый такт сброcа
  обнуляет своё состояние и линии (device-регистры чистит mem-драйвер через
  `model.reset_devices()`).

Результат (irq_ext, NUM_RUNS=2): `runs_checked=2 runs_failed=0
csr_checked=2 csr_live=32` (16 на прогон), оба прогона по 474 цикла,
mirror-reset RAL между прогонами отрабатывает штатно; контроль NUM_RUNS=1 —
PASS 474 (не сломан).

### IRQ-агент: покрытие обслуженных линий/масок (irq_cg / irq_line_cg)

`scr1_fcov_if` получает живые линии `irq_lines` (ширина —
`scr1_cfg_pkg::IRQ_LINES_NUM`, не хардкод; `scr1_bind.sv` подключает
одноимённый входной порт `scr1_top_ahb`, идущий на IPIC) и сэмплирует два
новых covergroup **на ext-IRQ trap-коммите** (`commit_trap &&
mcause == 32'h8000_000B`):

* `irq_cg` (один сэмпл на ext-трап):
  * `cp_live_cnt` — `$countones(irq_lines)` в момент коммита: бины
    `dropped`(0)/`one`(1)/`few`(2..3)/`many`(4..8)/`storm`(9..16).
    `dropped` — штатная ситуация: дренаж IPIC стоит ~15 циклов/трап, и
    короткий инжектированный импульс обычно уже снят к коммиту;
  * `cp_burst_cnt` — число линий в маске, **накопленной с предыдущего
    ext-трап-коммита** (`irq_burst` — sticky-OR линий внутри интерфейса,
    сбрасывается на сэмплировании): IPIC latch'ит фронты, поэтому маска
    импульса переживает снятие линий и видна на коммите дренажа. Бины те
    же (без `dropped`) — одиночные маски (`one`) отличаются от
    одновременных мульти-линейных совпадений (`few/many/storm`);
  * `cp_low_line` — наименьший установленный бит накопленной маски
    (высшая приоритетная линия в порядке IPIC search-one/SOI);
  * `x_cnt_low` — cross `cp_burst_cnt` × `cp_low_line` (совпадение
    «число линий × приоритетная линия»).
* `irq_line_cg` — bin-массив по каждой линии 0..15: каждый установленный
  бит накопленной маски даёт один сэмпл (присутствие линии в обслуженных
  масках), маска сэмплируется «как есть», без догадок о том, какую именно
  линию обслужил данный трап.

Числа (COV=1, irq_stress `IRQ_RANDOM=6 IRQ_SEED=1 IRQ_MASK_MODE=random16`,
28 ext-trap-коммитов): `cp_burst_cnt.many=6 storm=4`,
`cp_live_cnt.dropped=24 many=3 storm=1`, `irq_line_cg.cp_line.line[0..15]`
— ЗАДЕТЫ ВСЕ 16 бинов (hits 2..9), `x_cnt_low`: `many×line[0]=4`,
`many×line[1]=2`, `storm×line[0]=4`; прежние бины не деградировали:
`exc_cg.cp_irq.interrupt=29` (28 ext + 1 soft), `x_irq_ec=28+1`.

## Milestone 7 (готов): CSR live-predict — frontdoor RAL

RAL-зеркало строится ЖИВЬЁМ из golden-семантики каждого CSR-доступа и на
выходе прогона СРАВНИВАЕТСЯ с hardware-снапшотом (milestone 3 предсказывал
снапшот в зеркало вслепую — само-согласованно). Классический reg2bus-адаптер
к CSR ядра неприменим (шинного доступа к CSR нет) — «frontdoor» процессорного
ядра есть поток его же инструкций; golden-модель вычисляет ожидаемый
результат каждой csrrw/csrrs/csrrc независимо от DUT (ibex-подход).

```
commit_probe (+6 CSR-тапов, latch на request-цикле)
   → scr1_commit_if ┬→ csr_agt.mon (СОБСТВЕННЫЙ монитор — ibex rvfi_monitor:
             │    события trap / MRET / csr_r|w_req) → scb.commit_imp ┐
             │    (`uvm_analysis_imp_decl(_csr)` — без forwarder'ов)  │
             └→ monitor (core-агент) ─ ap (run) → csr_agt.run_export ─────┤
                                        (напрямую в scb.analysis_export) v
                                              csr_agt.scb (scr1_csr_scoreboard)
                                                                 |
   on_commit: scr1_csr_dec(instr) → {addr, txn, is_imm, op_set/clear}  | golden
   old = r_data (pre-write), operand = w_data (EXU mux)  →  legalize(op(old,operand))
                                                                 |
                                              RAL mirror ← predict(golden)
   write (exit): snapshot(state_probe) vs mirror — СНРАВНЕНИЕ (не слепой predict)
```

**Упаковка в агент (2026-11-22, ветка exp/uvm-csr-agent)**: CSR-движок
milestone 3/7 перенесён из `environment/` в отдельный ПАССИВНЫЙ
`scr1_csr_agent` (`tb/common/csr_agent/`, форма ibex `ibex_cosim_agent` —
БЕЗ driver/sequencer). Скорборд живёт в агенте и создаётся им
(`csr_agt.scb`), поэтому иерархия в логах сменилась
`uvm_test_top.env_h.csr_scb` → **`uvm_test_top.env_h.csr_agt.scb`**;
message-ID (`scr1_csr_scoreboard.*`) и формат SUMMARY СОХРАНЕНЫ
бит-в-бит. У агента есть СОБСТВЕННЫЙ монитор `scr1_csr_monitor`
(ibex `rvfi_monitor`-паттерн — checker-агент сэмплирует retire-шину
сам): он читает `scr1_commit_if mon_cb` (read-only #1step, ничего не
драйвит) и публикует только CSR-релевантные ретаи — trap / MRET
(`OPCODE_MRET`) / `csr_r_req|csr_w_req`, т.е. ровно то множество,
которое потребляет `on_commit` (фильтр семантически тождествен
полному потоку и облегчает длинные прогоны; сборка записи зеркалит
`scr1_monitor` поле-в-поле). `scr1_monitor` core-агента сохраняет
свой полный commit-поток для остальных потребителей (cosim-агент,
fcov). Run-end поток (exit-снапшот) приходит из env через
agent-level `run_export` (ibex dmem_port/imem_port-паттерн) и идёт
НАПРЯМУЮ в унаследованный `scb.analysis_export` (скорборд сам
является `uvm_subscriber #(scr1_transaction)`); commit-поток —
через стандартный макрос `` `uvm_analysis_imp_decl(_csr) ``:
второй TLM-вход скорборда `commit_imp`/`write_csr()`, куда
`mon.ap` подключён напрямую (forwarder-компоненты не нужны;
макрос проверен на Verilator 5.053 + uvm-verilator — старая
ловушка «imp_decl сломан» для текущей версии НЕ подтвердилась;
в cosim-агенте пока остаются plain-subscriber forwarder'ы —
кандидат на аналогичное упрощение). RAL-модель скорборд
забирает из `uvm_config_db` сам (`build_phase`), публикация из env
сохранена.


* **Типы транзакций** (`scr1_tb_pkg`): `scr1_csr_txn_e` = NONE / **READ /
  WRITE / ATOMIC_RW** + единый декодер `scr1_csr_dec(raw_opcode_t)` →
  `scr1_csr_dec_s {valid, addr, txn, is_imm, op_set, op_clear, funct3, rd,
  rs1}` — никакого разбросанного слайсинга funct3 по scoreboard'ам. Гейтинг
  записи по spec: CSRRW пишет всегда (читает iff rd!=x0); CSRRS/C пишут iff
  rs1/uimm ПОЛЕ != 0 (совпадает с `|exu_queue.rs1_addr` в scr1_pipe_exu.sv —
  НЕ по значению rs1!). `raw_opcode_t`/`csr_addr_t`/`csr_data_t` — typedef'ы
  (csr_* живут в cfg_pkg — единый источник для tb_pkg и RAL).
* **Тайминг-ловушка EXU→CSR (главная находка)**: CSR-доступ, обновляющий
  mstatus.MIE/mie, СТАЛЛИТ CSR-FSM EXU на цикл (SCR1_CSR_INIT→RDY по
  csr2exu_mstatus_mie_up) → `exu2csr_w_req` fires РАНЬШЕ instret, а
  `csr2exu_r_data` в цикле retire уже несёт ПОСТ-значение. Плюс
  `exu2csr_w_data` = ОПЕРАНД (rs1/zimm), а не итог: WRITE/SET/CLEAR применяет
  pipe_csr по `exu2csr_w_cmd`. Решение: проба latch'ит CSR-событие на ПЕРВОМ
  request-цикле (r_data = достоверный old) и предъявляет его с retire своей
  инструкции (EXU держит инструкцию до retire → совпадение request+retire
  возможно только для ОДНОЙ инструкции — неоднозначности нет).
* **IRQ на границе retire** (вторая находка): SCR1 утверждает instret и
  take_irq в одном цикле (IRQ берётся МЕЖДУ инструкциями, предыдущая УЖЕ
  завершена). Старая проба теряла retire-запись (trap-ветка приоритетнее) —
  терялись CSR-события (isr_sample: `csrs mie`) и mret (irq_ext: mstatus
  resync). Фикс: retire-запись сразу, trap-запись — отложенно на цикл через
  pending-регистр (flush пайплайна гарантирует отсутствие retire между ними).
  Исключения СОХРАНЯЮТ старое поведение (трапящая инструкция не ретайрится —
  конвенция golden trap-step).
* **Скрытый баг milestone 3 исправлен**: `csr_mepc_ff` объявлен `[31:1]` —
  присваивание в 32-битное поле снапшота несло ЗНАЧЕНИЕ mepc>>1 (0xd52→0x6a9),
  а не позиционное {ff,1'b0}; слепой predict это маскировал, live-зеркало
  вскрыло. state_probe получил MEPC_PAD-порт с позиционной досборкой (как
  commit_probe).
* **Golden-проверки scoreboard** (все — uvm_error в g_csr_mismatches):
  OPERAND (w_data EXU vs декод instr), LIVE_READ (old DUT vs зеркало),
  WRITE_MISSING / WRITE_UNEXPECTED (w_req vs spec-гейтинг), PROBE_ALIGN
  (addr-канарейка decode-vs-probe + rd_data==r_data), SNAPSHOT (exit vs
  live-зеркало — ловит класс «запись дошла до mux, но не до flop»,
  BUG-001/#80). Итог записи в flop проверяется ОТЛОЖЕННО (next old-check /
  exit-snapshot): w_data — операнд, не результат.
* **WARL-легилайзеры** (csr_legalize, правда из scr1_pipe_csr.sv): mstatus
  = (raw&0x88)|0x1800 (MIE/MPIE; MPP=11 зашит); mie = raw&0x888;
  mtvec = {raw[31:6],4'b0,1'b0,raw[0]} (BASE 64B-гранулярность, MODE 1 бит);
  mepc = raw & ~((1<<MEPC_PAD)-1); mcause = {raw[31],25'b0,raw[5:0]};
  mcounten = raw&0x5; mscratch/mtval/счётчики = full RW.
* **Классы адресов**: RW (300/304/305/340-343/7E0) — полный live-трекинг;
  COUNTER (B00/B02/B80/B82) — записи golden-checked, ИЗ exit-сравнения
  исключены (lo тикают, hi получает аппаратный перенос — mcycle.hex провоцирует
  его специально); RO (301/F11-F14) — read-check против констант; HW (344 mip
  — комбинационные device-линии, НЕ flop) и UNTRACKED (IPIC 0xBF0-7...) — skip.
* **Trap/mret resync**: аппаратные записи трапа (mepc←pc, mcause,
  mstatus MPIE←MIE/MIE←0, **mtval←trap_val у исключений / ←0 у IRQ** —
  мультиплексор csr_mtval_next в scr1_pipe_csr.sv; trap_val протащен в
  коммит-записи отдельным полем через тап exu2csr_trap_val) и mret
  (MIE←MPIE, MPIE←1) минуют шину w_req — зеркало ресинхронизируется из
  trap-записей и опкода mret (0x30200073). mtval полноценно трекается
  (первоначальный v1-флаг mtval_relaxed удалён).
* Вердикт: `csr_live=` в SCR1_RESULT; ВЕСЬ вердикт-вывод переведён с
  $display на uvm_info/uvm_error (UVM_NONE — grep Makefile видит при любой
  verbosity), $fatal убран (Makefile определяет вердикт по grep).
* **NUM_RUNS>1** (ветка feat/uvm-csr-multirun): live-зеркало — состояние
  ОДНОГО прогона; после exit-проверок run k < N scoreboard делает
  `ral.reset()` + `shadow.delete()` (reset-константы RAL = аппаратные
  reset-значения по построению → зеркало консистентно с ресетнутым DUT),
  последний прогон сохраняет снапшот для report-дампа. До фикса NUM_RUNS=2
  давал ложные LIVE_READ на run 2 (репродукция: isr_sample FAIL csr_mm=2 —
  mtvec 0x1c0 vs stale 0x1c1, mstatus 0x1880 vs 0x1888; после фикса PASS
  csr_checked=2 csr_live=28).

### Результаты milestone 7 (Verilator 5.053, CFG=MAX, xPack 15.2.0)

| Прогон | Вердикт | csr_live | csr_mm |
|---|---|---|---|
| hello (csr_test) | PASS | 0 | 0 |
| isr_sample (trap/mret resync, 3 IRQ) | PASS 457 | 14 | 0 |
| a5_1 | PASS 17184 | 0 | 0 |
| fuzz SEED=1 + SPIKE_COSIM=1 | PASS 970/970, trap_checked=1 | 9 | 0 |
| irq_ext + MEM_AGENT=1 (IRQ-агент) | PASS 474 | 16 | 0 |
| mcycle.hex (НЕГАТИВ-КОНТРОЛЬ, ветка без фикса #80) | FAIL failed=1 (a0 — BUG-001) | 6 | **0** (счётчики исключены из exit-сравнения из-за carry) |

### Directed-вектор csr_walk1 — walking-ones/zeros по всем writable CSR

`sim/tests/csr_walk1/` (сборка/прогон: `make hex SW_TEST=csr_walk1`,
`make run TEST=scr1_csr_test SW_TEST=csr_walk1`, покрытие — `COV=1
RUN_TAG=walk1`). Раскладка зеркалит isr_sample/irq_ext/fetch_fault:
trap-таблица `.org (64*3)` @0x1C0, `_start`@0x200, common `link.ld`, выход
через `la t0, sc_exit; jr t0` (ecall НЕ используется, трапов в векторе нет).

Вектор намеренно «глупый» — **ни одной самопроверки в asm**: WARL-правду
знает только окружение, golden-проверки milestone 7 (LIVE_READ / OPERAND /
WRITE_MISSING / WRITE_UNEXPECTED / SNAPSHOT) работают по каждому retire.
Для каждого из 12 writable CSR таблица из **68 паттернов** (walking-ones
`1<<i` и walking-zeros `~(1<<i)` для i=0..31 + фиксированные 0x0,
0xFFFFFFFF, 0xA5A5A5A5, 0x55555555) пишется `csrrw` (ATOMIC_RW: operand +
запись + golden-predict `csr_legalize`) и читается обратно `csrr` (READ:
LIVE_READ против зеркала) — именно read-back побитово прогоняет каждую
WARL-маску.

Порядок секций и страховки (все — ради «вектор не должен трапнуться»,
вердикт a0=0 = «дошли до конца»):

* mscratch 0x340 → mtval 0x343 → mepc 0x341 → mcause 0x342 → **mstatus
  0x300 → mie 0x304**: walking-ones по mstatus взводит MIE=1, что безопасно
  только пока mie ещё в reset-состоянии 0 (все три маскированы);
* mcounten 0x7E0 → **mtvec 0x305 ПОСЛЕДНИМ** из управляющих (walking-записи
  оставляют мусорную trap-базу), сразу после — восстановление
  mtvec=0x1C0 (direct, наша таблица), mie=0, mstatus=0x1880 (MPP=11|MPIE=1),
  mcounten=0x5 (CY|IR);
* счётчики mcycle 0xB00 → minstret 0xB02 → mcycleh 0xB80 → minstreth 0xB82
  с паттернами `pat | 0x80000000` (значение всегда ≥ 2^31); **LO-половины
  восстанавливаются 0xFFFFFFFF САМЫМИ ПОСЛЕДНИМИ**: в этом RTL запись
  hi-половины перезаписывает и counter[31:8] (незакрытый класс BUG-002/#87),
  поэтому после lo-восстановления hi-записей быть не должно. Обе LO = all
  ones сохраняют exit-инвариант scoreboard'а `mcycle >= minstret`
  (оба счётчика переполняются в одно и то же восстановленное hi-значение,
  mcycle тикает быстрее);
* trap-таблица минимальная (`_trap_fail: li a0,1; j sc_exit`) — неожиданный
  трап даёт внятный FAIL, а не hang.

**Результат (Verilator 5.053, CFG=MAX, xPack 15.2.0, MEM_AGENT=1)**:
`SCR1_RESULT: PASS` — 6963 циклов, csr_checked=1, **csr_live=1638**,
csr_mismatches=0, trap_checked=0, UVM_ERROR/UVM_WARNING=0; mem-scoreboard
6835 транзакций violations=0. Идентично под `COV=1` (детерминизм).
1638 = 12 CSR × 68 паттернов × 2 доступа + 6 восстановлений; из них
**1092 события по 8 RW-CSR проходят LIVE_READ-сверку** DUT r_data против
golden-зеркала (546 событий счётчиков — OPERAND/запись, read/exit для них
пропускается из-за свободного тика). **Расхождений модель↔RTL не найдено:
`csr_legalize` побитово совпал с scr1_pipe_csr.sv на всех 68 паттернах всех
12 регистров — правки env не потребовались.**

Покрытие `insn_cg.cp_csr` (хиты на bin; «до» — прогон isr_sample в этом же
worktree, `COV=1 RUN_TAG=base_isr`; в скобках — накопленные датчики
кампании в главном дереве: ec1=fetch_fault, irq=irq_ext/irq_stress):

| bin | до: isr_sample (ec1 / irq) | после: csr_walk1 |
|---|---|---|
| mstatus | 1 (0 / 2) | **137** |
| mie | 7 (0 / 5) | **137** |
| mtvec | 3 (1 / 2) | **137** |
| mscratch | 0 (3 / 7) | **136** |
| mepc | 0 (1 / 0) | **136** |
| mcause | 3 (1 / 0) | **136** |
| mtval | 0 (0 / 0) | **136** |
| mcounten | 0 (0 / 0) | **137** |
| mcycle | 0 (0 / 0) | **137** |
| minstret | 0 (0 / 0) | **137** |
| mcycleh | 0 (0 / 0) | **136** |
| minstreth | 0 (0 / 0) | **136** |
| mip (HW, RO) | 7 (0 / 0) | 0 — вектор его не читает |

Все 12 writable CSR закрыты (было: mscratch/mepc/mtval/mcounten и все четыре
счётчика — ноль). Дополнительно `uarch_cg.csr_access` 29 → **1638**, cross
`x_opcode_rd` 26 → **1496**, annotate-сводка fcov 17% → 20% (14/81 → 17/81
строк). Контроли env после добавления вектора эталонные: hello PASS 16990
(csr_live=0), isr_sample PASS 457 (csr_live=14).



Изучен `/home/m.yaroslove/Work/RISC-V-CPU-Core-UVM-Based-ISA-Compliance-Verification`
(v0.1 MVP, README-first скелет: mock-Spike DPI + стаб-ядро, VCS/Questa, UVM-1.2;
git-история — 3 коммита правок README).

**Код напрямую неприменим**: scoreboard не компилируется (`get_active_imp()`
в UVM нет; нужен `` `uvm_analysis_imp_decl ``), test без run_phase/objection,
монитор без clocking-блоков (гонки), сравнение тривиально истинно (mock),
нет загрузки программ/reset/watchdog/RAL — всё это у нас уже есть.

**Архитектурно ценны 3 паттерна** (переносим в milestone 2+):

1. **Commit-схема транзакции (RVFI-lite)** — `valid/pc/instr/rd_addr/rd_data/
   mem_we/mem_addr/mem_wdata/trap/priv`: контракт для instruction monitor.
   Все точки съёма у SCR1 уже апробированы в `scr1_trace_logger.sv`
   (FIFO {pc,instr} из IDU, retire/EXU, rd write, trap-detail CSR) и
   `scr1_trace_decoder_pkg`.
2. **Стабильная DPI-граница ISS** (`iss_init/load_elf/step`, у них
   `dpi_spike_init/next/fini`) — seam для настоящего Spike (собран в docker
   `scr1-spike-verif`/DiveFuzz-базе; прецедент — ibex `riscv_cosim`).
3. **Порядковая сверка двух очередей с first-mismatch-остановом** — совпадает
   с логикой редуктора (первое расхождение → контекст → минимизация).

### Оценка сложности интеграции паттернов

| # | Паттерн | Состав работ | Объём | Срок | Риск |
|---|---|---|---|---|---|
| 1 | Commit-канал (схема + instruction monitor) | `scr1_commit_s` в tb_pkg; пробы в `scr1_dut.sv` (сигнальный список копируется из trace_logger: FIFO idu→exu {pc,instr}, instret/curr_pc, rd_addr/rd_data, LSU dmem_req/cmd/addr/wdata, trap/mcause); расширение `scr1_if` + mon_cb; монитор публикует commit на каждый retire | ~+150..200 строк SV | 1–2 дня | LOW: все тапы проверены в потоке 224/224; XMR-глубина не проблема; RVC обрабатывает FIFO-паттерн логгера |
| 3 | Dual-imp scoreboard | `` `uvm_analysis_imp_decl(_dut)/(_ref) ``, очереди, порядковая сверка pc/instr/rd/mem/trap, first-mismatch → полный контекст + останов, счётчики → SCR1_RESULT; fазза-2: ref-сторона = file-monitor (реплей Spike-лога) | ~150–250 строк | 0.5–1 день | LOW-MED: проверить imp_decl-макросы под uvm-verilator (фолбэк — два subscriber + TLM fifo, как в лабе) |
| 2A | Spike офлайн (реплей логов) | Spike-прогон в существующем docker-потоке → парсер commit-лога (семантика reducer trace.py) → ref-monitor → тот же scoreboard | ~200 строк (SV+py) | 1–2 дня | LOW: пост-мортем сравнение (first divergence после прогона); MMIO/CSR-фильтры уже каталогизированы в spike-verif |
| 2B | Spike in-process (DPI lockstep) | libriscv статик-либом (ibex cosim-прецедент), DPI iss_init/iss_step→commit_s, MMIO-модели (console/timer/IPIC) или фильтры адресов на стороне Spike, пейсинг «DUT commit → ref step», линковка в --binary | ~300–400 строк C++/SV + Makefile | 3–5 дней | HIGH: сборка Spike как либы на хосте, ABI C++17 с Verilator, отладка lockstep (trap-тайминг, 16/32-бит instr, расхождения mvendorid/misa — известны по docker-потоку) |

Рекомендуемая последовательность: **1 → 3 → 2A → 2B** (2A закрывает ~90%
потребностей фаззер-триажа; 2B — только если DiveFuzz/DRVFuzz понадобится
online-управление генерацией по first-mismatch в процессе симуляции).

Внешний контур фаззинга готов уже сейчас без доработок: генератор → hex →
`make run TEST_HEX=fuzz_N.hex` → `SCR1_RESULT` (+ `<test>.log`/VCD при
флагах). Паттерны 1+3 дают гранулярность триажа «первая разошедшаяся
инструкция» вместо «итоговый a0».

## Report server и XML-лог (готов): кастомный UVM report server

Классический паттерн «Application of custom UVM report server» (SNUG 2013,
G. McGregor), донор — ALU-лаба (`uvm_lab_ALU_16bit/tb/alu_report_server.sv`).
`scr1_report_server extends uvm_default_report_server`
(`tb/env/environment/scr1_report_server.sv`, `` `include `` в `scr1_env_pkg`),
устанавливается в `scr1_base_test::build_phase` через
`uvm_report_server::set_server()` (сообщения до установки — elaboration-баннеры
— остаются на дефолтном сервере, как в Cookbook-рецепте):

* **`process_report_message`**: каждый UVM_ERROR/UVM_FATAL учитывается по ID
  (счётчик + первый текст + время + file/line — triage-таблица); все сообщения
  гистограммируются по verbosity (метаданные, которые дефолтный summary не
  показывает); затем сообщение передаётся базовому серверу (severity/quit-
  счётчики и действия не меняются — `get_severity_count`/`report_summarize`
  в `final_phase` продолжают работать).
* **`summarize`**: после стандартного UVM Report Summary — секция «SCR1
  Report Server Summary»: run info (тест/UVM/время/verbosity/seed),
  конфигурация `scr1_cfg_pkg` (включая путь памяти MEM_AGENT), счётчики
  вердикта SCR1_RESULT (runs/diff-lockstep/CSR), гистограмма verbosity,
  таблица error/fatal по ID и итоговый вердикт. Консольная строка
  `SCR1_RESULT:` НЕ дублируется (остаётся за `scr1_base_test` — grep-контракт
  Makefile единственно источающий); `$fopen/$fdisplay` — только для файла XML,
  консольный репортинг — исключительно UVM-макросы.
* **XML-лог** (`XML_LOG=<path>` → `+SCR1_XML_LOG=<path>`, рантайм-плюсарг —
  пересборка не нужна; голый плюсарг → `logs/scr1_log.xml`): документ
  `<?xml ...?><log>`, каждое сообщение — элемент `<msg>` с полными
  метаданными (verbosity/severity/file/line/id/time/context), спецсимволы
  экранируются; в `summarize` дописывается элемент `<summary>` (severity-
  счётчики `<sev>`, `<counters>` вердикта и `<verdict result="PASS|FAIL">`
  со SCR1_RESULT-эквивалентной строкой: PASS, если UVM_ERROR/UVM_FATAL==0 и
  нет проваленных прогонов/diff/CSR-расхождений) и документ закрывается.
  Просмотр: `make viewer XML_LOG=logs/scr1_log.xml`
  (`tools/scr1_log_viewer.py`, GUI/CLI — фильтрация и переформатирование в
  момент просмотра, без повторного прогона; секции 7/16 статьи).

Совместимость с uvm-verilator подтверждена прогонами: `set_server`,
виртуальные `process_report_message`/`summarize`, `$value$plusargs`,
`$fopen/$fdisplay` работают без оговорок (`uvm_report_server.svh` лабы и
окружения байт-в-байт идентичны); форсированный `srv.report_summarize()` в
`final_phase` на FAIL корректно печатает triage-секцию и закрывает XML до
автоматического summary раннера (второй вызов — handle уже закрыт).

### Результаты report server (Verilator 5.053, CFG=MAX, xPack 15.2.0)

| Прогон | Вердикт | XML |
|---|---|---|
| csr_test hello + `XML_LOG=logs/scr1_log.xml` | PASS 16990 | well-formed (minidom), `<verdict result="PASS">`, записи UVM_INFO |
| csr_test fetch_fault БЕЗ инъекции + `XML_LOG=logs/fail.xml` | FAIL failed=1 (негатив-контроль) | записи UVM_ERROR, `<verdict result="FAIL">`, `>>> TEST FAILURE !` |
| csr_test isr_sample без `XML_LOG` | PASS 457 | не создаётся, поведение штатное |

## Типизация представления (typedef sweep, готов 2026-11-22)

Все «магические» ширины/срезы окружения заменены осознанными типами и
именованными константами; единый источник — `scr1_cfg_pkg` (блок
«Representation types»), ширины ВЫВОДЯТСЯ из геометрии DUT
(`XLEN`/`AHB_WIDTH`/`IRQ_LINES_NUM`/`MEM_BYTE_BITS`), а не задаются
литералами. Правило: любое изменение представления запрещено —
typedef'ы бит-в-бит эквивалентны прежним `logic [N:0]` (проверено
полной батареей: циклы/счётчики/keystream/coverage-бины совпали).

| Тип | Ширина (вывод) | Семантика | Основные потребители |
|---|---|---|---|
| `irq_lines_t` | `[IRQ_LINES_NUM-1:0]` | вектор внешних IRQ-линий | scr1_irq_if, irq driver/monitor/seq, mem_model irq_lines (через каст), fcov_if |
| `irq_line_cnt_t` | `[$clog2(IRQ_LINES_NUM+1)-1:0]` | число активных линий (0..16) | fcov_if count_ones / irq_cg |
| `irq_line_idx_t` | `[$clog2(IRQ_LINES_NUM)-1:0]` | индекс линии (0..15) | fcov_if low_bit / irq_line_cg |
| `ahb_addr_t` / `ahb_data_t` | `[AHB_WIDTH-1:0]` | адрес/данные AHB | ahb_mem_if, mem driver/monitor/txn/scb/seqs, scr1_dut порты, scr1_if dmem-наблюдение |
| `ahb_htrans_t` / `ahb_hsize_t` | `[1:0]` / `[2:0]` | поля HTRANS/HSIZE (AMBA) | те же + HTRANS_*/HSIZE_* localparam'ы теперь этого типа |
| `ahb_hburst_t` / `ahb_hprot_t` | `[2:0]` / `[3:0]` | поля HBURST/HPROT | scr1_dut (RTL-facing нети) |
| `ahb_be_t` | `[AHB_BYTES-1:0]` | байтовые стробы (бит на lane) | mem_model be_form/read_word/write_word, mem_driver be_l |
| `ahb_byte_offs_t` | `[$clog2(AHB_BYTES)-1:0]` | байтовое смещение в слове | mem_model be_form(offset) |
| `counter_word_t` | `[2*XLEN-1:0]` | 64-битное тело mcycle/minstret | scr1_state_probe |
| `mtvec_base_t` | `[XLEN-MTVEC_BASE_LSB-1:0]` | BASE[31:6] (64B-гранулярность) | scr1_state_probe |
| `mem_byte_t` | `[MEM_BYTE_BITS-1:0]` | байт памяти/символ консоли | mem_model mem[], monitor/driver console-byte |
| `rvc_insn_t` | `[RVC_INSN_BYTES*MEM_BYTE_BITS-1:0]` | 16-битовое RVC-слово | RVC_C_EBREAK, fcov_if |
| `mem_delay_ch_t` | `[1:0]` | канал delay-окна (DMEM/IMEM/BOTH) | mem_txn.delay_ch, mem_delay_seq, mem_driver |

Именованные константы (все выводятся из существующих параметров):
`AHB_WORD_MASK` (выравнивание на слово — заменила срезы `{addr[31:2],2'b00}`
и сравнения `[31:2]`), `AHB_BE_NONE/BYTE/HALF/WORD`, `MMIO_REGION_MASK`
(сравнение MMIO-окон вместо срезов `[31:12]`), `MCAUSE_IRQ_BIT` /
`MCAUSE_EC_MASK` / `MCAUSE_MASK` / `MCAUSE_M_EXT_IRQ`, битовые позиции
`MSTATUS_*_BIT`/`MIE_*_BIT`/`MCOUNTEN_*_BIT` + `MSTATUS_IE_SHIFT` (маски
MSTATUS_*/MIE_MASK/MCOUNTEN_MASK/MTVEC_CMP_MASK/MEPC_MASK теперь
выводятся), ISA-кодировки `OPCODE_*`/`FUNCT7_MULDIV`/`FUNCT3_FENCE_I`/
`FUNCT3_CSRR*`/`FUNCT12_*` (`OPCODE_MRET` собирается из частей),
`TRAP_INSTR_MARKER` (маркер trap-коммита FFFFFFFF), `RVC_QUAD_32B`,
`RVC/RVI_INSN_BYTES`, `AHB_CH_NUM`, тайминги `CLK_HALF_PERIOD_NS` /
`DRAIN_TIME_NS`, легаси-ручки `STALL_PATTERN_NONE` / `IMEM_FETCH_DELAY`.

Сырые срезы/литералы сохранены только как ОСОЗНАННЫЕ исключения:
(а) структурные WARL-конкатенации (mtvec/mcause-реконструкции в пробах и
легилайзере — ширины нулевых заполнений выведены из констант);
(б) C-сторона DPI (`spike_cosim_dpi.cc` — C-типы; SV-сигнатуры `.svh`
остались `int`, маппинг не менялся — на SV-стороне типизированные касты);
(в) RTL-геометрия в harness (порты/нети scr1_dut на `SCR1_IRQ_LINES_NUM`/
`SCR1_AHB_WIDTH`, mepc-порты проб `[XLEN-MEPC_PAD-1:0]`, legacy
peek/poke-байт-лейны memory_tb); (г) параметрические FIFO-указатели
`[AW-1:0]`/`[CW-1:0]`/`[LAW-1:0]`/`[LCW-1:0]` (ширины из `$clog2`);
(д) служебные `'0`/`'1`; таблицы ISA-кодировок в центральном декодере
fcov (funct3/funct7/quadrant case-таблицы и coverage-бины — спека,
единственное место); алгоритмические константы PRNG (LCG Numerical
Recipes, xorshift32 13/17/5); структурная пара `retire_stall[1:0]`
({imem,dmem}); спецификации полей RAL (size/lsb_pos литералами, где
нет 1:1 константы) и `#1step`-тайминги clocking-блоков.

## Следующие этапы (backlog)

Milestone 2 (дифференциальная сверка), milestone 3 (CSR RAL), milestone 4
(покрытие) и этап B загрузчика/памяти (stage A string-loader + stage B
реактивный memory-агент) выполнены — см. разделы выше. Далее по плану:

1. **CSR RAL frontdoor** — ВЫПОЛНЕНО (2026-11-18, milestone 7) в форме
   live-predict: RAL-зеркало строится из golden-семантики каждого CSR-доступа
   (декодер scr1_csr_dec + WARL-легилайзеры), exit-снапшот СРАВНИВАЕТСЯ с
   зеркалом. Reg2bus-адаптер к CSR ядра архитектурно неприменим (нет шинного
    доступа; frontdoor ядра = поток его инструкций). CSR-сравнение в
    дифференциальном scoreboard (2B: Spike log_reg_write type-4 против DUT
    live-событий) — ВЫПОЛНЕНО (2026-11-19, см. «CSR-diff (2B)» в milestone
    2B): фаза A per-commit (наличие+адрес записи) и фаза B run-exit
    (снапшот DUT vs живое CSR-состояние Spike по INCLUDE-списку с масками).
     Остаток: directed-вектор walking-ones по CSR — ВЫПОЛНЕНО
     (2026-11-21, `sim/tests/csr_walk1`, см. «Directed-вектор csr_walk1»
     в milestone 7: 1638 live-проверок, все 12 writable CSR в cp_csr,
     0 расхождений модели с RTL). (mtval-моделирование
    на трапах закрыто 2026-11-19: tap exu2csr_trap_val → commit_s.trap_val →
    resync exc←trap_val / IRQ←0.)
2. **Trap-выравнивание** — ВЫПОЛНЕНО (2026-11-18) для precise-exceptions:
   DPI trap-шаги (сопряжённая запись mcause+mepc за шаг) возвращаются как
   golden TRAP-записи, scoreboard сверяет их с DUT trap-коммитами 1:1
   (mepc+mcause); счётчик trap_checked в SCR1_RESULT. Остаток: device-модели
   (timer/IPIC/console) в Spike-памяти 2B — откроют выравнивание IRQ-трапов
   и полную дифференциальную сверку isr_sample.
3. **Store-поток для DRVFuzz** — сравнение mem_we/mem_addr/mem_wdata (поля в
   scr1_commit_s уже есть; у Spike — log_mem_write; у mem-агента готов
   analysis-порт AHB-транзакций scr1_mem_txn).
4. **IRQ agent** — ВЫПОЛНЕНО (2026-11-18, milestone 6): асинхронное
   стимулирование ext/soft IRQ из UVM через injection-слой scr1_mem_model
   (inj_ext/inj_soft, OR-слияние в драйвере) + виртуальная последовательность
   scr1_irq_run_vseq (форк прогона и стимула) + тест scr1_irq_test + вектор
   sim/tests/irq_ext. Остатки — ВЫПОЛНЕНЫ (2026-11-19/21): многоимпульсные/
   случайные сценарии (irq_stress + IRQ_RANDOM/IRQ_SEED/IRQ_MASK_MODE),
   NUM_RUNS>1 для стимула (per-run цикл + seed+run_index), каверпойнты
   обслуженных линий/масок (irq_cg/irq_line_cg на ext-trap-коммитах),
   concurrent-soft с гарантированным обслуживанием (IRQ_SOFT_GUAR,
   дренаж-модель est_first_quiet). **Адаптация в ibex-стиль — ВЫПОЛНЕНО
   (2026-11-21, feat/uvm-irq-agent-ibex)**: отдельный `scr1_irq_agent`
   (`scr1_irq_if`/`scr1_irq_seq_item`/sequencer/driver/monitor/agent +
   реальные сиквенсы `scr1_irq_single_seq`/`scr1_irq_random_seq`, донор
   `ibex/dv/uvm/core_ibex/common/irq_agent`); инжекционный слой
   scr1_mem_model (inj_ext/inj_soft + OR-слияние в mem-драйвере) УПРАЗДНЁН;
   пины ядра = combinational OR линий агента и device-зеркала внутри
   `scr1_irq_if` (программный device-самотриггер isr_sample сохранён);
   scr1_irq_run_vseq — координатор на v_sqr (irq_sqr). Все baseline'ы
   cycle-exact (см. «Ре-верификация ibex-агента»). Незакрытый остаток:
   sby-formal IPIC priority как независимое подтверждение арбитража.
   Timer-IRQ агенту НЕ нужен: machine timer — встроенный
   RTL-модуль scr1_timer (в scr1_top_ahb, на внутреннем dmem-роутере,
   окно 0x0049_0000 не выходит на внешний AHB), работает при любом
   MEM_AGENT (isr_sample: PASS 457 с 3 IRQ ещё в Stage B); реальная
   timer-задача осталась только на Spike-стороне 2B (в DPI-модели
   Scr1Simif нет окна 0x490000 — программы с mtime-доступами под
   lockstep не запустить; значения таких load'ов cosim-scoreboard и так
   фильтрует is_mmio_load).
5. **Память-агент: развитие** — ВЫПОЛНЕНО: sequencer-режим error-инжекции
   (2026-11-19, feat/uvm-agent-evolve), случайные wait-states
   (+AGENT_RANDOM_STALL/AGENT_STALL_SEED/AGENT_RANDOM_STALL_CH —
   детерминированный xorshift32), подписка mem-scoreboard на ap монитора,
   rdelay-модуляция через sequencer (2026-11-21, feat/uvm-agent-remain —
   см. «Sequencer rdelay-модуляция» в этапе B), AGENT_RANDOM_STALL в
   штатных кампаниях dv/fuzz (regress + MIXED_STALL — см. dv/fuzz/README.md,
   «Кампании со случайными wait-states»).
6. **riscv-dv таргет SCR1 + seed-регрессия** — выполнено (dv/fuzz).
7. **Coverage** — выполнено (milestone 4 + кампания бинов + этап B:
   54.9% merged); далее — расширение merge-кампаний stall-режимами агента.
8. Кастомный report server и XML-лог (паттерн из лабы) — ВЫПОЛНЕНО
   (2026-11-19): `scr1_report_server` + `XML_LOG` knob + viewer, см.
   «Report server и XML-лог» выше.
9. Минимальные SVA в scr1_if / scr1_ahb_mem_if; sby-formal для листовых
   ячеек (опционально).
