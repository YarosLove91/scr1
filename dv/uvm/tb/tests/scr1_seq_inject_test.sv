// ============================================================
// File    : scr1_seq_inject_test.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Demo test for SEQUENCE-driven memory ERROR injection: runs the
// paired directed vector (sw_directed/scr1_seq_inject.S - console
// stores + trap handler) while scr1_seq_inject_vseq arms hresp
// ERROR on the console word address THROUGH A SEQUENCE on the
// memory agent's injection sequencer (MEM_AGENT=1).
//
//   make -C dv/fuzz seq_inject CROSS_PREFIX=<...>
//
// Expected: the console stores fault (mcause=7, TRAP commits in
// the log), the handler skips them, exit a0=0 -> PASS - the exact
// effect of +AGENT_DMEM_ERROR_ADDR=f0000000 via a sequence.
// Overrides: +SEQ_INJECT_ADDR / +SEQ_INJECT_COUNT /
// +SEQ_INJECT_IMEM=1.
// ============================================================
  class scr1_seq_inject_test extends scr1_start_reset;
    `uvm_component_utils(scr1_seq_inject_test)

    function new(string name = "scr1_seq_inject_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual task body_seq();
      scr1_seq_inject_vseq vseq;
      string hex_path;
      int unsigned imem_sel;

      if (!$value$plusargs("SCR1_TEST_HEX=%s", hex_path)) begin
        hex_path = DEFAULT_TEST_HEX;
      end

      vseq = scr1_seq_inject_vseq::type_id::create("vseq");
      // optional injection-target overrides
      void'($value$plusargs("SEQ_INJECT_ADDR=%h",  vseq.inj_addr));
      void'($value$plusargs("SEQ_INJECT_COUNT=%d", vseq.inj_count));
      imem_sel = 0;
      void'($value$plusargs("SEQ_INJECT_IMEM=%d",  imem_sel));
      vseq.inj_imem = imem_sel[0];

      repeat (NUM_RUNS) begin
        vseq.prog_paths.push_back(hex_path);
      end
      `uvm_info({get_type_name(), ".SEQ"},
          $sformatf("starting scr1_seq_inject_vseq on v_sqr: %0d run(s) of %s + sequence ERROR injection",
                    vseq.prog_paths.size(), hex_path),
          UVM_LOW)
      vseq.start(env_h.v_sqr);
    endtask : body_seq

  endclass : scr1_seq_inject_test
