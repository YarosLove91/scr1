// ============================================================
// File    : scr1_irq_agent_pkg.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ agent package (donor: ibex irq_agent_pkg - item, sequencer
// typedef, monitor/driver/agent + stimulus sequences; the vseq
// coordinator stays in scr1_env_pkg). Chain: scr1_cfg_pkg +
// scr1_irq_cfg_pkg + scr1_tb_pkg -> scr1_irq_agent_pkg ->
// scr1_env_pkg. Details: dv/uvm/README.md (milestone 6).
// ============================================================
`ifndef SCR1_IRQ_AGENT_PKG_SV
`define SCR1_IRQ_AGENT_PKG_SV

package scr1_irq_agent_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_irq_cfg_pkg::*;
    import scr1_tb_pkg::*;

    `include "uvm_macros.svh"

    `include "scr1_irq_seq_item.sv"

    // ibex irq_agent_pkg pattern: a plain parameterized sequencer
    typedef uvm_sequencer#(scr1_irq_seq_item) scr1_irq_sequencer;

    `include "scr1_irq_monitor.sv"
    `include "scr1_irq_driver.sv"
    `include "scr1_irq_agent.sv"
    `include "scr1_irq_base_seq.sv"
    `include "scr1_irq_single_seq.sv"
    `include "scr1_irq_random_seq.sv"

endpackage : scr1_irq_agent_pkg

`endif // SCR1_IRQ_AGENT_PKG_SV
