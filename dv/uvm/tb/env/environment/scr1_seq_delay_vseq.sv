// ============================================================
// File    : scr1_seq_delay_vseq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Demo vseq for SEQUENCE-driven wait-state modulation (mem-agent
// rdelay side channel): forks the normal program run against a
// scr1_mem_delay_seq on p_sequencer.mem_sqr - wait states are
// modulated at runtime by a SEQUENCE, not by the +AGENT_*_STALL
// plusargs. Default window: ALL dmem addresses, 0..3 cycles per
// transfer (dedicated seeded xorshift32, bit-reproducible),
// unlimited count; the window OVERRIDES the stall knobs (full
// contract incl. the +1 idle-gating cycle: scr1_mem_driver /
// scr1_mem_delay_seq). delay_enable=0 (+SEQ_DELAY_DISABLE=1)
// skips the delay sequence - the run reproduces the parity cycle
// count bit-for-bit. Requires MEM_AGENT=1; the bus FSM is never
// blocked (the driver pulls items in a separate process).
// ============================================================
  class scr1_seq_delay_vseq extends scr1_base_vseq;
    `uvm_object_utils(scr1_seq_delay_vseq)

    // program vectors to run (passed through to scr1_run_prog_seq)
    string prog_paths[$];

    // delay window spec (overridable via +SEQ_DELAY_* plusargs in the test)
    ahb_addr_t   delay_lo;      // window lower bound (byte address)
    ahb_addr_t   delay_hi;      // window upper bound (inclusive)
    int unsigned delay_min;     // min wait states (item rdelay)
    int unsigned delay_max;     // max wait states (item rdelay_max)
    string       delay_ch;      // "dmem" | "imem" | "both"
    int unsigned delay_count;   // modulated transfers (0 = unlimited)
    bit          delay_enable;  // 0 = skip the delay sequence (control)

    function new(string name = "scr1_seq_delay_vseq");
      super.new(name);
      delay_lo     = '0;
      delay_hi     = '1;
      delay_min    = 0;
      delay_max    = 3;
      delay_ch     = "dmem";
      delay_count  = 0;
      delay_enable = 1'b1;
    endfunction : new

    virtual task body();
      scr1_run_prog_seq  seq;
      scr1_mem_delay_seq dly_seq;

      if (p_sequencer.mem_sqr == null) begin
        `uvm_fatal({get_type_name(), ".NOMEMSQR"},
            {"sequence-driven delay modulation needs the reactive memory ",
             "agent (MEM_AGENT=1): v_sqr.mem_sqr is null"})
      end

      if (delay_enable) begin
        `uvm_info({get_type_name(), ".CFG"},
            $sformatf({"seq delay modulation: ch=%s range 0x%08h..0x%08h ",
                       "delay %0d..%0d count=%0d (0 = unlimited) ",
                       "(sequence-driven, not a plusarg)"},
                delay_ch, delay_lo, delay_hi, delay_min, delay_max,
                delay_count),
            UVM_LOW)
      end else begin
        `uvm_info({get_type_name(), ".CFG"},
            "seq delay modulation DISABLED (+SEQ_DELAY_DISABLE) - plain run",
            UVM_LOW)
      end

      fork
        begin
          seq = scr1_run_prog_seq::type_id::create("seq");
          seq.prog_paths = prog_paths;
          seq.start(p_sequencer.sqr);
        end
        begin
          if (delay_enable) begin
            dly_seq = scr1_mem_delay_seq::type_id::create("dly_seq");
            dly_seq.add_delay(delay_lo, delay_hi, delay_min, delay_max,
                              delay_ch, delay_count);
            dly_seq.start(p_sequencer.mem_sqr);
          end
        end
      join
    endtask : body

  endclass : scr1_seq_delay_vseq
