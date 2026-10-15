src_dir := $(dir $(lastword $(MAKEFILE_LIST)))

c_src := a5_1.c

# Freestanding link: no libc/libgcc.
ADD_CFLAGS := -ffreestanding -fno-builtin
LDFLAGS := -nostartfiles -nostdlib -march=rv32$(ARCH)_zicsr_zifencei -mabi=$(ABI)

include $(inc_dir)/common.mk

default: log_requested_tgt $(bld_dir)/a5_1.elf $(bld_dir)/a5_1.hex $(bld_dir)/a5_1.dump

log_requested_tgt:
	echo a5_1.hex>> $(bld_dir)/test_info

clean:
	$(RM) $(c_objs) $(asm_objs) $(bld_dir)/a5_1.elf $(bld_dir)/a5_1.hex $(bld_dir)/a5_1.dump
