# -----------------------------------------------------------------------------
# riscv_core_setting.py — riscv-dv target for the SCR1 core (RV32IMC, MAX cfg)
#
# Based on the built-in pygen rv32imc target, adapted to SCR1:
#   - M-mode only, BARE addressing, no PMP / debug / sfence / U-mode traps;
#   - implemented_csr = the SCR1 M-mode set (src/includes/scr1_csr.svh):
#     NO mcounteren (SCR1 uses the custom mcounten 0x7E0 instead), plus the
#     RV32 counter halves mcycle/minstret/mcycleh/minstreth;
#   - programs are linked by link.ld at 0x200 (SCR1 reset vector) and must
#     fit the 64K RAM (the fuzz Makefile caps stacks via tools/patch_asm.py).
# -----------------------------------------------------------------------------

import math
from pygen_src.riscv_instr_pkg import (
    privileged_reg_t,
    satp_mode_t,
    riscv_instr_group_t,
    mtvec_mode_t,
    privileged_mode_t,
)

# XLEN
XLEN = 32

# set to BARE if address translation is not supported
SATP_MODE = satp_mode_t.BARE

# Supported Privileged mode
supported_privileged_mode = [privileged_mode_t.MACHINE_MODE]

# Unsupported instructions
unsupported_instr = []

# ISA supported by the processor (SCR1 CFG=MAX: RV32IMC)
supported_isa = [riscv_instr_group_t.RV32I, riscv_instr_group_t.RV32M,
                 riscv_instr_group_t.RV32C]

# Interrupt mode support (SCR1 MAX with VECT_IRQ supports both; the
# generated handler dispatches by mcause in software either way)
supported_interrupt_mode = [mtvec_mode_t.DIRECT, mtvec_mode_t.VECTORED]

# The number of interrupt vectors to be generated, only used if VECTORED
# interrupt mode is supported
max_interrupt_vector_num = 16

# Physical memory protection support
support_pmp = 0

# Debug mode support
support_debug_mode = 0

# Support delegate trap to user mode
support_umode_trap = 0

# Support sfence.vma instruction
support_sfence = 0

# Support unaligned load/store
support_unaligned_load_store = 1

# GPR Setting
NUM_FLOAT_GPR = 0
NUM_GPR = 32
NUM_VEC_GPR = 0

# -----------------------------------------------------------------------------
# Vector extension configuration (not present in SCR1)
# -----------------------------------------------------------------------------
VECTOR_EXTENSION_ENABLE = 0
VLEN = 0
ELEN = 0
SELEN = 0
VELEN = 0
MAX_LMUL = 1

# Harts
NUM_HARTS = 1

# -----------------------------------------------------------------------------
# Privileged CSR implementation (SCR1 M-mode subset, scr1_csr.svh)
# -----------------------------------------------------------------------------
implemented_csr = [
    privileged_reg_t.MVENDORID,   # 0xF11 Vendor ID (RO, 0)
    privileged_reg_t.MARCHID,     # 0xF12 Architecture ID (RO, 8)
    privileged_reg_t.MIMPID,      # 0xF13 Implementation ID (RO, 0x22011200)
    privileged_reg_t.MHARTID,     # 0xF14 Hardware thread ID (RO, fuse)
    privileged_reg_t.MSTATUS,     # 0x300 Machine status (MIE/MPIE/MPP=11)
    privileged_reg_t.MISA,        # 0x301 ISA and extensions (RO)
    privileged_reg_t.MIE,         # 0x304 Machine interrupt-enable
    privileged_reg_t.MTVEC,       # 0x305 Machine trap-handler base
    # NOTE: no MCOUNTEREN - SCR1 uses the custom MCOUNTEN (0x7E0) instead
    privileged_reg_t.MSCRATCH,    # 0x340 Scratch register
    privileged_reg_t.MEPC,        # 0x341 Machine exception program counter
    privileged_reg_t.MCAUSE,      # 0x342 Machine trap cause
    privileged_reg_t.MTVAL,       # 0x343 Machine bad address/instruction
    privileged_reg_t.MIP,         # 0x344 Machine interrupt pending
    privileged_reg_t.MCYCLE,      # 0xB00 Machine cycle counter (lo)
    privileged_reg_t.MINSTRET,    # 0xB02 Machine instr-retired counter (lo)
    privileged_reg_t.MCYCLEH,     # 0xB80 cycle counter (hi, RV32)
    privileged_reg_t.MINSTRETH,   # 0xB82 instr-retired counter (hi, RV32)
]

# Implementation-specific custom CSRs (SCR1 mcounten 0x7E0, IPIC 0xBF0-0xBF7,
# TDU 0x7A0-0x7A7 are not modeled here yet - the generator must not emit them)
custom_csr = []
