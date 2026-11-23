// ============================================================
// File    : scr1_seq_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Sequence package: sequence item (scr1_transaction), base
// sequence and the stimulus library (run-program). Depends on
// scr1_cfg_pkg / scr1_tb_pkg only - the agent package imports
// this one.
// ============================================================
`ifndef SCR1_SEQ_PKG_SV
`define SCR1_SEQ_PKG_SV

package scr1_seq_pkg;

  import uvm_pkg::*;
  import scr1_cfg_pkg::*;
  import scr1_tb_pkg::*;

  `include "uvm_macros.svh"

  `include "scr1_transaction.sv"
  `include "scr1_commit_tr.sv"
  // the base sequence must be included first
  `include "scr1_base_seq.sv"
  `include "scr1_run_prog_seq.sv"

endpackage : scr1_seq_pkg

`endif // SCR1_SEQ_PKG_SV
