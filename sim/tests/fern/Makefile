src_dir := $(dir $(lastword $(MAKEFILE_LIST)))

c_src := fern.c

# Freestanding link: no libc/libgcc (avoids 64-bit multilib requirement).
ADD_CFLAGS := -ffreestanding -fno-builtin
LDFLAGS := -nostartfiles -nostdlib -march=rv32$(ARCH)_zicsr_zifencei -mabi=$(ABI)

include $(inc_dir)/common.mk

default: log_requested_tgt $(bld_dir)/fern.elf $(bld_dir)/fern.hex $(bld_dir)/fern.dump

log_requested_tgt:
	echo fern.hex>> $(bld_dir)/test_info

clean:
	$(RM) $(c_objs) $(asm_objs) $(bld_dir)/fern.elf $(bld_dir)/fern.hex $(bld_dir)/fern.dump
