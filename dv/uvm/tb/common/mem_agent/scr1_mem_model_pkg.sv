// ============================================================
// File    : scr1_mem_model_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Package of the reactive AHB memory agent's memory + device
// model. Co-located with the agent, compiled BEFORE scr1_tb_pkg
// and the RTL; consumers reach it through the package chain (the
// scr1_tb_pkg global g_mem_model -> harness / mem_agent_pkg /
// test_pkg; no cross-directory includes). Cannot live inside
// scr1_mem_agent_pkg: that one is compiled AFTER the RTL while
// the harness needs the class before it (circular).
// ============================================================
`ifndef SCR1_MEM_MODEL_PKG_SV
`define SCR1_MEM_MODEL_PKG_SV

package scr1_mem_model_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;

    `include "uvm_macros.svh"

    `include "scr1_mem_model.sv"

endpackage : scr1_mem_model_pkg

`endif // SCR1_MEM_MODEL_PKG_SV
