// ============================================================
// File    : scr1_env_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Environment package: scoreboard, virtual sequencer and the
// env. Dependency chain: scr1_seq_pkg -> scr1_agent_pkg ->
// scr1_irq_agent_pkg -> scr1_csr_agent_pkg -> scr1_cosim_agent_pkg
// -> scr1_env_pkg.
// ============================================================
`ifndef SCR1_ENV_PKG_SV
`define SCR1_ENV_PKG_SV

package scr1_env_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_irq_cfg_pkg::*;
    import scr1_tb_pkg::*;
    import scr1_csr_ral_pkg::*;
    import scr1_seq_pkg::*;
    import scr1_agent_pkg::*;
    import scr1_mem_agent_pkg::*;
    import scr1_irq_agent_pkg::*;
    import scr1_csr_agent_pkg::*;
    import scr1_cosim_agent_pkg::*;

    `include "uvm_macros.svh"

    // custom UVM report server (SNUG 2013 pattern; installed by
    // scr1_base_test). The CSR / cosim checker layers live in their agent
    // packages, imported above.
    `include "scr1_report_server.sv"
    `include "scr1_scoreboard.sv"
    `include "scr1_vsequencer.sv"
    // virtual sequences (after the vsequencer type they are typed on)
    `include "scr1_base_vseq.sv"
    `include "scr1_run_prog_vseq.sv"
    `include "scr1_irq_run_vseq.sv"
    `include "scr1_seq_inject_vseq.sv"
    `include "scr1_seq_delay_vseq.sv"
    `include "scr1_env.sv"

endpackage : scr1_env_pkg

`endif // SCR1_ENV_PKG_SV
