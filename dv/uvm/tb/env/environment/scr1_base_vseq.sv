// ============================================================
// File    : scr1_base_vseq.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Base virtual sequence (Sunburst Design pattern): started on
// scr1_vsequencer, never sends items itself - coordinates real
// sequences on the agent sequencers reachable through p_sequencer
// (typed handle via `uvm_declare_p_sequencer). Scenarios: program
// run + IRQ stimulus, injection/delay windows, multi-program
// series with per-run reset windows.
// ============================================================
  class scr1_base_vseq extends uvm_sequence #(uvm_sequence_item);
    `uvm_object_utils(scr1_base_vseq)
    `uvm_declare_p_sequencer(scr1_vsequencer)

    function new(string name = "scr1_base_vseq");
      super.new(name);
    endfunction : new

  endclass : scr1_base_vseq
