// ============================================================
// File    : scr1_cosim_agent_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Cosim agent package (ibex ibex_cosim_agent_pkg pattern): cfg,
// reference backends and the passive agent, next to the DPI source.
// Chain: scr1_tb_pkg -> scr1_seq_pkg -> scr1_cosim_agent_pkg ->
// scr1_env_pkg. Details: dv/uvm/README.md (milestones 2A/2B).
// ============================================================
`ifndef SCR1_COSIM_AGENT_PKG_SV
`define SCR1_COSIM_AGENT_PKG_SV

package scr1_cosim_agent_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_tb_pkg::*;
    import scr1_seq_pkg::*;

    `include "uvm_macros.svh"

    // multi-stream TLM entries; imp_decl verified working on the current
    // 5.053 + uvm-verilator stack (the old "broken" trap does not reproduce)
    `uvm_analysis_imp_decl(_commit)
    `uvm_analysis_imp_decl(_run)

    `include "scr1_cosim_cfg.sv"
`ifdef SCR1_SPIKE_COSIM
    // DPI-C boundary of the in-process Spike (ibex spike_cosim_dpi.svh)
    `include "spike_cosim_dpi.svh"
`endif
    // ref backends behind one pull interface: 2A CSV replay (SCR1-specific,
    // no ibex analogue) + 2B in-process Spike
    `include "scr1_ref_model.sv"
`ifdef SCR1_SPIKE_COSIM
    `include "scr1_ref_spike.sv"
`endif
    `include "scr1_cosim_monitor.sv"
    `include "scr1_cosim_scoreboard.sv"
    `include "scr1_cosim_agent.sv"

endpackage : scr1_cosim_agent_pkg

`endif // SCR1_COSIM_AGENT_PKG_SV
