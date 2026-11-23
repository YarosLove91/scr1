# Fetch access fault vector (EC1 coverage, exc_cg.cp_ec.fetch_access).
#
# The program jumps to POISON_ADDR - a RAM word that the UVM reactive
# memory agent poisons with an AHB ERROR response when run with
#   MEM_AGENT=1 AGENT_IMEM_ERROR_ADDR=3000
# (the imem bridge/IFU turn hresp ERROR into an instruction access
# fault, mcause=1). The handler verifies the CAUSE is exactly the
# fetch access fault, counts it, re-points mepc to the recovery label
# and mret's; the verdict is a0=0 iff the handler saw mcause==1.
#
# WITHOUT the injection the poisoned word fetches zeros = an illegal
# instruction (mcause=2) -> cause check fails -> a0=1: the vector is
# its own negative control. Requires MEM_AGENT=1 (like irq_ext).
#
# Layout mirrors isr_sample/irq_ext: trap table @0x1C0, _start@0x200.

#include "riscv_macros.h"
#include "sc_test.h"

.altmacro

#define POISON_ADDR         0x00003000   // keep == AGENT_IMEM_ERROR_ADDR
#define MCAUSE_FETCH_FAULT  1

    .section .text.init
    .option norvc
    .globl _start

    .org (64*3)
    .balign 64
machine_trap_entry:
    j   fetch_fault_handler // 0
    j   _trap_fail          // 1
    j   _trap_fail          // 2
    j   _trap_fail          // 3
    j   _trap_fail          // 4
    j   _trap_fail          // 5
    j   _trap_fail          // 6
    j   _trap_fail          // 7
    j   _trap_fail          // 8
    j   _trap_fail          // 9
    j   _trap_fail          // 10
    j   _trap_fail          // 11
    j   _trap_fail          // 12
    j   _trap_fail          // 13
    j   _trap_fail          // 14
    j   _trap_fail          // 15

    .balign 64
_start:
    la      t0, machine_trap_entry
    csrw    mtvec, t0                   // direct mode (exceptions -> BASE)
    la      t0, hsave
    csrw    mscratch, t0                // handler save area
    li      s2, 0                       // fetch-fault counter

    // jump into the poisoned word: the FETCH itself must fault
    li      t0, POISON_ADDR
    jalr    zero, t0, 0

    .balign 64
after_fault:                            // handler re-points mepc here
    li      a0, 0
    li      t1, 1
    bne     s2, t1, test_fail           // expected exactly one EC1 trap
    j       test_exit
test_fail:
    li      a0, 1
test_exit:
    la      t0, sc_exit
    jr      t0

    .balign 64
fetch_fault_handler:
    csrrw   t0, mscratch, t0            // t0 = &hsave, mscratch = old t0
    sw      a1, 0(t0)
    sw      a5, 4(t0)
    csrr    a1, mcause
    li      a5, MCAUSE_FETCH_FAULT
    bne     a1, a5, h_done              // wrong cause: leave s2 = 0 (fail)
    addi    s2, s2, 1
h_done:
    la      a5, after_fault
    csrw    mepc, a5                    // recovery: skip the poison word
    lw      a5, 4(t0)
    lw      a1, 0(t0)
    csrrw   t0, mscratch, t0            // restore t0, mscratch = &hsave
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
