// ============================================================
// File    : scr1_vsequencer.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Virtual sequencer (Sunburst Design pattern): holds handles to
// the real agent sequencers so a virtual sequence can coordinate
// cross-agent scenarios; it generates no items itself. Wired in
// scr1_env.connect_phase.
// ============================================================
  class scr1_vsequencer extends uvm_sequencer #(uvm_sequence_item);
    `uvm_component_utils(scr1_vsequencer)

    // handle to the real (agent) sequencer, assigned by scr1_env
    scr1_sequencer sqr;
    // reactive memory agent's injection sequencer (SCR1_MEM_AGENT only, null
    // on the legacy path) - concurrent scr1_mem_err_seq / delay windows
    scr1_mem_sequencer mem_sqr;
    // IRQ agent's sequencer (SCR1_MEM_AGENT only) - runs the IRQ stimulus
    // sequences concurrently with the program run
    scr1_irq_sequencer irq_sqr;

    function new(string name = "scr1_vsequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

  endclass : scr1_vsequencer
