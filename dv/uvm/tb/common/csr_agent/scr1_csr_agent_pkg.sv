// ============================================================
// File    : scr1_csr_agent_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR agent package (ibex pkg pattern): the M3/M7 CSR scoreboard,
// own monitor and passive agent next to the RAL model they consume.
// Chain: scr1_csr_ral_pkg -> scr1_seq_pkg -> scr1_csr_agent_pkg ->
// scr1_cosim_agent_pkg -> scr1_env_pkg.
// ============================================================
`ifndef SCR1_CSR_AGENT_PKG_SV
`define SCR1_CSR_AGENT_PKG_SV

package scr1_csr_agent_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_tb_pkg::*;
    import scr1_seq_pkg::*;
    import scr1_csr_ral_pkg::*;

    `include "uvm_macros.svh"

    // imp_decl: scoreboard keeps the inherited subscriber write() for the
    // run stream and gains write_csr() for the commit stream
    `uvm_analysis_imp_decl(_csr)

    `include "scr1_csr_scoreboard.sv"
    `include "scr1_csr_monitor.sv"
    `include "scr1_csr_agent.sv"

endpackage : scr1_csr_agent_pkg

`endif // SCR1_CSR_AGENT_PKG_SV
