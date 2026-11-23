// ============================================================
// File    : scr1_agent_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Agent package: sequencer, driver, monitor and the agent.
// The sequence item (scr1_transaction) lives in scr1_seq_pkg, so
// the dependency chain is: scr1_tb_pkg -> scr1_seq_pkg ->
// scr1_agent_pkg.
// ============================================================
`ifndef SCR1_AGENT_PKG_SV
`define SCR1_AGENT_PKG_SV

package scr1_agent_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_tb_pkg::*;
    import scr1_seq_pkg::*;

    `include "uvm_macros.svh"

    `include "scr1_sequencer.sv"
    `include "scr1_driver.sv"
    `include "scr1_monitor.sv"
    `include "scr1_agent.sv"

endpackage : scr1_agent_pkg

`endif // SCR1_AGENT_PKG_SV
