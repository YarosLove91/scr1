/*
 * scr1_seq_inject.S — demo vector for SEQUENCE-driven mem ERROR injection.
 *
 * Pairs with the UVM scr1_seq_inject_test / scr1_seq_inject_vseq, which arm
 * hresp ERROR on the console word address (SCR1_SIM_PRINT_ADDR = 0xF0000000)
 * THROUGH A SEQUENCE on the memory agent's injection sequencer (not via the
 * +AGENT_DMEM_ERROR_ADDR plusarg).
 *
 * The program stores a short tag to the console; each store normally answers
 * OKAY. When the sequence injects ERROR on the console address, the store
 * faults (store access fault, mcause=7); the self-contained trap handler below
 * (identical skip-the-faulting-instruction scheme as scr1_cov_directed.S)
 * advances mepc past the faulting store and mret's, so the run still exits
 * a0=0 (PASS) with the mcause=7 trap visible in the commit log. WITHOUT the
 * injection the stores simply print and no trap occurs.
 *
 * Exit: a0 = 0, jump to 0xF8 where .exit_vec holds the legal `j .` spin
 * (SCR1 tb convention). Runs WITHOUT Spike lockstep (SPIKE_COSIM=0).
 * Build/run: see 'make seq_inject' in dv/fuzz/Makefile (link.ld @0x200).
 */

    .section .text
    .globl _start
    .option norvc          # predictable 4-byte encodings for the body

_start:
    /* trap vector: direct mode, handler 64-byte aligned (SCR1 hardwires
       mtvec.BASE[5:0] to zero) */
    la      t0, trap_handler
    csrw    mtvec, t0

    /* ---- console stores (0xF0000000): OKAY normally, mcause=7 when the
       sequence injects ERROR on this word address ---- */
    li      t1, 0xF0000000
    li      a1, 'S'
    sw      a1, 0(t1)
    li      a1, 'E'
    sw      a1, 0(t1)
    li      a1, 'Q'
    sw      a1, 0(t1)

    /* ---- pass verdict and exit (SCR1 tb convention) ---- */
    li      a0, 0
    li      t0, 0xF8
    jr      t0

    /* ---- trap handler: mepc += insn size (2/4), mret ---- */
    .balign 64
trap_handler:
    csrr    t3, mepc
    /* read the low 16 bits at mepc with BYTE loads (lhu would trap on an
       odd mepc) */
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

    /* legal spin at the 0xF8 exit marker (see link.ld exit_vec) */
    .section .exit_vec,"ax"
    .align 2
_exit_vec:
    j       .
