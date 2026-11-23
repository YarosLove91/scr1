/*
 * scr1_cov_directed.S — directed coverage vector for the SCR1 UVM env.
 *
 * Deterministically exercises the hard-to-reach fcov bins that random
 * riscv-dv streams currently miss:
 *   - fence / fence.i / fence rw,rw      (cp_retire_cat fence/fence_i)
 *   - ecall / ebreak / c.ebreak          (cp_trap_cat, exc_cg EC 11/3)
 *   - misaligned lw  (odd addr)          (exc_cg EC 4  LD_ADDR_MISALIGN)
 *   - misaligned sw  (odd addr)          (exc_cg EC 6  ST_ADDR_MISALIGN)
 *   - unmapped lw/sw (0x20000000)        (exc_cg EC 5/7 LD/ST_ACCESS_FAULT)
 * EC 0 (INSTR_MISALIGN) is unreachable with RVC: jalr/jal clear the target
 * LSB and mepc[0] is hardwired zero - documented, not exercised.
 * SCR1 traps on every misaligned access (scr1_pipe_lsu.sv), so a small
 * self-contained trap handler advances mepc past the trapping instruction
 * (2 bytes for compressed, 4 otherwise, read via byte loads - a halfword
 * load at an odd mepc would trap again) and mret's back.
 *
 * Exit: a0 = 0, jump to 0xF8 where .exit_vec holds the legal `j .` spin
 * (SCR1 tb convention). Runs WITHOUT Spike lockstep (SPIKE_COSIM=0):
 * Spike executes misaligned accesses natively and would diverge.
 *
 * Build: see 'make cov_directed' in dv/fuzz/Makefile (link.ld @0x200).
 */

    .section .text
    .globl _start
    .option norvc          # predictable 4-byte encodings for the body

_start:
    /* trap vector: direct mode, handler is 64-byte aligned (SCR1
       hardwires mtvec.BASE[5:0] to zero) */
    la      t0, trap_handler
    csrw    mtvec, t0

    /* ---- fences ---- */
    fence
    fence   rw, rw
    fence.i

    /* ---- ecall (EC 11) -> handler skips 4 ---- */
    ecall

    /* ---- ebreak (EC 3) -> handler skips 4 ---- */
    ebreak

    /* ---- c.ebreak (EC 3) -> handler skips 2 ---- */
    .option rvc
    .2byte  0x9002
    .option norvc

    /* ---- misaligned load (EC 4) ---- */
    la      t1, data_area
    addi    t1, t1, 1          # odd address
    lw      a1, 0(t1)          # trap; handler skips the lw

    /* ---- misaligned store (EC 6) ---- */
    sw      a1, 0(t1)          # trap; handler skips the sw

    /* ---- access faults (EC 5/7): unmapped address.
       memory tb drives dmem_hresp=ERROR outside the known regions
       (RAM/TCM/timer/sim) -> LSU raises LD/ST_ACCESS_FAULT ---- */
    li      t1, 0x20000000
    lw      a1, 0(t1)          # EC 5 load access fault
    sw      a1, 0(t1)          # EC 7 store access fault

    /* ---- misaligned jump: jalr clears target bit0 per spec and
       mepc[0] is hardwired 0, so EC 0 (INSTR_MISALIGN) is
       architecturally UNREACHABLE with RVC - intentionally absent ---- */
    la      t2, after_jr
    jalr    x0, t2, 0

after_jr:
    /* ---- pass verdict and exit (SCR1 tb convention) ---- */
    li      a0, 0
    li      t0, 0xF8
    jr      t0

    /* ---- trap handler: mepc += insn size (2/4), mret ---- */
    .balign 64
trap_handler:
    csrr    t3, mepc
    /* read the low 16 bits at mepc with BYTE loads (mepc may be odd
       after a misaligned jump; lhu would trap again) */
    lbu     t4, 0(t3)
    lbu     t5, 1(t3)
    slli    t5, t5, 8
    or      t4, t4, t5
    andi    t4, t4, 3
    li      t5, 3
    bne     t4, t5, handler_adv2
    addi    t3, t3, 4          /* 32-bit instruction */
    j       handler_wr
handler_adv2:
    addi    t3, t3, 2          /* compressed instruction */
handler_wr:
    csrw    mepc, t3
    mret

    .section .data
    .align 4
data_area:
    .word   0x12345678
    .word   0x87654321

    /* legal spin at the 0xF8 exit marker (see link.ld exit_vec) */
    .section .exit_vec,"ax"
    .align 2
_exit_vec:
    j       .
