###############################################################################
# SCR1 pure C++ Verilator testbench (AXI)
# Replaces the native SV testbench (scr1_top_tb_axi + scr1_memory_tb_axi)
###############################################################################
TOP            ?= scr1_top_axi
SIM_CFG_DEF    ?= SCR1_CFG_RV32IMC_MAX
SIM_TRACE_DEF  ?= SCR1_TRACE_LOG_DIS

# Testbench config defines, see makefile.build_tb
TB_DEFINES     ?=

# Default test image: fern.elf of an existing native AXI build, if present
TEST_IMAGE     ?= $(firstword $(wildcard ../../build/verilator_AXI*/*.elf) ./test.elf)

# Extra run options, e.g. RUN_OPTS="-c 100000 --trace 0"
RUN_OPTS       ?=

NUM_THREADS    := $(shell nproc)
ifeq ($(NUM_THREADS), 0)
	NUM_THREADS := 2
else
	NUM_THREADS := $(shell echo "$$(( $(NUM_THREADS) - 2 ))")
endif

###############################################################################
.PHONY: all build clean run print_help

all: build

print_help:
	@echo " Using make:"
	@echo " make build - Verilate DUT, build model and testbench"
	@echo " make run   - Build and run TEST_IMAGE (default: first elf of native AXI build)"
	@echo " make clean - Clean the generated files"
	@echo " Variables:"
	@echo "  TOP=scr1_top_axi SIM_CFG_DEF=SCR1_CFG_RV32IMC_MAX SIM_TRACE_DEF=SCR1_TRACE_LOG_DIS"
	@echo "  TEST_IMAGE=<path to elf> RUN_OPTS=\"-c NUM --trace 0|1 --vcd_name FILE\""

build:
	make -f makefile.generate_verilated TOP=$(TOP) SIM_CFG_DEF=$(SIM_CFG_DEF) SIM_TRACE_DEF=$(SIM_TRACE_DEF)
	make -f makefile.build_verilated TOP=$(TOP) -j $(NUM_THREADS)
	make -f makefile.build_tb TOP=$(TOP) TB_DEFINES="$(TB_DEFINES)" -j $(NUM_THREADS)

run: build
	./build/test.x -f $(TEST_IMAGE) $(RUN_OPTS)

clean:
	-make -f makefile.generate_verilated clean
	-make -f makefile.build_verilated TOP=$(TOP) clean
	-make -f makefile.build_tb clean
	-rm -rf *.vcd

.DEFAULT_GOAL := print_help
