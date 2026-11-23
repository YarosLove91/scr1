# ============================================================
# UVM verification environment for the SCR1 RISC-V core
#   Simulator: Verilator 5.x + uvm-verilator (UVM 1800.2)
#
#   tb/              - UVM testbench (interface, packages, top)
#   ../../src/       - SCR1 RTL (core + AHB top) and memory tb
#   ../../sim/tests/ - bare-metal test sources (hex vectors)
#   uvm-verilator/   - UVM library (cloned by: make uvm_download)
# ============================================================

CXX      := g++

# ------------------------------------------------------------
# Run parameters (overridable from the command line)
#   TEST    : scr1_smoke_test
#   SW_TEST : bare-metal test built as the vector (hello)
#   TEST_HEX: explicit vector path (skips the SW_TEST build)
#
# Configuration knobs (override the localparam defaults from
# tb/scr1_cfg_pkg.sv; passed as +define+SCR1_CFG_<NAME>=<value>
# only when set explicitly, any change triggers a rebuild):
#   RST_CYCLES     -> reset low duration (vector load)
#   TIMEOUT_CYCLES -> per-run watchdog
#   NUM_RUNS       -> program runs in the smoke test
#   SCB_LOG        -> detailed mismatch log cap
# ------------------------------------------------------------
CFG     ?= MAX
TEST    ?= scr1_smoke_test
SW_TEST ?= hello
VERBOSITY    ?= UVM_HIGH
# +UVM_NO_RELNOTES suppresses the UVM release-notes banner
SIM_PLUSARGS ?= +UVM_NO_RELNOTES

CFG_DEFINES :=
ifdef RST_CYCLES
  CFG_DEFINES += +define+SCR1_CFG_RST_CYCLES=$(RST_CYCLES)
endif
ifdef TIMEOUT_CYCLES
  CFG_DEFINES += +define+SCR1_CFG_TIMEOUT_CYCLES=$(TIMEOUT_CYCLES)
endif
ifdef NUM_RUNS
  CFG_DEFINES += +define+SCR1_CFG_NUM_RUNS=$(NUM_RUNS)
endif
ifdef SCB_LOG
  CFG_DEFINES += +define+SCR1_CFG_SCB_MAX_LOG=$(SCB_LOG)
endif
ifdef RTC_HALF
  CFG_DEFINES += +define+SCR1_CFG_RTC_HALF_PERIOD=$(RTC_HALF)
endif

# ------------------------------------------------------------
# Stage B: reactive AHB memory agent (replaces the legacy
# scr1_memory_tb_ahb with a UVM agent). DEFAULT since 2026-11-19
# after the parity campaign (hello/a5_1/isr_sample cycle-exact,
# stall matrix, fuzz lockstep); MEM_AGENT=0 keeps the legacy path
# bit-exact for comparisons. Compile-time flag - goes into the
# CFG stamp, any change triggers a rebuild.
# ------------------------------------------------------------
MEM_AGENT ?= 1
ifeq ($(MEM_AGENT),1)
  CFG_DEFINES += +define+SCR1_MEM_AGENT
endif

CFG_STRING := CFG=$(CFG) TEST=$(TEST) SW_TEST=$(SW_TEST) RST_CYCLES=$(RST_CYCLES) TIMEOUT_CYCLES=$(TIMEOUT_CYCLES) NUM_RUNS=$(NUM_RUNS) RTC_HALF=$(RTC_HALF) SPIKE_COSIM=$(SPIKE_COSIM) SPIKE_HOME=$(SPIKE_HOME) SPIKE_ROOT=$(SPIKE_ROOT) COV=$(COV) MEM_AGENT=$(MEM_AGENT)

NUM_THREADS := $(shell nproc 2>/dev/null || echo 4)
MAKEFLAGS += --no-print-directory

# ------------------------------------------------------------
# Paths. The DUT is referenced through the `dut` SYMLINK to the
# scr1 source tree (dut -> ../../src): this env keeps no copies
# of DUT files, so RTL edits by the design engineers flow into
# the env sources/build directly.
# ------------------------------------------------------------
SCR1_ROOT := $(abspath $(CURDIR)/../..)
DUT_DIR   := $(CURDIR)/dut
$(shell [ -L $(DUT_DIR) ] || ln -sfn ../../src $(DUT_DIR))

ifeq ($(CFG),MAX)
  CFG_DEFINES += +define+SCR1_CFG_RV32IMC_MAX
  SW_ARCH   := imc
  SW_TCM    := 1
  SW_IPIC   := 1
  SW_VECT_IRQ := 1
else ifeq ($(CFG),BASE)
  CFG_DEFINES += +define+SCR1_CFG_RV32IC_BASE
  SW_ARCH   := ic
  SW_TCM    := 1
  SW_IPIC   := 1
  SW_VECT_IRQ := 1
else ifeq ($(CFG),MIN)
  CFG_DEFINES += +define+SCR1_CFG_RV32EC_MIN
  SW_ARCH   := ec
  SW_TCM    := 1
  SW_IPIC   := 0
  SW_VECT_IRQ := 0
else
  $(error Unsupported CFG=$(CFG), use MAX/BASE/MIN)
endif

# Toolchain for the SW vector build (same convention as the
# scr1 root Makefile)
CROSS_PREFIX ?= riscv64-unknown-elf-
SW_ABI       := ilp32
SW_EXT_CFLAGS := $(if $(findstring c,$(SW_ARCH)),-D__RVC_EXT,)

# ------------------------------------------------------------
# RTL sources: native core/top file lists + the memory tb, all
# via the dut symlink (single source of truth = scr1 src tree)
# ------------------------------------------------------------
RTL_CORE := $(addprefix $(DUT_DIR)/,$(shell cat $(DUT_DIR)/core.files))
RTL_TOP  := $(addprefix $(DUT_DIR)/,$(shell cat $(DUT_DIR)/ahb_top.files))
MEM_TB   := $(DUT_DIR)/tb/scr1_memory_tb_ahb.sv
RTL_SRCS := $(RTL_CORE) $(RTL_TOP) $(MEM_TB)

# ------------------------------------------------------------
# UVM (uvm-verilator)
# ------------------------------------------------------------
VERILATOR   := verilator
UVM_DIR     ?= $(CURDIR)/uvm-verilator
UVM_REPO    := https://github.com/chipsalliance/uvm-verilator.git
UVM_MARKER  := .uvm_downloaded
UVM_DPI_SRC := $(UVM_DIR)/src/dpi/uvm_dpi.cc

TB_TOP    := scr1_tb_top
TB_DIR    := tb
RAL_DIR   := tb/ral
CORE_AGENT_DIR := tb/common/core_agent
MEM_AGENT_DIR := tb/common/mem_agent
IRQ_AGENT_DIR := tb/common/irq_agent
CSR_AGENT_DIR := tb/common/csr_agent
COSIM_AGENT_DIR := tb/common/cosim_agent
SEQ_DIR   := tb/env/sequence
ENV_DIR   := tb/env/environment
TEST_DIR  := tb/tests
SW_DIR    := sw
OUT_DIR   := uvm_out/$(CFG)
LOG_DIR   := logs
LOG       := $(LOG_DIR)/$(TEST).log

TEST_HEX ?= $(SW_DIR)/build/$(SW_TEST).hex

# ------------------------------------------------------------
# Differential mode (pattern 2A): golden commits from Spike
#   make run REF=1 SW_TEST=hello  -> tools/spike_log2csv.py
# SPIKE_BIN preference: tools/bin/spike (extracted from the
# scr1-spike-verif image via `make spike_extract`; a host riscv-isa-sim
# build without --no-dm overlaps RAM@0 with its debug module) ->
# spike in PATH -> $(SPIKE_ROOT)/build/spike.
REF        ?= 0
SPIKE_BIN  ?= $(if $(wildcard $(CURDIR)/tools/bin/spike),$(CURDIR)/tools/bin/spike,$(shell command -v spike 2>/dev/null || echo $(if $(SPIKE_ROOT),$(SPIKE_ROOT)/build/spike,spike)))
REF_CSV    := $(SW_DIR)/build/$(SW_TEST).spike.csv
REF_DEP    :=
ifeq ($(REF),1)
  SIM_PLUSARGS += +REF_CSV=$(REF_CSV)
  REF_DEP      := $(REF_CSV)
endif

$(REF_CSV): $(SW_DIR)/build/%.spike.csv: $(SW_DIR)/build/%.elf
	python3 tools/spike_log2csv.py --elf $< --out $@ --spike $(SPIKE_BIN) \
		--keep-log $(SW_DIR)/build/$*.spike_commits.log

# ------------------------------------------------------------
# In-process Spike via DPI-C (pattern 2B): lockstep reference.
# The DPI wrapper is co-located with the cosim agent that consumes
# it (ibex ibex_cosim_agent pattern):
# dv/uvm/tb/common/cosim_agent/spike_cosim_dpi.cc. Two link
# modes, NEITHER has a machine-specific default on purpose;
# SPIKE_HOME wins if both are given:
#   SPIKE_HOME=<install prefix> - shared-lib mode (preferred):
#     include/ + lib/libriscv.so (e.g. the prefix the C++-testbench
#     line uses, sim/tb_cpp_ahb/makefile.build_tb). Linked with
#     -Wl,-rpath so the binary loads the .so from that prefix at
#     runtime; libriscv.so also pulls host libboost_regex (its
#     DT_NEEDED). Example:
#       make run SPIKE_COSIM=1 SPIKE_HOME=<prefix> SW_TEST=hello
#   SPIKE_ROOT=<riscv-isa-sim checkout> - legacy static mode:
#     headers from the tree root + build/, static .a by full path
#     inside --start-group (-lriscv would pick libriscv.so from the
#     build tree and the binary then fails at load time - no rpath).
# Verilator puts -LDFLAGS content into LDLIBS (after the objects),
# so both the .a group and the -l chain resolve correctly.
# ------------------------------------------------------------
SPIKE_COSIM ?= 0
SPIKE_ROOT  ?=
SPIKE_HOME  ?=
DPI_SRCS    :=
CXXFLAGS_SPIKE :=
ifeq ($(SPIKE_COSIM),1)
  CFG_DEFINES    += +define+SCR1_SPIKE_COSIM
  DPI_SRCS       += $(COSIM_AGENT_DIR)/spike_cosim_dpi.cc
  SIM_PLUSARGS   += +SPIKE_HEX=$(TEST_HEX)
  ifneq ($(strip $(SPIKE_HOME)),)
    CXXFLAGS_SPIKE := -CFLAGS "-I$(SPIKE_HOME)/include"
    LDFLAGS += -L$(SPIKE_HOME)/lib -Wl,-rpath,$(SPIKE_HOME)/lib \
               -lriscv -lfesvr -ldisasm -lsoftfloat
  else ifneq ($(strip $(SPIKE_ROOT)),)
    CXXFLAGS_SPIKE := -CFLAGS "-I$(SPIKE_ROOT) -I$(SPIKE_ROOT)/build"
    SPIKE_LIBS := $(addprefix $(SPIKE_ROOT)/build/,libriscv.a libsoftfloat.a \
                  libfesvr.a libfdt.a libspike_dasm.a libdisasm.a)
    LDFLAGS += -Wl,--start-group $(SPIKE_LIBS) -Wl,--end-group
  else
    $(error SPIKE_COSIM=1 requires SPIKE_HOME=<install prefix with lib/libriscv.so> or SPIKE_ROOT=<riscv-isa-sim tree with built static libs>)
  endif
endif

# Extract the proven Spike binary (Oct master, with --no-dm) from the
# scr1-spike-verif docker image (no build, docker create/cp only)
.PHONY: spike_extract
spike_extract:
	@mkdir -p tools/bin
	@cid=$$(docker create scr1-spike-verif:latest); \
	docker cp $$cid:/opt/riscv/bin/spike tools/bin/spike; \
	docker rm $$cid > /dev/null; \
	chmod +x tools/bin/spike; \
	echo "spike extracted to tools/bin/spike ($$(tools/bin/spike --help 2>&1 | head -1))"

# Compilation units in dependency order:
# uvm_pkg -> cfg pkg -> interfaces -> common pkg (mem model +
# g_mem_model: the harness scr1_dut consumes the model through
# the package global, so the pkg compiles BEFORE the RTL) ->
# RTL -> dut harness -> ral pkg -> sequence pkg -> agent pkg ->
# mem agent pkg -> irq agent pkg -> csr agent pkg -> cosim agent pkg
# -> env pkg -> test pkg -> top;
# class files are `included into their packages
TB_PKG_SRCS := $(RAL_DIR)/scr1_csr_ral_pkg.sv \
               $(SEQ_DIR)/scr1_seq_pkg.sv \
               $(CORE_AGENT_DIR)/scr1_agent_pkg.sv \
               $(MEM_AGENT_DIR)/scr1_mem_agent_pkg.sv \
               $(IRQ_AGENT_DIR)/scr1_irq_agent_pkg.sv \
               $(CSR_AGENT_DIR)/scr1_csr_agent_pkg.sv \
               $(COSIM_AGENT_DIR)/scr1_cosim_agent_pkg.sv \
               $(ENV_DIR)/scr1_env_pkg.sv \
               $(TEST_DIR)/scr1_test_pkg.sv
TB_ALL      := $(wildcard $(TB_DIR)/*.sv) $(wildcard $(RAL_DIR)/*.sv*) \
                 $(wildcard $(TB_DIR)/common/*.sv) \
                 $(wildcard $(CORE_AGENT_DIR)/*.sv) \
                 $(wildcard $(MEM_AGENT_DIR)/*.sv) \
                  $(wildcard $(IRQ_AGENT_DIR)/*.sv) \
                  $(wildcard $(CSR_AGENT_DIR)/*.sv) \
                  $(wildcard $(COSIM_AGENT_DIR)/*.sv*) \
                 $(wildcard $(SEQ_DIR)/*.sv) \
                 $(wildcard $(ENV_DIR)/*.sv) $(wildcard $(TEST_DIR)/*.sv)

# ------------------------------------------------------------
# Linker auto-detection: mold -> lld -> gold -> system default
# ------------------------------------------------------------
LINKER ?= $(shell for l in mold lld gold; do \
            if command -v $$l >/dev/null 2>&1; then echo $$l; break; fi; \
          done)
ifneq ($(strip $(LINKER)),)
  LDFLAGS += -fuse-ld=$(LINKER)
  LINKER_DISPLAY := $(LINKER)
else
  LINKER_DISPLAY := (system default: bfd)
endif

TRACE_FLAGS :=
ifeq ($(TRACE),1)
  TRACE_FLAGS := --trace
  # keep the trace build isolated from the regular one
  OUT_DIR := uvm_out/$(CFG)_trace
endif

# Functional coverage (ibex fcov pattern, scr1_fcov_if covergroups)
COV ?= 0
COV_FLAGS :=
ifeq ($(COV),1)
  COV_FLAGS := --coverage-user
endif
# per-run coverage db suffix (vector name by default; dv/fuzz passes
# RUN_TAG=fuzz_<seed>); all logs/*.coverage.dat merge via 'make cov_merge'
RUN_TAG ?= $(SW_TEST)

# ------------------------------------------------------------
# AHB wait-state patterns (runtime plusargs, no rebuild needed):
# memory tb semantics: pattern == 0 -> RANDOM delays; otherwise
# bit[0] of the rotating pattern gates req_ack (FFFFFFFF = no
# stall, 55555555 = every other request stalled, ...)
# ------------------------------------------------------------
IMEM_PATTERN ?=
DMEM_PATTERN ?=
ifneq ($(IMEM_PATTERN),)
  SIM_PLUSARGS += +imem_pattern=$(IMEM_PATTERN)
endif
ifneq ($(DMEM_PATTERN),)
  SIM_PLUSARGS += +dmem_pattern=$(DMEM_PATTERN)
endif

# ------------------------------------------------------------
# Memory agent knobs (stage B, MEM_AGENT=1; runtime plusargs, no
# rebuild needed; the legacy IMEM/DMEM_PATTERN knobs are ignored
# by the agent - it has its own wait-state semantics):
#   AGENT_IMEM_STALL / AGENT_DMEM_STALL - N wait states (hready=0
#     clocks) per transfer address phase, 0 = off (legacy-parity
#     timing); AGENT_DMEM_ERROR_ADDR=<hex> - hresp ERROR injection
#     on the matching dmem word address (EC5/EC7 bins);
#     AGENT_IMEM_ERROR_ADDR=<hex> - hresp ERROR on the matching
#     imem FETCH word address (instruction access fault, EC1 bin;
#     pair with the sim/tests/fetch_fault vector)
# ------------------------------------------------------------
AGENT_IMEM_STALL ?=
AGENT_DMEM_STALL ?=
AGENT_DMEM_ERROR_ADDR ?=
AGENT_IMEM_ERROR_ADDR ?=
# Random wait states (task: random stall). AGENT_RANDOM_STALL=<max> (0/unset =
# off = deterministic bit-identical), AGENT_STALL_SEED=<n> (default 1, reproducible
# xorshift32), AGENT_RANDOM_STALL_CH=imem|dmem|both (default both). When set, the
# per-transfer address-phase delay is a deterministic 1..max instead of the fixed
# AGENT_<CH>_STALL (random overrides deterministic on the enabled channels).
AGENT_RANDOM_STALL ?=
AGENT_STALL_SEED ?=
AGENT_RANDOM_STALL_CH ?=
ifneq ($(AGENT_IMEM_STALL),)
  SIM_PLUSARGS += +AGENT_IMEM_STALL=$(AGENT_IMEM_STALL)
endif
ifneq ($(AGENT_DMEM_STALL),)
  SIM_PLUSARGS += +AGENT_DMEM_STALL=$(AGENT_DMEM_STALL)
endif
ifneq ($(AGENT_DMEM_ERROR_ADDR),)
  SIM_PLUSARGS += +AGENT_DMEM_ERROR_ADDR=$(AGENT_DMEM_ERROR_ADDR)
endif
ifneq ($(AGENT_IMEM_ERROR_ADDR),)
  SIM_PLUSARGS += +AGENT_IMEM_ERROR_ADDR=$(AGENT_IMEM_ERROR_ADDR)
endif
ifneq ($(AGENT_RANDOM_STALL),)
  SIM_PLUSARGS += +AGENT_RANDOM_STALL=$(AGENT_RANDOM_STALL)
endif
ifneq ($(AGENT_STALL_SEED),)
  SIM_PLUSARGS += +AGENT_STALL_SEED=$(AGENT_STALL_SEED)
endif
ifneq ($(AGENT_RANDOM_STALL_CH),)
  SIM_PLUSARGS += +AGENT_RANDOM_STALL_CH=$(AGENT_RANDOM_STALL_CH)
endif

# ------------------------------------------------------------
# Structured XML log (SNUG 2013 pattern, scr1_report_server):
# runtime plusarg, no rebuild needed. Every UVM report message
# is additionally written as a <msg> element (verbosity/severity/
# file/line/id/time/context) and report_summarize appends the
# <summary> verdict element:
#   XML_LOG=logs/scr1_log.xml   - write the XML log
#   make viewer XML_LOG=<path>  - GUI/CLI viewer (tools/)
# ------------------------------------------------------------
XML_LOG ?=
ifneq ($(XML_LOG),)
  SIM_PLUSARGS += +SCR1_XML_LOG=$(XML_LOG)
endif

# ------------------------------------------------------------
# IRQ-agent random multi-pulse scenario (runtime plusargs, no
# rebuild; pair with TEST=scr1_irq_test + the sim/tests/irq_stress
# vector). Unset/0 keeps the legacy single ext + single soft path
# bit-exact (irq_ext):
#   IRQ_RANDOM=<n>       n external pulses in the random series (>0 = on)
#   IRQ_SEED=<n>         RNG seed (same seed -> identical stimulus log)
#   IRQ_MASK_MODE=<m>    fixed9 | random16 | all16 (IPIC line masks)
#   IRQ_SOFT_GUAR=<0|1>  guaranteed-service concurrent soft pulse (default 1:
#                        the pulse spans the expected ext-drain window, so
#                        >=1 soft trap survives any ext storm; 0 = legacy
#                        narrow pulse which may expire unserviced)
# Legacy single-pulse timing overrides remain available:
#   IRQ_EXT_DELAY / IRQ_EXT_WIDTH / IRQ_SOFT_DELAY / IRQ_SOFT_WIDTH
# ------------------------------------------------------------
IRQ_RANDOM ?=
IRQ_SEED ?=
IRQ_MASK_MODE ?=
IRQ_SOFT_GUAR ?=
IRQ_EXT_DELAY ?=
IRQ_EXT_WIDTH ?=
IRQ_SOFT_DELAY ?=
IRQ_SOFT_WIDTH ?=
ifneq ($(IRQ_RANDOM),)
  SIM_PLUSARGS += +IRQ_RANDOM=$(IRQ_RANDOM)
endif
ifneq ($(IRQ_SEED),)
  SIM_PLUSARGS += +IRQ_SEED=$(IRQ_SEED)
endif
ifneq ($(IRQ_MASK_MODE),)
  SIM_PLUSARGS += +IRQ_MASK_MODE=$(IRQ_MASK_MODE)
endif
ifneq ($(IRQ_SOFT_GUAR),)
  SIM_PLUSARGS += +IRQ_SOFT_GUAR=$(IRQ_SOFT_GUAR)
endif
ifneq ($(IRQ_EXT_DELAY),)
  SIM_PLUSARGS += +IRQ_EXT_DELAY=$(IRQ_EXT_DELAY)
endif
ifneq ($(IRQ_EXT_WIDTH),)
  SIM_PLUSARGS += +IRQ_EXT_WIDTH=$(IRQ_EXT_WIDTH)
endif
ifneq ($(IRQ_SOFT_DELAY),)
  SIM_PLUSARGS += +IRQ_SOFT_DELAY=$(IRQ_SOFT_DELAY)
endif
ifneq ($(IRQ_SOFT_WIDTH),)
  SIM_PLUSARGS += +IRQ_SOFT_WIDTH=$(IRQ_SOFT_WIDTH)
endif

BIN := $(OUT_DIR)/V$(TB_TOP)

VFLAGS := \
	--binary \
	--timing \
	--vpi \
	-j $(NUM_THREADS) \
	-Wno-fatal \
	-Wno-DECLFILENAME \
	-Wno-UNUSED \
	-Wno-WIDTHTRUNC \
	-Wno-WIDTHCONCAT \
	-Wno-UNSIGNED \
	-Wno-CASEINCOMPLETE \
	-Wno-TIMESCALEMOD \
	-Wno-PINMISSING \
	-Wno-MULTIDRIVEN \
	$(TRACE_FLAGS) \
	$(COV_FLAGS) \
	$(CFG_DEFINES) \
	+define+SCR1_TRGT_SIMULATION \
	+incdir+$(UVM_DIR)/src \
	+incdir+$(DUT_DIR)/includes \
	+incdir+$(DUT_DIR)/tb \
	+incdir+$(TB_DIR) \
	+incdir+$(RAL_DIR) \
	+incdir+$(CORE_AGENT_DIR) \
	+incdir+$(MEM_AGENT_DIR) \
	+incdir+$(IRQ_AGENT_DIR) \
	+incdir+$(CSR_AGENT_DIR) \
	+incdir+$(COSIM_AGENT_DIR) \
	+incdir+$(SEQ_DIR) \
	+incdir+$(ENV_DIR) \
	+incdir+$(TEST_DIR) \
	--top-module $(TB_TOP) \
	--Mdir $(OUT_DIR) \
	$(if $(strip $(LDFLAGS)),-LDFLAGS "$(LDFLAGS)",)

# ------------------------------------------------------------
# Colored console verdicts (default behavior)
#   green "TEST SUCCESFULLY PASS !" / red "TEST FAILURE !"
# ------------------------------------------------------------
CLR_PASS := \033[1;32m
CLR_FAIL := \033[1;31m
CLR_OFF  := \033[0m

define clr
	if [ -t 1 ] && [ -z "$$NO_COLOR" ]; then C='$(1)'; R='$(CLR_OFF)'; else C=''; R=''; fi
endef

# ------------------------------------------------------------
# Targets
# ------------------------------------------------------------
.PHONY: all build run smoke hex waves viewer test clean distclean cov_merge \
        FORCE uvm_download list help

# Regression targets fan out to sub-makes sharing one OUT_DIR;
# serialize to avoid concurrent Verilator builds into the same --Mdir
.NOTPARALLEL:

all: run

uvm_download: $(UVM_MARKER)

$(UVM_MARKER):
	@if [ ! -d "$(UVM_DIR)" ]; then \
		echo ">>> [uvm] Cloning uvm-verilator..."; \
		git clone --depth 1 $(UVM_REPO) $(UVM_DIR); \
	fi
	@touch $@

# ------------------------------------------------------------
# SW vector: build $(SW_TEST).hex from ../../sim/tests (the same
# bare-metal sources and link scripts as the native flow)
# ------------------------------------------------------------
hex: $(TEST_HEX)

$(SW_DIR)/build/%.hex: FORCE
	@mkdir -p $(SW_DIR)/build
	@echo ">>> [sw] building $* ($(SCR1_ROOT)/sim/tests/$*)"
	$(MAKE) -C $(SCR1_ROOT)/sim/tests/$* \
		bld_dir=$(CURDIR)/$(SW_DIR)/build \
		inc_dir=$(SCR1_ROOT)/sim/tests/common \
		ARCH=$(SW_ARCH) ABI=$(SW_ABI) TCM=$(SW_TCM) \
		IPIC=$(SW_IPIC) VECT_IRQ=$(SW_VECT_IRQ) \
		EXT_CFLAGS="$(SW_EXT_CFLAGS)" \
		CROSS_PREFIX="$(CROSS_PREFIX)" \
		RISCV_GCC="$(CROSS_PREFIX)gcc" \
		RISCV_OBJCOPY="$(CROSS_PREFIX)objcopy -O verilog" \
		RISCV_OBJDUMP="$(CROSS_PREFIX)objdump -D"

build: $(BIN)

# Config stamp: rewritten (triggering a rebuild) only when the
# effective knob set changes; file edits are covered by TB_ALL
CFG_STAMP := $(OUT_DIR)/.cfg_stamp

$(CFG_STAMP): FORCE
	@mkdir -p $(OUT_DIR)
	@echo "$(CFG_STRING) TRACE=$(TRACE)" > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm -f $@.tmp; else mv $@.tmp $@; fi

$(BIN): $(UVM_MARKER) $(TB_ALL) $(RTL_SRCS) $(wildcard $(COSIM_AGENT_DIR)/*.cc) $(CFG_STAMP) $(firstword $(MAKEFILE_LIST))
	@mkdir -p $(OUT_DIR) $(LOG_DIR)
	@echo ">>> [build] $(CFG_STRING) jobs=$(NUM_THREADS) ld=$(LINKER_DISPLAY)"
	$(VERILATOR) $(VFLAGS) \
		$(UVM_DIR)/src/uvm_pkg.sv \
		$(TB_DIR)/scr1_cfg_pkg.sv \
		$(TB_DIR)/scr1_irq_cfg_pkg.sv \
		$(TB_DIR)/common/core_agent/scr1_if.sv \
		$(TB_DIR)/common/mem_agent/scr1_ahb_mem_if.sv \
		$(TB_DIR)/common/irq_agent/scr1_irq_if.sv \
		$(TB_DIR)/common/scr1_commit_if.sv \
		$(MEM_AGENT_DIR)/scr1_mem_model_pkg.sv \
		$(TB_DIR)/scr1_tb_pkg.sv \
		$(RTL_SRCS) \
		$(TB_DIR)/scr1_commit_probe.sv \
		$(TB_DIR)/scr1_state_probe.sv \
		$(TB_DIR)/scr1_dut.sv \
		$(TB_DIR)/scr1_fcov_if.sv \
		$(TB_DIR)/scr1_bind.sv \
		$(TB_PKG_SRCS) \
		$(TB_DIR)/scr1_tb_top.sv \
		$(UVM_DPI_SRC) \
		$(DPI_SRCS) \
		-CFLAGS "-std=c++17" $(CXXFLAGS_SPIKE)

# The vector is built only when the default TEST_HEX layout is
# used (an explicit TEST_HEX= skips the sw build)
ifeq ($(TEST_HEX),$(SW_DIR)/build/$(SW_TEST).hex)
run: build hex $(REF_DEP)
else
run: build $(REF_DEP)
endif

run:
	@mkdir -p $(LOG_DIR)
	@echo ">>> [run] TEST=$(TEST) vector=$(TEST_HEX)"
	-$(BIN) +UVM_TESTNAME=$(TEST) \
		+UVM_VERBOSITY=$(VERBOSITY) \
		+SCR1_TEST_HEX=$(TEST_HEX) \
		$(SIM_PLUSARGS) 2>&1 | tee $(LOG)
	@if grep -q "SCR1_RESULT: PASS" $(LOG); then \
		$(call clr,$(CLR_PASS)); \
		printf "$$C>>> TEST SUCCESFULLY PASS !$$R (%s)\n" "$(LOG)"; \
	else \
		$(call clr,$(CLR_FAIL)); \
		printf "$$C>>> TEST FAILURE !$$R (%s)\n" "$(LOG)"; \
		exit 1; \
	fi
	@if [ "$(COV)" = "1" ] && [ -f coverage.dat ]; then \
		mkdir -p $(LOG_DIR); \
		mv coverage.dat $(LOG_DIR)/$(TEST).$(RUN_TAG).coverage.dat; \
		rm -rf $(LOG_DIR)/$(TEST).$(RUN_TAG)_cov; \
		verilator_coverage --annotate $(LOG_DIR)/$(TEST).$(RUN_TAG)_cov \
			$(LOG_DIR)/$(TEST).$(RUN_TAG).coverage.dat | tail -10; \
		echo ">>> Coverage: $(LOG_DIR)/$(TEST).$(RUN_TAG).coverage.dat"; \
	fi

# Merge every logs/*.coverage.dat (multi-run/multi-seed regression) and
# annotate the merged database (ibex merge_cov.py pattern, native tool)
cov_merge:
	@mkdir -p $(LOG_DIR)
	verilator_coverage --write $(LOG_DIR)/merged.coverage.dat $(LOG_DIR)/*.coverage.dat
	rm -rf $(LOG_DIR)/merged_cov
	verilator_coverage --annotate $(LOG_DIR)/merged_cov $(LOG_DIR)/merged.coverage.dat | tail -10
	@echo ">>> Merged coverage: $(LOG_DIR)/merged.coverage.dat -> $(LOG_DIR)/merged_cov/"

# single run with VCD dump (TRACE=1 rebuilds into a separate dir)
waves:
	@$(MAKE) run TRACE=1
	@echo ">>> Waves: $(LOG_DIR)/waves.vcd (gtkwave $(LOG_DIR)/waves.vcd)"

# interactive XML log viewer (SNUG 2013): run first with XML_LOG=...
viewer:
	python3 tools/scr1_log_viewer.py $(if $(XML_LOG),$(XML_LOG),$(LOG_DIR)/scr1_log.xml)

smoke:
	@$(MAKE) run TEST=scr1_smoke_test

test: smoke
	@$(call clr,$(CLR_PASS)); \
	printf "$$C>>> REGRESSION test: TEST SUCCESFULLY PASS !$$R\n"

clean:
	@rm -rf uvm_out $(LOG_DIR) *.vcd $(SW_DIR)/build

distclean: clean
	@rm -rf $(UVM_DIR) $(UVM_MARKER)

list:
	@echo "CFG        : $(CFG)"
	@echo "TEST       : $(TEST)"
	@echo "CFG_STRING : $(CFG_STRING)"
	@echo "TEST_HEX   : $(TEST_HEX)"
	@echo "BIN        : $(BIN)"
	@echo "LD         : $(LINKER_DISPLAY)"
	@echo "VERILATOR  : $(shell $(VERILATOR) --version)"

help:
	@echo "UVM verification environment for the SCR1 core (Verilator)"
	@echo ""
	@echo "Quick start:"
	@echo "  make uvm_download        - clone uvm-verilator (once)"
	@echo "  make smoke CROSS_PREFIX=<riscv-none-elf->  - build hello.hex + run scr1_smoke_test"
	@echo "  make run TEST=<test> [SW_TEST=<t>|TEST_HEX=<hex>]"
	@echo ""
	@echo "  TEST: scr1_smoke_test"
	@echo "  SW_TEST: hello | isr_sample | a5_1 | fern | conway | mcycle ..."
	@echo ""
	@echo "Configuration knobs (override localparam defaults from"
	@echo "tb/scr1_cfg_pkg.sv; unset knobs use the file defaults):"
	@echo "  RST_CYCLES=<n>      reset low duration (vector load)"
	@echo "  TIMEOUT_CYCLES=<n>  per-run watchdog"
	@echo "  NUM_RUNS=<n>        program runs in the smoke test"
	@echo "  SCB_LOG=<n>         detailed mismatch log cap"
	@echo "  RTC_HALF=<ns>       rtc_clk half period (5 = native-equivalent, 500 = real 1 MHz)"
	@echo "  MEM_AGENT=0         legacy scr1_memory_tb_ahb instead of the"
	@echo "                      reactive UVM AHB memory agent (compile-time;"
	@echo "                      default 1 = agent)"
	@echo ""
	@echo "Memory agent runtime knobs (MEM_AGENT=1, plusargs, no rebuild):"
	@echo "  AGENT_IMEM_STALL=<n>       imem wait states per transfer (0 = off)"
	@echo "  AGENT_DMEM_STALL=<n>       dmem wait states per transfer (0 = off)"
	@echo "  AGENT_DMEM_ERROR_ADDR=<hex> hresp ERROR injection on the dmem word"
	@echo "  AGENT_IMEM_ERROR_ADDR=<hex> hresp ERROR on the imem FETCH word (EC1,"
	@echo "                             pair with SW_TEST=fetch_fault)"
	@echo "  AGENT_RANDOM_STALL=<max>   random 1..max wait states per transfer"
	@echo "                             (0/unset = off; overrides the deterministic"
	@echo "                             knobs on the enabled channels)"
	@echo "  AGENT_STALL_SEED=<n>       stall PRNG seed (default 1; same seed = same"
	@echo "                             cycle counts - reproducible runs)"
	@echo "  AGENT_RANDOM_STALL_CH=<c>  imem | dmem | both (default both)"
	@echo ""
	@echo "Sequencer side-channel demos (MEM_AGENT=1, runtime plusargs):"
	@echo "  make run TEST=scr1_seq_inject_test  - sequence ERROR injection demo"
	@echo "                             (pair vector: make -C ../fuzz seq_inject;"
	@echo "                             +SEQ_INJECT_ADDR/COUNT/IMEM overrides)"
	@echo "  make run TEST=scr1_seq_delay_test   - sequence rdelay wait-state"
	@echo "                             modulation demo (default: all dmem, 0..3;"
	@echo "                             overrides via SIM_PLUSARGS: +SEQ_DELAY_MIN/"
	@echo "                             MAX/CH/LO/HI/COUNT; +SEQ_DELAY_DISABLE=1 ="
	@echo "                             plain-run control, exactly the parity count)"
	@echo ""
	@echo "IRQ-agent random scenario (TEST=scr1_irq_test + SW_TEST=irq_stress):"
	@echo "  IRQ_RANDOM=<n>       n external pulses (>0 enables the random series;"
	@echo "                       unset/0 keeps the legacy single ext+soft path)"
	@echo "  IRQ_SEED=<n>         RNG seed (same seed -> identical stimulus log;"
	@echo "                       NUM_RUNS>1: run i uses seed+i)"
	@echo "  IRQ_MASK_MODE=<m>    fixed9 | random16 | all16 (IPIC line masks)"
	@echo "  IRQ_SOFT_GUAR=<0|1>  guaranteed-service concurrent soft pulse (default 1:"
	@echo "                       spans the expected ext-drain window; 0 = legacy"
	@echo "                       narrow pulse, may expire unserviced in a storm)"
	@echo "  example: make run TEST=scr1_irq_test SW_TEST=irq_stress \\"
	@echo "             IRQ_RANDOM=6 IRQ_SEED=1 IRQ_MASK_MODE=random16"
	@echo ""
	@echo "Report server (runtime plusarg, no rebuild):"
	@echo "  XML_LOG=<path>             structured XML log (+SCR1_XML_LOG): every"
	@echo "                             UVM message as a <msg> element + <summary>"
	@echo "                             verdict (scr1_report_server, SNUG 2013)"
	@echo ""
	@echo "Misc:"
	@echo "  make waves TEST=...      - run with VCD dump (logs/waves.vcd)"
	@echo "  make viewer XML_LOG=<path> - XML log GUI/CLI viewer (SNUG 2013)"
	@echo "  make list                - print variables"
	@echo "  make clean / distclean   - cleanup (distclean removes uvm-verilator)"
