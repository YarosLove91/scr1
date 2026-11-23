# Multi-pulse / random IRQ stress vector for the UVM IRQ agent (dv/uvm).
# Generalizes sim/tests/irq_ext from a single external (IPIC line 9) + a
# single software pulse to ARBITRARY series of testbench-injected pulses:
# the program enables ALL IPIC lines (0..IRQ_LINES_NUM-1) in edge mode plus
# the machine software interrupt, then keeps BOTH enabled in ONE bounded
# spin loop while the agent (scr1_irq_run_vseq, scr1_mem_model.inj_ext /
# inj_soft OR-merged by the reactive memory agent) injects random external
# external line masks and software pulses - possibly SIMULTANEOUS ext+soft.
#
# This exercises IPIC priority arbitration: when several lines are asserted
# at once the IPIC search-one logic starts the LOWEST-index (highest
# priority) pending+enabled line per SOI; after EOI the next still-pending
# pending line re-requests, so a k-bit injected mask yields k sequential ext
# traps (edge mode latches each rising edge as pending). Concurrent ext+soft
# tests the core's interrupt priority (MEI over MSI) and the deferred-trap /
# IRQ-at-retire path under a pulse storm.
#
# The vector NEVER triggers any line itself (no store to TRIG_*_IRQ_ADDR):
# it only installs the handler, enables the sources and waits for the TB.
#
# Pass criterion (robust across scenarios, exact counts are checked on the
# UVM side via the trap/csr_live counters): at least PASS_EXT_MIN external
# AND PASS_SOFT_MIN software interrupts were serviced (a0 = 0), otherwise
# a0 = 1. The bounded spin (SPIN_LIMIT) guarantees termination (no hang)
# even if an injection is missed; the loop does NOT exit early so every trap
# delivered during the spin window is counted.
#
# Structure mirrors sim/tests/irq_ext (same .org / trap-table @0x1C0 /
# _start@0x200 layout, direct + vectored modes via #ifdef); the handler
# saves the scratch registers it uses through mscratch (no kernel stack).

#include "riscv_macros.h"
#include "sc_test.h"

.altmacro

#define MSIE                (1 << IRQ_M_SOFT)
#define MEIE                (1 << IRQ_M_EXT)
#define MCAUSE_EXT_IRQ      (1 << 31 | IRQ_M_EXT)
#define MCAUSE_SOFT_IRQ     (1 << 31 | IRQ_M_SOFT)

// simulation device registers (the IRQ agent injection is OR-merged with
// any store the program makes here; the stress vector stores to NEITHER)
#define IRQ_LINES_ADDR      0xF0000100
#define TRIG_SW_IRQ_ADDR    0xF0000200

// IPIC (only when the core is built with SCR1_IPIC_EN)
#define IPIC_EOI            0xBF4
#define IPIC_SOI            0xBF5
#define IPIC_IDX            0xBF6
#define IPIC_ICSR           0xBF7
#define IPIC_ICSR_IE        (1 << 1)
#define IPIC_ICSR_IM        (1 << 2)

// number of IPIC lines to enable (matches scr1_cfg_pkg::IRQ_LINES_NUM)
#define IRQ_LINES_NUM       16

// bounded spin so a missed injection still terminates the run; large enough
// to cover a random pulse series yet well under the UVM watchdog
#define SPIN_LIMIT          100000

// pass thresholds (kept at >=1 so any scenario passes; the exact ext/soft
// trap counts are verified on the UVM side, see the file header)
#define PASS_EXT_MIN        1
#define PASS_SOFT_MIN       1

    .section .text.init
    .option norvc
    .globl _start

//  -----------------------------------------------------------------
//  Trap vector table (16 entries, 4 bytes each: 0x1C0 .. 0x1FF).
//  Entry 0 is the direct-mode entry; entries 3 (machine software) and
//  11 (machine external) are the vectored-mode entries. This single
//  table serves BOTH mtvec modes.
//  -----------------------------------------------------------------
    .org (64*3)
    .balign 64
machine_trap_entry:
    j   direct_dispatch     // 0  (direct mode: all traps)
    j   _trap_fail          // 1  user software
    j   _trap_fail          // 2  supervisor software
    j   soft_handler        // 3  machine software (vectored)
    j   _trap_fail          // 4  user timer
    j   _trap_fail          // 5  supervisor timer
    j   _trap_fail          // 6  reserved
    j   _trap_fail          // 7  machine timer (unused here)
    j   _trap_fail          // 8  user external
    j   _trap_fail          // 9  supervisor external
    j   _trap_fail          // 10 reserved
    j   ext_handler         // 11 machine external (vectored)
    j   _trap_fail          // 12
    j   _trap_fail          // 13
    j   _trap_fail          // 14
    j   _trap_fail          // 15

//  -----------------------------------------------------------------
    .balign 64
_start:
    la      t0, machine_trap_entry
    csrw    mtvec, t0
#ifdef VECT_IRQ_ENABLED
    csrsi   mtvec, 1                    // vectored mode
#endif
    // mscratch = handler register-save area (3 words)
    la      t0, hsave
    csrw    mscratch, t0
    // counters (shared with the handlers; main only reads them)
    li      s2, 0                       // external IRQ counter
    li      s3, 0                       // software IRQ counter

    // ---- enable ALL IPIC lines (edge mode) + software + global ----
    csrw    mie, zero
    li      t0, IRQ_LINES_ADDR
    sh      zero, (t0)                  // clear any latched ext lines
#ifdef IPIC_ENABLED
    li      t1, 0                       // line index n
    li      t2, IRQ_LINES_NUM           // 16
    li      t0, (IPIC_ICSR_IE | IPIC_ICSR_IM)
ipic_en_loop:
    csrw    IPIC_IDX, t1                // select line n
    csrw    IPIC_ICSR, t0               // enable, edge mode
    addi    t1, t1, 1
    blt     t1, t2, ipic_en_loop
#endif
    li      t0, (MEIE | MSIE)
    csrs    mie, t0                     // enable external + software
    csrs    mstatus, MSTATUS_MIE        // global interrupt enable

    // ---- single bounded spin: both sources stay enabled, count all ----
    li      t3, SPIN_LIMIT
main_wait:
    addi    t3, t3, -1
    bnez    t3, main_wait

    csrc    mstatus, MSTATUS_MIE        // global interrupt disable

    // ---- verdict: pass iff ext >= PASS_EXT_MIN and soft >= PASS_SOFT_MIN ----
    li      a0, 0
    li      t0, PASS_EXT_MIN
    blt     s2, t0, test_fail
    li      t0, PASS_SOFT_MIN
    blt     s3, t0, test_fail
    j       test_exit
test_fail:
    li      a0, 1
test_exit:
    la      t0, sc_exit
    jr      t0

//  -----------------------------------------------------------------
//  Handlers. Each saves the scratch registers it uses (a1, a5, t0)
//  through the mscratch-pointed save area, so an asynchronous trap at
//  any point of the main spin loop is transparent. mstatus.MIE is
//  cleared by hardware on entry, so handlers never nest and the single
//  3-word save area is safe for interleaved ext+soft storms. s2/s3 are
//  the intentional shared counters (main only reads them).
//  -----------------------------------------------------------------
    .balign 64
direct_dispatch:
    csrr    a1, mcause
    li      a5, MCAUSE_EXT_IRQ
    beq     a1, a5, ext_handler
    li      a5, MCAUSE_SOFT_IRQ
    beq     a1, a5, soft_handler
    mret                                // unexpected cause: just return

    .balign 64
ext_handler:
    csrrw   t0, mscratch, t0            // t0 = &hsave, mscratch = old t0
    sw      a1, 0(t0)
    sw      a5, 4(t0)
#ifdef IPIC_ENABLED
    csrw    IPIC_SOI, zero              // start highest-priority pending line
    csrw    IPIC_EOI, zero              // end it (next pending re-requests)
#endif
    addi    s2, s2, 1
    lw      a5, 4(t0)
    lw      a1, 0(t0)
    csrrw   t0, mscratch, t0            // restore t0, mscratch = &hsave
    mret

    .balign 64
soft_handler:
    csrrw   t0, mscratch, t0
    sw      a1, 0(t0)
    sw      a5, 4(t0)
    addi    s3, s3, 1
    li      a5, TRIG_SW_IRQ_ADDR
    sh      zero, (a5)                  // clear the soft device register
    lw      a5, 4(t0)
    lw      a1, 0(t0)
    csrrw   t0, mscratch, t0
    mret

    .balign 64
_trap_fail:
    li      a0, 1
    la      t0, sc_exit
    jr      t0

    .data
    .balign 4
hsave:
    .word   0
    .word   0
    .word   0
