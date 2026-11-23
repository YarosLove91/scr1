// ============================================================
// File    : scr1_irq_run_vseq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ-agent virtual sequence ("program run + IRQ stimulus"):
// forks scr1_run_prog_seq on the agent sequencer against the IRQ
// stimulus sequences on v_sqr.irq_sqr (ibex irq_agent pattern).
// The stimulus lives in the agent sequences: scr1_irq_single_seq
// (single ext+soft pulse, +IRQ_*) or scr1_irq_random_seq
// (deterministic LCG multi-pulse schedule). Timing is relative to
// the core clk/reset observed on irq_vif; with NUM_RUNS > 1 the
// stimulus re-executes for EVERY run (aligned to each reset
// release, random re-seeds with seed+run_index). Requires
// MEM_AGENT=1. No Spike lockstep: the 2B reference models no IRQ
// devices. Details: dv/uvm/README.md (milestone 6).
// ============================================================
  class scr1_irq_run_vseq extends scr1_base_vseq;
    `uvm_object_utils(scr1_irq_run_vseq)

    // program vectors to run (passed through to scr1_run_prog_seq)
    string prog_paths[$];

    // single-pulse stimulus timing, cycles (+IRQ_* plusargs via scr1_irq_test)
    int unsigned ext_delay;
    int unsigned ext_width;
    int unsigned soft_delay;
    int unsigned soft_width;

    // external IRQ line mask (EXT_IRQ_LINE from cfg: IPIC line 9 / common 0)
    irq_lines_t ext_mask;

    // ---- random-scenario controls (+IRQ_RANDOM / +IRQ_SEED /
    //      +IRQ_MASK_MODE / +IRQ_SOFT_GUAR); random_count == 0 keeps the
    //      single-pulse path (irq_ext), > 0 selects the random series ----
    int unsigned random_count;
    int unsigned random_seed;
    string       mask_mode;          // "fixed9" | "random16" | "all16"
    bit          soft_guar;          // guaranteed-service concurrent soft

    // IRQ interface for the clock/reset-relative run alignment
    scr1_irq_vif irq_vif;

    function new(string name = "scr1_irq_run_vseq");
      super.new(name);
      ext_delay    = IRQ_EXT_DELAY_DFLT;
      ext_width    = IRQ_EXT_WIDTH_DFLT;
      soft_delay   = IRQ_SOFT_DELAY_DFLT;
      soft_width   = IRQ_SOFT_WIDTH_DFLT;
      random_count = IRQ_RANDOM_DFLT;
      random_seed  = IRQ_SEED_DFLT;
      mask_mode    = IRQ_MASK_MODE_DFLT;
      soft_guar    = IRQ_SOFT_GUAR_DFLT;
      ext_mask     = '0;
      ext_mask[EXT_IRQ_LINE] = 1'b1;
    endfunction : new

    virtual task body();
      scr1_run_prog_seq seq;

      if (p_sequencer.irq_sqr == null) begin
        `uvm_fatal({get_type_name(), ".NOSQR"},
            {"IRQ stimulus needs the IRQ agent sequencer (MEM_AGENT=1): ",
             "v_sqr.irq_sqr is null"})
      end
      if (!uvm_config_db#(scr1_irq_vif)::get(null, "*", "irq_vif", irq_vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "irq_vif not found in uvm_config_db (IRQ stimulus timing)")
      end

      if (random_count > 0) begin
        string smsg;
        smsg = $sformatf(
            "IRQ RANDOM scenario: pulses=%0d seed=%0d mask_mode=%s setup_delay=%0d runs=%0d",
            random_count, random_seed, mask_mode, RAND_SETUP_DELAY, NUM_RUNS);
        `uvm_info({get_type_name(), ".CFG"}, smsg, UVM_LOW)
      end else begin
        string lmsg;
        lmsg = $sformatf(
            {"IRQ stimulus: ext_line=%0d (mask 0x%04h) ext_delay=%0d ",
             "ext_width=%0d soft_delay=%0d soft_width=%0d runs=%0d"},
            EXT_IRQ_LINE, ext_mask, ext_delay, ext_width,
            soft_delay, soft_width, NUM_RUNS);
        `uvm_info({get_type_name(), ".CFG"}, lmsg, UVM_LOW)
      end

      fork
        begin
          seq = scr1_run_prog_seq::type_id::create("seq");
          seq.prog_paths = prog_paths;
          seq.start(p_sequencer.sqr);
        end
        begin
          run_stimulus();
        end
      join
    endtask : body

    // Per-run stimulus loop (NUM_RUNS > 1): the driver reloads and
    // re-asserts reset between runs, so the scenario restarts for EVERY
    // run aligned to its reset release (random re-seeds with
    // random_seed+run_index, still ONE single-threaded LCG pass per run).
    // The reset fall can land INSIDE the schedule tail (irq_ext exits as
    // soon as both IRQs are serviced), so a plain level wait could miss
    // the boundary: a clk-sampled watcher counts rst_n falls and the loop
    // consumes exactly one fall per completed run.
    int unsigned rst_falls;   // rst_n 1->0 transitions since t0
    bit          rst_prev;

    protected task rst_fall_watch();
      rst_prev = (irq_vif.rst_n === 1'b1);
      forever begin
        @(posedge irq_vif.clk);
        if (rst_prev && (irq_vif.rst_n === 1'b0)) begin
          rst_falls++;
        end
        rst_prev = (irq_vif.rst_n === 1'b1);
      end
    endtask : rst_fall_watch

    protected task run_stimulus();
      int unsigned run_index;
      int unsigned falls_base;
      fork
        rst_fall_watch();
      join_none
      run_index = 0;
      forever begin
        // align to the run start: reset release (the core starts fetching)
        @(posedge irq_vif.clk);
        wait (irq_vif.rst_n === 1'b1);
        @(posedge irq_vif.clk);
        falls_base = rst_falls;

        if (random_count > 0) begin
          start_random_run(run_index);
        end else begin
          start_single_run(run_index);
        end

        run_index++;
        if (run_index >= NUM_RUNS) begin
          break;
        end
        // run boundary: wait for the driver's reset fall of the next run
        while (rst_falls == falls_base) begin
          @(posedge irq_vif.clk);
        end
      end
      disable fork;   // stop the fall watcher
    endtask : run_stimulus

    // one run of the legacy single ext + single soft pulse scenario
    protected task start_single_run(int unsigned run_index);
      scr1_irq_single_seq seq;
      string rmsg;
      rmsg = $sformatf("run %0d/%0d: ext+soft single-pulse stimulus",
                       run_index + 1, NUM_RUNS);
      `uvm_info({get_type_name(), ".IRQ_RUN"}, rmsg, UVM_LOW)
      seq = scr1_irq_single_seq::type_id::create("irq_single_seq");
      seq.ext_delay  = ext_delay;
      seq.ext_width  = ext_width;
      seq.soft_delay = soft_delay;
      seq.soft_width = soft_width;
      seq.ext_mask   = ext_mask;
      seq.start(p_sequencer.irq_sqr);
    endtask : start_single_run

    // one run of the random multi-pulse scenario (seed+run_index)
    protected task start_random_run(int unsigned run_index);
      scr1_irq_random_seq seq;
      string rmsg;
      rmsg = $sformatf("run %0d/%0d: random multi-pulse schedule",
                       run_index + 1, NUM_RUNS);
      `uvm_info({get_type_name(), ".IRQ_RUN"}, rmsg, UVM_LOW)
      seq = scr1_irq_random_seq::type_id::create("irq_random_seq");
      seq.random_count = random_count;
      seq.run_seed     = random_seed + run_index;
      seq.mask_mode    = mask_mode;
      seq.soft_guar    = soft_guar;
      seq.start(p_sequencer.irq_sqr);
    endtask : start_random_run

  endclass : scr1_irq_run_vseq
