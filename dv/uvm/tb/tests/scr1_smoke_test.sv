// ============================================================
// File    : scr1_smoke_test.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Smoke test: the sequence passes the vector path to the driver;
// the driver loads it, releases the reset and waits for the exit
// PC; monitor/scoreboard check a0 == 0 (the SCR1 pass/fail
// convention). Vector: +SCR1_TEST_HEX=<path> or the Makefile
// SW_TEST build (default DEFAULT_TEST_HEX); NUM_RUNS repetitions
// of the same vector.
// ============================================================

  class scr1_smoke_test extends scr1_start_reset;
    `uvm_component_utils(scr1_smoke_test)

    function new(string name = "scr1_smoke_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual task body_seq();
      scr1_run_prog_vseq vseq;
      string hex_path;

      if (!$value$plusargs("SCR1_TEST_HEX=%s", hex_path)) begin
        hex_path = DEFAULT_TEST_HEX;
      end

      // virtual sequence on the virtual sequencer: the scenario
      // wrapper starts the real scr1_run_prog_seq on the agent sqr
      vseq = scr1_run_prog_vseq::type_id::create("vseq");
      repeat (NUM_RUNS) begin
        vseq.prog_paths.push_back(hex_path);
      end
      `uvm_info({get_type_name(), ".SEQ"},
          $sformatf("starting scr1_run_prog_vseq on v_sqr: %0d run(s) of %s",
                    vseq.prog_paths.size(), hex_path),
          UVM_LOW)
      vseq.start(env_h.v_sqr);
    endtask : body_seq

  endclass : scr1_smoke_test
