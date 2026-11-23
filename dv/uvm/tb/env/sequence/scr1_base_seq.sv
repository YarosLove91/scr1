// ============================================================
// File    : scr1_base_seq.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Base sequence: common factory/constructor plumbing for the
// SCR1 program-run sequences (item type scr1_transaction).
// ============================================================
  class scr1_base_seq extends uvm_sequence #(scr1_transaction);
    `uvm_object_utils(scr1_base_seq)

    function new(string name = "scr1_base_seq");
      super.new(name);
    endfunction : new

  endclass : scr1_base_seq
