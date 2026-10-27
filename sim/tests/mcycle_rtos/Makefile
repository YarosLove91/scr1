src_dir := $(dir $(lastword $(MAKEFILE_LIST)))
KDIR    := $(src_dir)vendor/FreeRTOS-Kernel

# C++ компилятор: тот же xPack-префикс, что и у RISCV_GCC
RISCV_GXX ?= riscv64-unknown-elf-g++

# --- Источники ---
# C (ядро FreeRTOS + клей) и asm (порт) собираются правилами common.mk,
# C++ (приложение) — своим правилом ниже (common.mk C++ не умеет).
c_src := tasks.c queue.c list.c heap_4.c port.c port_glue.c
asm_src_in_project := portASM.S
cpp_src := main.cpp app.cpp console.cpp

# -Os идёт ПОСЛЕ -O3 из common.mk (последний -O побеждает) — ядро компактнее,
# всё вместе влезает в 64K TCM-область (link_tcm.ld).
ADD_FLAGS := -Os
ADD_CFLAGS := -ffreestanding -fno-builtin
ADD_incs := -I$(src_dir) \
            -I$(src_dir)app \
            -I$(KDIR)/include \
            -I$(KDIR)/portable/GCC/RISC-V \
            -I$(KDIR)/portable/GCC/RISC-V/chip_specific_extensions/RISCV_no_extensions
ADD_VPATH := $(KDIR) $(KDIR)/portable/MemMang $(KDIR)/portable/GCC/RISC-V $(src_dir)app

# Линковка: C++-объекты требуют -lstdc++ (в группе с -lc/-lgcc, nano.specs)
LDFLAGS := -nostartfiles -nostdlib -Wl,--start-group -lc -lgcc -lstdc++ -Wl,--end-group \
           -march=rv32$(ARCH)_zicsr_zifencei -mabi=$(ABI) --specs=nano.specs

include $(inc_dir)/common.mk

# --- C++ правила (после include: common.mk их не знает) ---
CPP_OBJS := $(addprefix $(bld_dir)/,$(patsubst %.cpp,%.o,$(cpp_src)))

CPPFLAGS := -Os -std=gnu++17 -static -ffreestanding -fno-exceptions -fno-rtti \
            -fno-use-cxa-atexit -fno-threadsafe-statics -fno-common -fno-builtin-printf \
            -DTCM=1 $(CFLAGS_ARCH) $(incs)

$(bld_dir)/%.o: %.cpp
	$(RISCV_GXX) $(CPPFLAGS) -c $< -o $@

default: log_requested_tgt $(bld_dir)/mcycle_rtos.elf $(bld_dir)/mcycle_rtos.hex $(bld_dir)/mcycle_rtos.dump

log_requested_tgt:
	echo mcycle_rtos.hex>> $(bld_dir)/test_info

clean:
	$(RM) $(c_objs) $(asm_objs) $(CPP_OBJS) $(bld_dir)/mcycle_rtos.elf $(bld_dir)/mcycle_rtos.hex $(bld_dir)/mcycle_rtos.dump

# Долинковываем C++-объекты к правилу %.elf из common.mk (prerequisite-only rule)
$(bld_dir)/mcycle_rtos.elf: $(CPP_OBJS)
