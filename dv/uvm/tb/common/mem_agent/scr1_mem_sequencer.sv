// ============================================================
// File    : scr1_mem_sequencer.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Sequencer of the reactive AHB memory agent: the bus is answered
// autonomously by the driver's per-clock FSM (a slave cannot
// sequence the master's bus); this carries the SIDE-CHANNEL
// injection stimulus (scr1_mem_err_seq / scr1_mem_delay_seq items
// -> non-blocking injection state in the driver).
// ============================================================
  class scr1_mem_sequencer extends uvm_sequencer #(scr1_mem_txn);
    `uvm_component_utils(scr1_mem_sequencer)

    function new(string name = "scr1_mem_sequencer", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

  endclass : scr1_mem_sequencer
