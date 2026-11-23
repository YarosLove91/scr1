# Walking-ones / walking-zeros directed CSR vector for the UVM env (dv/uvm).
#
# The vector is deliberately "dumb": it does NOT self-check a single CSR.
# The golden reference is the environment - every retiring CSR access is
# decoded independently by scr1_csr_scoreboard (milestone 7 live-predict)
# and checked against the WARL-legalized live RAL mirror:
#   csrrw -> ATOMIC_RW: OPERAND (EXU w_data vs the instruction decode),
#            WRITE_MISSING/WRITE_UNEXPECTED (spec rs1/rd gating) and the
#            golden predict of csr_legalize(pattern) into the mirror;
#   csrr  -> READ: LIVE_READ compares the DUT read data against the
#            mirror built from the previous write. This read-back is what
#            walks every WARL mask bit by bit (mstatus MIE/MPIE + MPP=11,
#            mie MSIE/MTIE/MEIE, mtvec BASE 64B + 1-bit MODE, mepc low
#            MEPC_PAD bits, mcause {i, 27'b0, ec[3:0]}, mcounten CY|IR,
#            mscratch/mtval full RW);
#   exit  -> SNAPSHOT: the CSR snapshot must equal the live-built mirror.
#
# Stimulus per CSR: the 68-entry pattern table below - walking ones
# (1<<i, i=0..31), walking zeros (~(1<<i), i=0..31) and four fixed
# patterns (0x0, 0xFFFFFFFF, 0xA5A5A5A5, 0x55555555) - is written with
# csrrw and read back with csrr (2 CSR events per pattern, ~1640 live
# golden checks in total).
#
# Order rules (all of them for the same reason: the vector must never
# take a trap, its verdict is a0=0 = "reached the end"):
#   * mstatus is walked BEFORE mie - a walking mstatus.MIE=1 is only
#     harmless while mie is still at its reset value 0;
#   * mtvec is walked LAST of the control group and restored to
#     0x1C0 (direct mode, the trap table below) immediately after - the
#     walking patterns leave a garbage trap base behind;
#   * the counters are walked after the control CSRs, with bit31 forced
#     into every pattern (value >= 2^31), and the LO halves are restored
#     to 0xFFFFFFFF at the very end: in this RTL a hi-half write also
#     rewrites counter[31:8] (the unpatched BUG-002/#87 class), so no hi
#     write may follow the lo restore. Restoring both lo halves to all
#     ones keeps the scoreboard exit invariant mcycle >= minstret true
#     (both wrap into the same hi value, mcycle ticks faster).
#
# No trap is expected: every instruction is legal, ecall is not used.
# The trap table is minimal insurance - an unexpected trap reports a0=1
# instead of hanging. Layout mirrors isr_sample/irq_ext/fetch_fault:
# trap table @0x1C0, _start@0x200.
#
# Run: make run TEST=scr1_csr_test SW_TEST=csr_walk1 CROSS_PREFIX=<...>

// sc_test.h only (sc_exit): riscv_macros.h/riscv_csr_encoding.h are not
// used and would collide with the CSR address defines below.
#include "sc_test.h"

.altmacro

// M-mode CSR addresses, numeric: keeps the vector independent of the
// assembler CSR name table (mcounten 0x7E0 is SCR1-specific anyway)
#define CSR_MSTATUS     0x300
#define CSR_MIE         0x304
#define CSR_MTVEC       0x305
#define CSR_MSCRATCH    0x340
#define CSR_MEPC        0x341
#define CSR_MCAUSE      0x342
#define CSR_MTVAL       0x343
#define CSR_MCOUNTEN    0x7E0
#define CSR_MCYCLE      0xB00
#define CSR_MINSTRET    0xB02
#define CSR_MCYCLEH     0xB80
#define CSR_MINSTRETH   0xB82

// benign state restored after the walking sections
#define MTVEC_SAFE      0x1C0       // direct mode -> machine_trap_entry
#define MSTATUS_RST     0x1880      // MPP=11 | MPIE=1 | MIE=0
#define MCOUNTEN_RST    0x5         // CY | IR enabled

// walk the whole pattern table through one CSR:
// csrrw = write (golden WRITE/OPERAND + predict), csrr = read back
// (LIVE_READ against the mirror). s0 = cursor, s1 = table end.
.macro WALK_CSR csr
    la      s0, pat_table
9:  lw      t1, 0(s0)
    csrrw   t0, \csr, t1
    csrr    t0, \csr
    addi    s0, s0, 4
    bltu    s0, s1, 9b
.endm

// counters: the same walk with bit31 OR-ed into every pattern (t3)
.macro WALK_CNT csr
    la      s0, pat_table
9:  lw      t1, 0(s0)
    or      t1, t1, t3
    csrrw   t0, \csr, t1
    csrr    t0, \csr
    addi    s0, s0, 4
    bltu    s0, s1, 9b
.endm

    .section .text.init
    .option norvc
    .globl _start

//  -----------------------------------------------------------------
//  Trap vector table (16 entries, 4 bytes each: 0x1C0 .. 0x1FF).
//  The vector never traps on purpose - every entry just reports FAIL.
//  -----------------------------------------------------------------
    .org (64*3)
    .balign 64
machine_trap_entry:
    j   _trap_fail              // 0
    j   _trap_fail              // 1
    j   _trap_fail              // 2
    j   _trap_fail              // 3
    j   _trap_fail              // 4
    j   _trap_fail              // 5
    j   _trap_fail              // 6
    j   _trap_fail              // 7
    j   _trap_fail              // 8
    j   _trap_fail              // 9
    j   _trap_fail              // 10
    j   _trap_fail              // 11
    j   _trap_fail              // 12
    j   _trap_fail              // 13
    j   _trap_fail              // 14
    j   _trap_fail              // 15

    .balign 64
_start:
    la      s1, pat_table_end           // pattern table limit
    lui     t3, 0x80000                 // bit31 of the counter patterns

    // ---- writable control CSRs (see the order rules in the header) ----
    WALK_CSR CSR_MSCRATCH
    WALK_CSR CSR_MTVAL
    WALK_CSR CSR_MEPC
    WALK_CSR CSR_MCAUSE
    WALK_CSR CSR_MSTATUS
    WALK_CSR CSR_MIE
    WALK_CSR CSR_MCOUNTEN
    WALK_CSR CSR_MTVEC                  // last: leaves a garbage base

    // ---- restore a benign control state ----
    li      t1, MTVEC_SAFE
    csrw    CSR_MTVEC, t1
    li      t1, 0
    csrw    CSR_MIE, t1
    li      t1, MSTATUS_RST
    csrw    CSR_MSTATUS, t1
    li      t1, MCOUNTEN_RST
    csrw    CSR_MCOUNTEN, t1

    // ---- counters (bit31 forced; lo halves restored last) ----
    WALK_CNT CSR_MCYCLE
    WALK_CNT CSR_MINSTRET
    WALK_CNT CSR_MCYCLEH
    WALK_CNT CSR_MINSTRETH
    li      t1, -1
    csrw    CSR_MCYCLE, t1
    csrw    CSR_MINSTRET, t1

    li      a0, 0                       // walked everything, no trap
    la      t0, sc_exit
    jr      t0

    .balign 64
_trap_fail:
    li      a0, 1                       // unexpected trap -> FAIL, no hang
    la      t0, sc_exit
    jr      t0

//  -----------------------------------------------------------------
//  68 patterns: walking ones, walking zeros, four fixed values
//  -----------------------------------------------------------------
    .data
    .balign 4
pat_table:
    .set    i, 0
    .rept   32
    .word   (1 << i)
    .set    i, i + 1
    .endr
    .set    i, 0
    .rept   32
    .word   ~(1 << i)
    .set    i, i + 1
    .endr
    .word   0x00000000
    .word   0xFFFFFFFF
    .word   0xA5A5A5A5
    .word   0x55555555
pat_table_end:
