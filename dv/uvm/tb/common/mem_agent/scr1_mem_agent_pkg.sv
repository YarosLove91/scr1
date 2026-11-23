// ============================================================
// File    : scr1_mem_agent_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Reactive AHB memory agent package (stage B, MEM_AGENT=1).
// Chain: scr1_tb_pkg (model + vif + g_mem_model) ->
// scr1_mem_agent_pkg -> scr1_env_pkg. The scoreboard is included
// BEFORE the agent (the agent declares the handle) and is OWNED
// by it (the ibex_cosim_agent cohesion pattern).
// ============================================================
`ifndef SCR1_MEM_AGENT_PKG_SV
`define SCR1_MEM_AGENT_PKG_SV

package scr1_mem_agent_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_mem_model_pkg::*;
    import scr1_tb_pkg::*;

    `include "uvm_macros.svh"

    `include "scr1_mem_txn.sv"
    `include "scr1_mem_sequencer.sv"
    `include "scr1_mem_err_seq.sv"
    `include "scr1_mem_delay_seq.sv"
    `include "scr1_mem_driver.sv"
    `include "scr1_mem_monitor.sv"
    `include "scr1_mem_scoreboard.sv"
    `include "scr1_mem_agent.sv"

endpackage : scr1_mem_agent_pkg

`endif // SCR1_MEM_AGENT_PKG_SV
