// ============================================================
// File    : scr1_seq_delay_test.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Demo test for SEQUENCE-driven wait-state modulation (mem-agent
// rdelay side channel): runs a program vector (default hello)
// while scr1_seq_delay_vseq arms a delay window on the memory
// agent's injection sequencer (MEM_AGENT=1) - matching transfers
// take their address-phase wait states from the window instead of
// the +AGENT_* stall knobs.
//
//   make run TEST=scr1_seq_delay_test CROSS_PREFIX=<...>
//
// Default window: ALL dmem addresses, 0..3 wait states, unlimited
// count - the run lengthens vs the parity 16990 and is
// DETERMINISTIC (dedicated xorshift32 seeded by +AGENT_STALL_SEED).
// Overrides: +SEQ_DELAY_MIN/MAX/CH/LO/HI/COUNT;
// +SEQ_DELAY_DISABLE=1 skips the delay sequence (control: the
// plain run is reproduced exactly).
// ============================================================
  class scr1_seq_delay_test extends scr1_start_reset;
    `uvm_component_utils(scr1_seq_delay_test)

    function new(string name = "scr1_seq_delay_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual task body_seq();
      scr1_seq_delay_vseq vseq;
      string hex_path;
      string ch;
      int unsigned off;

      if (!$value$plusargs("SCR1_TEST_HEX=%s", hex_path)) begin
        hex_path = DEFAULT_TEST_HEX;
      end

      vseq = scr1_seq_delay_vseq::type_id::create("vseq");
      // optional delay-window overrides
      void'($value$plusargs("SEQ_DELAY_MIN=%d",   vseq.delay_min));
      void'($value$plusargs("SEQ_DELAY_MAX=%d",   vseq.delay_max));
      void'($value$plusargs("SEQ_DELAY_COUNT=%d", vseq.delay_count));
      void'($value$plusargs("SEQ_DELAY_LO=%h",    vseq.delay_lo));
      void'($value$plusargs("SEQ_DELAY_HI=%h",    vseq.delay_hi));
      if ($value$plusargs("SEQ_DELAY_CH=%s", ch)) begin
        vseq.delay_ch = ch;
      end
      off = 0;
      void'($value$plusargs("SEQ_DELAY_DISABLE=%d", off));
      vseq.delay_enable = !off[0];

      repeat (NUM_RUNS) begin
        vseq.prog_paths.push_back(hex_path);
      end
      `uvm_info({get_type_name(), ".SEQ"},
          $sformatf({"starting scr1_seq_delay_vseq on v_sqr: %0d run(s) of ",
                     "%s + sequence delay modulation (%s)"},
                     vseq.prog_paths.size(), hex_path,
                     vseq.delay_enable ? "enabled" : "disabled"),
          UVM_LOW)
      vseq.start(env_h.v_sqr);
    endtask : body_seq

  endclass : scr1_seq_delay_test
