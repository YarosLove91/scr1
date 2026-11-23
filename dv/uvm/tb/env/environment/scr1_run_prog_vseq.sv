// ============================================================
// File    : scr1_run_prog_vseq.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Run-program virtual sequence: starts the real scr1_run_prog_seq
// on the agent sequencer (p_sequencer.sqr). The test stays thin:
// it fills prog_paths (e.g. from +SCR1_TEST_HEX) and starts this
// vseq on env.v_sqr.
// ============================================================
  class scr1_run_prog_vseq extends scr1_base_vseq;
    `uvm_object_utils(scr1_run_prog_vseq)

    // test vectors to run, in order (passed through to the real seq)
    string prog_paths[$];

    function new(string name = "scr1_run_prog_vseq");
      super.new(name);
    endfunction : new

    task body();
      scr1_run_prog_seq seq;
      seq = scr1_run_prog_seq::type_id::create("seq");
      seq.prog_paths = prog_paths;
      seq.start(p_sequencer.sqr);
    endtask : body

  endclass : scr1_run_prog_vseq
