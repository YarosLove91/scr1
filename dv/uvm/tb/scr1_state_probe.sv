// ============================================================
// File    : scr1_state_probe.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR snapshot + observation taps probe, bound into the DUT top
// by tb/scr1_bind.sv (ibex fcov_bind pattern): snap_o assembles
// the pipe_csr registers into scr1_csr_snap_s (RAL, M3; read-only
// ID registers = cfg_pkg reset constants); curr_pc/instret/a0 are
// the observation taps for the UVM monitor (a0 = MPRF x10, the
// pass/fail convention). Purely combinational. Env-side file: no
// RTL-header includes, widths/constants from scr1_cfg_pkg.
// ============================================================
`timescale 1ns/1ps

module scr1_state_probe
  import scr1_cfg_pkg::*;
#(
  // mepc padding: csr_mepc_ff is [31:MEPC_PAD] - the port keeps the POSITIONAL
  // bit alignment (a value-typed [31:1] would carry mepc>>1, not mepc)
  parameter int MEPC_PAD = 1
)(
  // ---- observation taps ----
  input  xlen_word_t    curr_pc_i,
  input  logic          instret_i,
  input  xlen_word_t    a0_i,

  // ---- pipe_csr taps ----
  input  csr_data_t     mstatus_i,
  input  csr_data_t     mie_i,
  input  mtvec_base_t   mtvec_base_i,   // csr_mtvec_base [31:6]
  input  logic          mtvec_mode_i,
  input  csr_data_t     mscratch_i,
  input  logic [XLEN-MEPC_PAD-1:0] mepc_i,  // csr_mepc_ff ([31:1] with RVC)
  input  logic        mcause_irq_i,
  input  exc_code_t   mcause_ec_i,          // type_scr1_exc_code_e is 4-bit
  input  csr_data_t     mtval_i,
  input  csr_data_t     mip_i,
  input  csr_data_t     mcounten_i,
  input  counter_word_t mcycle_i,
  input  counter_word_t minstret_i,
  input  csr_data_t     mhartid_i,

  // ---- re-exported to the harness ----
  output xlen_word_t       curr_pc_o,
  output logic             instret_o,
  output xlen_word_t       a0_o,
  output scr1_csr_snap_s   snap_o
);

  assign curr_pc_o = curr_pc_i;
  assign instret_o = instret_i;
  assign a0_o      = a0_i;

  always_comb begin
    snap_o.mstatus   = mstatus_i;
    snap_o.misa      = MISA_RST_VAL;
    snap_o.mie       = mie_i;
    // structural mtvec WARL assembly: {BASE[31:6], zeros, MODE}
    snap_o.mtvec     = {mtvec_base_i,
                        {(MTVEC_BASE_LSB-MTVEC_MODE_BITS){1'b0}},
                        MTVEC_MODE_BITS'(mtvec_mode_i)};
    snap_o.mscratch  = mscratch_i;
    // positional mepc re-assembly (low MEPC_PAD bits hardwired zero)
    snap_o.mepc      = {mepc_i, {MEPC_PAD{1'b0}}};
    // structural mcause: {irq, zeros, ec[3:0]}; ec flop is 4-bit (codes 0..11)
    snap_o.mcause    = {mcause_irq_i,
                        {(XLEN-1-$bits(exc_code_t)){1'b0}}, mcause_ec_i};
    snap_o.mtval     = mtval_i;
    snap_o.mip       = mip_i;
    snap_o.mcounten  = mcounten_i;
    // 64-bit counter halves split at the XLEN boundary
    snap_o.mcycle    = mcycle_i[XLEN-1:0];
    snap_o.mcycleh   = mcycle_i[2*XLEN-1:XLEN];
    snap_o.minstret  = minstret_i[XLEN-1:0];
    snap_o.minstreth = minstret_i[2*XLEN-1:XLEN];
    snap_o.mhartid   = mhartid_i;
    snap_o.mvendorid = MVENDORID_RST_VAL;
    snap_o.marchid   = MARCHID_RST_VAL;
    snap_o.mimpid    = MIMPID_RST_VAL;
  end

endmodule : scr1_state_probe
