src_dir := $(dir $(lastword $(MAKEFILE_LIST)))

c_src := issue80_core.c

# Freestanding link: no libc/libgcc.
ADD_CFLAGS := -ffreestanding -fno-builtin
LDFLAGS := -nostartfiles -nostdlib -march=rv32$(ARCH)_zicsr_zifencei -mabi=$(ABI)

include $(inc_dir)/common.mk

default: log_requested_tgt $(bld_dir)/issue80_core.elf $(bld_dir)/issue80_core.hex $(bld_dir)/issue80_core.dump

log_requested_tgt:
	echo issue80_core.hex>> $(bld_dir)/test_info

clean:
	$(RM) $(c_objs) $(asm_objs) $(bld_dir)/issue80_core.elf $(bld_dir)/issue80_core.hex $(bld_dir)/issue80_core.dump
