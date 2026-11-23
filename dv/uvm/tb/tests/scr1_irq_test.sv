// ============================================================
// File    : scr1_irq_test.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ-agent test: runs a program vector while scr1_irq_run_vseq
// injects asynchronous ext + soft interrupts through the
// scr1_irq_agent (its driver is the single source of the TB
// stimulus lines; the program-driven device registers OR into the
// core pins inside scr1_irq_if). Pair with sim/tests/irq_ext:
//
//   make run TEST=scr1_irq_test SW_TEST=irq_ext MEM_AGENT=1 CROSS_PREFIX=<...>
//
// No Spike lockstep (2B models no IRQ devices); verdict = the a0
// pass/fail convention + the CSR RAL checks. Stimulus timing via
// the +IRQ_* plusargs. Details: dv/uvm/README.md (milestone 6).
// ============================================================
  class scr1_irq_test extends scr1_start_reset;
    `uvm_component_utils(scr1_irq_test)

    function new(string name = "scr1_irq_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual task body_seq();
      scr1_irq_run_vseq vseq;
      string hex_path;
      int guar_arg;

      if (!$value$plusargs("SCR1_TEST_HEX=%s", hex_path)) begin
        hex_path = DEFAULT_TEST_HEX;
      end

      vseq = scr1_irq_run_vseq::type_id::create("vseq");
      // optional stimulus-timing overrides (single ext + soft pulse)
      void'($value$plusargs("IRQ_EXT_DELAY=%d",  vseq.ext_delay));
      void'($value$plusargs("IRQ_EXT_WIDTH=%d",  vseq.ext_width));
      void'($value$plusargs("IRQ_SOFT_DELAY=%d", vseq.soft_delay));
      void'($value$plusargs("IRQ_SOFT_WIDTH=%d", vseq.soft_width));
      // optional random multi-pulse scenario (pair with sim/tests/irq_stress);
      // random_count==0 keeps the single-pulse path bit-exact
      void'($value$plusargs("IRQ_RANDOM=%d",    vseq.random_count));
      void'($value$plusargs("IRQ_SEED=%d",      vseq.random_seed));
      void'($value$plusargs("IRQ_MASK_MODE=%s", vseq.mask_mode));
      // guaranteed-service concurrent soft pulse (random mode, default ON);
      // +IRQ_SOFT_GUAR=0 restores the narrow pulse (may legitimately expire
      // unserviced during an ext storm)
      if ($value$plusargs("IRQ_SOFT_GUAR=%d", guar_arg)) begin
        vseq.soft_guar = guar_arg[0];
      end
      repeat (NUM_RUNS) begin
        vseq.prog_paths.push_back(hex_path);
      end
      `uvm_info({get_type_name(), ".SEQ"},
          $sformatf("starting scr1_irq_run_vseq on v_sqr: %0d run(s) of %s + IRQ stimulus",
                    vseq.prog_paths.size(), hex_path),
          UVM_LOW)
      vseq.start(env_h.v_sqr);
    endtask : body_seq

  endclass : scr1_irq_test
