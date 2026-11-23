# ============================================================
# SCR1 fuzz flow: riscv-dv (pygen) random programs -> SCR1 UVM
# environment (dv/uvm) with in-process Spike lockstep (2B).
#
#   make venv                 - python3.11 venv with pygen deps (once)
#   make fuzz SEED=42         - gen -> patch -> gcc -> hex -> UVM run
#   make gen/patch/elf/hex    - individual stages
#   make fuzz UVM_TEST=scr1_smoke_test SPIKE_COSIM=0 - no cosim
#
# The riscv-dv generator lives in the riscv-dv/ submodule
# (git submodule update --init). The SCR1 target is a pygen
# namespace-package overlay (pygen_ext/pygen_src/target/scr1) -
# the submodule is never modified.
# ============================================================

RISCV_DV_ROOT ?= $(CURDIR)/riscv-dv
PYGEN_EXT     := $(CURDIR)/pygen_ext
SCR1_TARGET   := $(PYGEN_EXT)/pygen_src/target/scr1

# Python venv with the pygen dependencies (created by: make venv)
VENV ?= $(CURDIR)/.venv
PY   := $(VENV)/bin/python3

# Toolchain / generation knobs (same convention as the scr1 root Makefile:
# pass CROSS_PREFIX=<path-to>/riscv-none-elf- or have it on PATH)
CROSS_PREFIX ?= riscv64-unknown-elf-
MARCH ?= rv32imc_zicsr_zifencei
MABI  ?= ilp32
SPIKE_COSIM ?= 1

TARGET_NAME ?= scr1
TEST ?= riscv_arithmetic_basic_test
SEED ?= 1
STACK_MAX ?= 1000
UVM_TEST ?= scr1_csr_test
# CSR body injection (patch_asm.py transform 4): pygen master emits no CSR
# instructions in the random body (enum-vs-string bug in
# build_basic_instruction_list, see the patch_asm docstring), so the
# riscv_csr_rand_test gets N random whitelist-safe CSR instructions
# injected at patch time (deterministic per SEED). Override: CSR_INJECT=<n>.
ifeq ($(TEST),riscv_csr_rand_test)
CSR_INJECT ?= 12
else
CSR_INJECT ?= 0
endif
# functional coverage passthrough (dv/uvm COV/RUN_TAG)
COV ?= 0
# riscv-isa-sim tree with built static libs - required for SPIKE_COSIM=1
# (no machine-specific default on purpose). SPIKE_HOME (installed prefix
# with lib/libriscv.so, shared-lib link mode) is an alternative and WINS
# over SPIKE_ROOT when both are set - see dv/uvm/Makefile.
SPIKE_ROOT ?=
SPIKE_HOME ?=

WORK     ?= $(CURDIR)/work
SEED_DIR := $(WORK)/seed_$(SEED)
GEN_DIR  := $(SEED_DIR)/gen
ASM_RAW  := $(SEED_DIR)/$(TEST)_$(SEED).S
ASM      := $(SEED_DIR)/$(TEST)_$(SEED).scr1.S
ELF      := $(SEED_DIR)/$(TEST)_$(SEED).elf
HEX      := $(SEED_DIR)/$(TEST)_$(SEED).hex

# pygen resolves the target as pygen_src.target.$(TARGET_NAME);
# pygen_ext (namespace-package overlay) must precede the submodule pygen
export PYTHONPATH := $(PYGEN_EXT):$(RISCV_DV_ROOT)/pygen

# ------------------------------------------------------------
# Seed regression (riscv-core-dv-uvm scripts/ pattern):
# NUM_SEEDS random seeds, each through the full fuzz flow, per-seed
# logs in work/seed_<n>/run.log, summary table + exit code at the end.
# PRESERVE_SEEDS=1 reuses the existing work/seeds.txt (rerun of the
# same seed set, e.g. after an RTL change).
# ------------------------------------------------------------
NUM_SEEDS ?= 4
SEED_FILE := $(WORK)/seeds.txt

# ------------------------------------------------------------
# Mixed stall profiles for regress (optional): MIXED_STALL=1
# alternates the seed set between the plain lockstep profile
# (odd positions: AGENT_RANDOM_STALL=0) and random wait states
# (even positions: AGENT_RANDOM_STALL=$(MIXED_STALL_MAX),
# AGENT_STALL_SEED=$(MIXED_STALL_SEED)). The per-seed assignment
# is passed on the sub-make command line, so it WINS over a
# globally passed AGENT_RANDOM_STALL; the summarize.py stall
# column shows the per-seed profile. Lockstep is timing-invariant,
# so both profiles must PASS identically (commit counts may drop
# slightly under stalls: exit-spin tail outside the drain window).
# ------------------------------------------------------------
MIXED_STALL ?= 0
MIXED_STALL_MAX ?= 2
MIXED_STALL_SEED ?= 7

.PHONY: all fuzz gen patch elf hex run clean venv submodule regress seeds cov_isa cov_directed seq_inject help

all: fuzz

fuzz: hex run

seeds:
	@mkdir -p $(WORK)
	@if [ -n "$(PRESERVE_SEEDS)" ] && [ -f $(SEED_FILE) ]; then \
		echo "PRESERVE_SEEDS: reusing $(SEED_FILE) ($$(wc -l < $(SEED_FILE)) seeds)"; \
	else \
		$(VENV)/bin/python3 tools/gen_seeds.py $(NUM_SEEDS) --seed-file $(SEED_FILE) > /dev/null; \
		echo "generated $(NUM_SEEDS) seeds -> $(SEED_FILE)"; \
	fi

regress: seeds
	@i=0; for s in $$(cat $(SEED_FILE)); do \
		i=$$((i+1)); \
		stall=""; \
		if [ "$(MIXED_STALL)" = "1" ]; then \
			if [ $$((i % 2)) -eq 0 ]; then \
				stall="AGENT_RANDOM_STALL=$(MIXED_STALL_MAX) AGENT_STALL_SEED=$(MIXED_STALL_SEED)"; \
			else \
				stall="AGENT_RANDOM_STALL=0"; \
			fi; \
		fi; \
		mkdir -p $(WORK)/seed_$$s; \
		echo "=== [regress] seed $$s: $(TEST) $$stall ==="; \
		$(MAKE) fuzz SEED=$$s $$stall > $(WORK)/seed_$$s/run.log 2>&1 \
			&& echo "  seed $$s: PASS" \
			|| echo "  seed $$s: FAIL (log: $(WORK)/seed_$$s/run.log)"; \
	done; \
	$(VENV)/bin/python3 tools/summarize.py --work-dir $(WORK)

# ------------------------------------------------------------
# venv with pygen deps (python3.11; pyvsc/pyboolector pins from
# riscv-dv requirements.txt - the pyboolector pin matters: the
# generic PyBoolector lacks BTOR_OPT_INCREMENTAL used by pyvsc)
# ------------------------------------------------------------
venv:
	python3.11 -m venv $(VENV)
	$(VENV)/bin/pip install pyvsc==0.9.1.10086043874 \
		pyboolector==3.2.4.20240823.1 bitstring PyYAML tabulate "pandas<=2.2.3"

submodule:
	git -C $(CURDIR)/../.. submodule update --init scr1/dv/fuzz/riscv-dv

# ------------------------------------------------------------
# Stages
# ------------------------------------------------------------
gen: $(ASM_RAW)

$(ASM_RAW):
	@mkdir -p $(GEN_DIR)/asm_test
	cd $(GEN_DIR) && PATH=$(VENV)/bin:$$PATH $(PY) $(RISCV_DV_ROOT)/run.py \
		--custom_target $(SCR1_TARGET) \
		--test $(TEST) --target $(TARGET_NAME) --isa rv32imc \
		--simulator pyflow --steps gen --iterations 1 --seed $(SEED)
	mv $$(ls -d $(GEN_DIR)/out_*/asm_test/$(TEST)_0.S | head -1) $(ASM_RAW)

patch: $(ASM)

$(ASM): $(ASM_RAW) tools/patch_asm.py
	$(VENV)/bin/python3 tools/patch_asm.py --in $(ASM_RAW) --out $(ASM) \
		--stack-max $(STACK_MAX) \
		--csr-inject $(CSR_INJECT) --csr-seed $(SEED)

elf: $(ELF)

$(ELF): $(ASM) $(SCR1_TARGET)/link.ld
	$(CROSS_PREFIX)gcc -march=$(MARCH) -mabi=$(MABI) \
		-static -mcmodel=medany -fvisibility=hidden \
		-nostdlib -nostartfiles -mno-relax \
		-I$(RISCV_DV_ROOT)/user_extension \
		-T $(SCR1_TARGET)/link.ld \
		$(ASM) -o $(ELF)
	$(CROSS_PREFIX)objdump -D $(ELF) > $(SEED_DIR)/$(TEST)_$(SEED).dump

hex: $(HEX)

$(HEX): $(ELF)
	$(CROSS_PREFIX)objcopy -O verilog $(ELF) $(HEX)

# ------------------------------------------------------------
# UVM run with the in-process Spike lockstep (dv/uvm milestone 2B).
# The stage A loader takes a full SV string path, so the vector is
# passed as an absolute path directly (no short-name copy needed).
# ------------------------------------------------------------

# AHB wait-state patterns passthrough (dv/uvm runtime plusargs;
# empty = no plusarg = tb default FFFFFFFF; 0 = random stalls)
IMEM_PATTERN ?=
DMEM_PATTERN ?=

# Reactive memory agent passthrough (dv/uvm stage B):
# MEM_AGENT=1 (default since 2026-11-19) replaces the legacy memory tb
# with the UVM agent; AGENT_* are its runtime knobs (wait states /
# ERROR injection, dmem AND imem)
MEM_AGENT ?= 1
AGENT_IMEM_STALL ?=
AGENT_DMEM_STALL ?=
AGENT_DMEM_ERROR_ADDR ?=
AGENT_IMEM_ERROR_ADDR ?=
# Random wait states passthrough (dv/uvm task: random stall). AGENT_RANDOM_STALL=0/
# unset = deterministic bit-identical lockstep; >0 = per-transfer 1..max from a
# reproducible xorshift32 (AGENT_STALL_SEED). The fuzz lockstep must stay intact
# under random stalls (that is the whole point: timing-invariant commit stream).
AGENT_RANDOM_STALL ?=
AGENT_STALL_SEED ?=
AGENT_RANDOM_STALL_CH ?=

run: $(HEX)
	$(MAKE) -C $(CURDIR)/../uvm run TEST=$(UVM_TEST) \
		TEST_HEX=$(abspath $(HEX)) SPIKE_COSIM=$(SPIKE_COSIM) \
		SPIKE_ROOT=$(SPIKE_ROOT) SPIKE_HOME=$(SPIKE_HOME) \
		COV=$(COV) RUN_TAG=fuzz_$(SEED) \
		IMEM_PATTERN=$(IMEM_PATTERN) DMEM_PATTERN=$(DMEM_PATTERN) \
		MEM_AGENT=$(MEM_AGENT) \
		AGENT_IMEM_STALL=$(AGENT_IMEM_STALL) \
		AGENT_DMEM_STALL=$(AGENT_DMEM_STALL) \
		AGENT_DMEM_ERROR_ADDR=$(AGENT_DMEM_ERROR_ADDR) \
		AGENT_IMEM_ERROR_ADDR=$(AGENT_IMEM_ERROR_ADDR) \
		AGENT_RANDOM_STALL=$(AGENT_RANDOM_STALL) \
		AGENT_STALL_SEED=$(AGENT_STALL_SEED) \
		AGENT_RANDOM_STALL_CH=$(AGENT_RANDOM_STALL_CH) \
		CROSS_PREFIX=$(CROSS_PREFIX)

# ------------------------------------------------------------
# Directed coverage vector (sw_directed/scr1_cov_directed.S):
# fence/fence.i, ecall/ebreak/c.ebreak, misaligned lw/sw/jr with
# a self-contained trap handler. Runs WITHOUT Spike lockstep:
# Spike executes misaligned accesses natively and would diverge
# (SCR1 traps: scr1_pipe_lsu.sv LD/ST_ADDR_MISALIGN).
# ------------------------------------------------------------
DIR_SRC ?= sw_directed/scr1_cov_directed.S
DIR_DIR := $(WORK)/directed
DIR_ELF := $(DIR_DIR)/scr1_cov_directed.elf
DIR_HEX := $(DIR_DIR)/scr1_cov_directed.hex

cov_directed: $(DIR_HEX)
	$(MAKE) -C $(CURDIR)/../uvm run TEST=$(UVM_TEST) \
		TEST_HEX=$(abspath $(DIR_HEX)) SPIKE_COSIM=0 \
		COV=$(COV) RUN_TAG=directed \
		IMEM_PATTERN=$(IMEM_PATTERN) DMEM_PATTERN=$(DMEM_PATTERN) \
		MEM_AGENT=$(MEM_AGENT) \
		AGENT_IMEM_STALL=$(AGENT_IMEM_STALL) \
		AGENT_DMEM_STALL=$(AGENT_DMEM_STALL) \
		AGENT_DMEM_ERROR_ADDR=$(AGENT_DMEM_ERROR_ADDR) \
		AGENT_IMEM_ERROR_ADDR=$(AGENT_IMEM_ERROR_ADDR) \
		AGENT_RANDOM_STALL=$(AGENT_RANDOM_STALL) \
		AGENT_STALL_SEED=$(AGENT_STALL_SEED) \
		AGENT_RANDOM_STALL_CH=$(AGENT_RANDOM_STALL_CH) \
		CROSS_PREFIX=$(CROSS_PREFIX)

$(DIR_ELF): $(DIR_SRC) $(SCR1_TARGET)/link.ld
	@mkdir -p $(DIR_DIR)
	$(CROSS_PREFIX)gcc -march=$(MARCH) -mabi=$(MABI) \
		-static -mcmodel=medany -fvisibility=hidden \
		-nostdlib -nostartfiles -mno-relax \
		-T $(SCR1_TARGET)/link.ld $(DIR_SRC) -o $(DIR_ELF)
	$(CROSS_PREFIX)objdump -D $(DIR_ELF) > $(DIR_DIR)/scr1_cov_directed.dump

$(DIR_HEX): $(DIR_ELF)
	$(CROSS_PREFIX)objcopy -O verilog $(DIR_ELF) $(DIR_HEX)

# ------------------------------------------------------------
# Sequence-driven mem ERROR injection demo (dv/uvm scr1_seq_inject_test):
# directed vector sw_directed/scr1_seq_inject.S stores to the console and
# carries a trap handler; the test arms hresp ERROR on the console word
# address THROUGH A SEQUENCE (mem-agent injection sequencer), so the console
# stores fault (mcause=7), the handler skips them and the run exits a0=0.
# Runs WITHOUT Spike lockstep (the 2B model does not model console ERROR).
# Injection target/count default to the console / 4; override at run time by
# appending +SEQ_INJECT_ADDR=<hex> / +SEQ_INJECT_COUNT=<n> to SIM_PLUSARGS.
# ------------------------------------------------------------
SEQ_SRC ?= sw_directed/scr1_seq_inject.S
SEQ_DIR := $(WORK)/seq_inject
SEQ_ELF := $(SEQ_DIR)/scr1_seq_inject.elf
SEQ_HEX := $(SEQ_DIR)/scr1_seq_inject.hex

seq_inject: $(SEQ_HEX)
	$(MAKE) -C $(CURDIR)/../uvm run TEST=scr1_seq_inject_test \
		TEST_HEX=$(abspath $(SEQ_HEX)) SPIKE_COSIM=0 \
		COV=$(COV) RUN_TAG=seq_inject \
		MEM_AGENT=$(MEM_AGENT) \
		AGENT_IMEM_STALL=$(AGENT_IMEM_STALL) \
		AGENT_DMEM_STALL=$(AGENT_DMEM_STALL) \
		AGENT_RANDOM_STALL=$(AGENT_RANDOM_STALL) \
		AGENT_STALL_SEED=$(AGENT_STALL_SEED) \
		AGENT_RANDOM_STALL_CH=$(AGENT_RANDOM_STALL_CH) \
		CROSS_PREFIX=$(CROSS_PREFIX)

$(SEQ_ELF): $(SEQ_SRC) $(SCR1_TARGET)/link.ld
	@mkdir -p $(SEQ_DIR)
	$(CROSS_PREFIX)gcc -march=$(MARCH) -mabi=$(MABI) \
		-static -mcmodel=medany -fvisibility=hidden \
		-nostdlib -nostartfiles -mno-relax \
		-T $(SCR1_TARGET)/link.ld $(SEQ_SRC) -o $(SEQ_ELF)
	$(CROSS_PREFIX)objdump -D $(SEQ_ELF) > $(SEQ_DIR)/scr1_seq_inject.dump

$(SEQ_HEX): $(SEQ_ELF)
	$(CROSS_PREFIX)objcopy -O verilog $(SEQ_ELF) $(SEQ_HEX)

# ------------------------------------------------------------
# riscv-dv AUTOGENERATED ISA coverage (the ibex get_fcov.py
# approach): spike logs -> trace CSV -> riscv_instr_cov_test
# (per-instruction pyvsc covergroups generated from the ISA
# registry of the scr1 target). ELFS="..." overrides the default
# set (work/seed_*/*.elf).
# ------------------------------------------------------------
SPIKE_BIN  ?= $(if $(wildcard $(CURDIR)/../uvm/tools/bin/spike),$(CURDIR)/../uvm/tools/bin/spike,$(shell command -v spike 2>/dev/null || echo spike))
COV_LOGS_DIR := $(WORK)/cov_logs
COV_OUT      := $(WORK)/cov

cov_isa:
	@mkdir -p $(COV_LOGS_DIR)
	@elfs="$(or $(ELFS),$(wildcard $(WORK)/seed_*/*.elf))"; \
	if [ -z "$$elfs" ]; then echo "no ELF vectors found (run make fuzz first or pass ELFS=...)"; exit 1; fi; \
	for elf in $$elfs; do \
		n=$$(basename $$elf .elf); \
		echo ">>> [cov_isa] spike log: $$n"; \
		$(VENV)/bin/python3 ../uvm/tools/spike_log2csv.py --elf $$elf \
			--out $(COV_LOGS_DIR)/$$n.csv --spike $(SPIKE_BIN) \
			--keep-log $(COV_LOGS_DIR)/$$n.log > /dev/null || exit 1; \
	done
	# riscv-dv's spike converter is an FSM waiting for the classic boot-ROM
	# trampoline end marker at pc 0x1010; we boot with --disable-dtb
	# --pc=0x200 and never pass 0x1010, so prepend the marker line
	# (the converter consumes it and yields no entry for it)
	@for lg in $(COV_LOGS_DIR)/*.log; do \
		sed -i '1i core   0: 0x00001010 (0x00000013) trampoline-end-marker' $$lg; \
	done
	rm -f $(COV_LOGS_DIR)/*.csv
	# NB: paths are RELATIVE to $(WORK): riscv_instr_cov_test derives the
	# report dir as log_file_name.split("/")[0], which breaks on absolute
	# paths (empty -> '/CoverageReport.txt' PermissionError)
	cd $(WORK) && PATH=$(VENV)/bin:$$PATH \
		PYTHONPATH=$(PYGEN_EXT):$(RISCV_DV_ROOT)/pygen \
		$(PY) $(RISCV_DV_ROOT)/cov.py \
		--dir cov_logs --iss spike \
		--simulator pyflow --target $(TARGET_NAME) \
		--isa rv32imc --opts=--isa=rv32imc \
		--custom_target $(SCR1_TARGET) \
		-tl $(RISCV_DV_ROOT)/yaml/cov_testlist.yaml \
		-o cov --noclean
	@echo ">>> ISA coverage results: $(COV_OUT)/CoverageReport.txt"

clean:
	rm -rf $(WORK)

help:
	@echo "SCR1 fuzz flow (riscv-dv -> UVM + Spike lockstep)"
	@echo ""
	@echo "  make venv                        - create the pygen venv (once)"
	@echo "  make submodule                   - init the riscv-dv submodule (once)"
	@echo "  make fuzz SEED=<n> [TEST=...]    - full flow: gen->patch->gcc->hex->UVM run"
	@echo "  make regress NUM_SEEDS=<n>       - multi-seed regression + summary table"
	@echo "       (PRESERVE_SEEDS=1 reruns the existing work/seeds.txt set)"
	@echo ""
	@echo "  TEST: riscv_arithmetic_basic_test (default) | riscv_rand_instr_test"
	@echo "        riscv_csr_rand_test (body CSR via patch-time injection)"
	@echo "  CSR_INJECT: body CSR instructions to inject (default: 12 for"
	@echo "        riscv_csr_rand_test, 0 otherwise; see tools/patch_asm.py)"
	@echo "  UVM_TEST: scr1_csr_test (default, RAL checks) | scr1_smoke_test"
	@echo "  SPIKE_COSIM: 1 (default, 2B lockstep; requires SPIKE_HOME=<install prefix"
	@echo "        with lib/libriscv.so> - preferred, or SPIKE_ROOT=<riscv-isa-sim tree>) | 0"
	@echo "  MEM_AGENT: 1 (default, UVM reactive agent) | 0 (legacy scr1_memory_tb_ahb)"
	@echo "  AGENT_IMEM_STALL / AGENT_DMEM_STALL: imem/dmem wait states per transfer"
	@echo "  AGENT_DMEM_ERROR_ADDR: hex - dmem hresp ERROR injection (EC5/EC7)"
	@echo "  AGENT_IMEM_ERROR_ADDR: hex - imem FETCH hresp ERROR injection (EC1,"
	@echo "        pair with the sim/tests/fetch_fault vector)"
	@echo ""
	@echo "Random wait-state campaigns (STANDARD mode - the Spike lockstep is"
	@echo "timing-invariant, so regress/fuzz pass identically under stalls; commit"
	@echo "counts may drop slightly: exit-spin tail outside the drain window):"
	@echo "  AGENT_RANDOM_STALL=<max>: random 1..max wait states per transfer"
	@echo "        (deterministic xorshift32; 0/unset = off = plain profile)"
	@echo "  AGENT_STALL_SEED=<n>: stall PRNG seed (default 1; same seed = same"
	@echo "        cycle counts - reproducible campaigns)"
	@echo "  AGENT_RANDOM_STALL_CH=imem|dmem|both: channel filter (default both)"
	@echo "  make regress NUM_SEEDS=8 SPIKE_COSIM=1 AGENT_RANDOM_STALL=2 \\"
	@echo "       AGENT_STALL_SEED=7 CROSS_PREFIX=... SPIKE_ROOT=..."
	@echo "  MIXED_STALL=1 (regress): alternate seeds between the plain and the"
	@echo "       random-stall profile (MIXED_STALL_MAX=2, MIXED_STALL_SEED=7"
	@echo "       defaults; the per-seed stall column shows the profile)"
	@echo "  STACK_MAX: stack .rept cap in words (default 1000, 64K RAM budget)"
	@echo "  CROSS_PREFIX: riscv toolchain prefix (default riscv64-unknown-elf-)"
	@echo "  VENV: python venv path (default ./.venv, created by 'make venv')"
