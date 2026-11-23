// ============================================================
// File    : scr1_sequencer.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Sequencer: default uvm_sequencer parameterized with the
// program-run transaction (scr1_transaction).
// ============================================================
  class scr1_sequencer extends uvm_sequencer #(scr1_transaction);
    `uvm_component_utils(scr1_sequencer)

    function new(string name = "scr1_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

  endclass : scr1_sequencer
