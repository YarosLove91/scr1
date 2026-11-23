// ============================================================
// File    : scr1_env.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Environment topology:
//
//   agt(mon) --ap--------> scb  (run verdict: exit/a0/console)
//
// The CSR and cosim agents own their golden-model checkers (ibex
// pattern): their monitors sample the commit channel themselves;
// the env only builds the cosim cfg and feeds the run-end streams:
//
//   agt(mon) --ap (run tr)-> csr_agt.run_export   -> csr_agt.scb   (M3+M7)
//   agt(mon) --ap (run tr)-> cosim_agt.run_export -> cosim_agt.scb (2A/2B)
//
// RAL: scr1_csr_top_block is built/locked/reset here and published
// via config_db (uvm_root, "*", "reg_top_model"); the CSR agent's
// scoreboard fetches it. v_sqr (virtual sequencer, Sunburst
// pattern) holds the agent sequencer handles for virtual sequences.
// ============================================================
  class scr1_env extends uvm_env;
    `uvm_component_utils(scr1_env)

    scr1_agent            agt;

    scr1_scoreboard       scb;

    scr1_csr_agent        csr_agt;       // CSR golden-model checker agent (ibex pattern)
    scr1_cosim_agent      cosim_agt;     // reference-model agent (ibex pattern)
    scr1_cosim_cfg        cosim_cfg;
    scr1_vsequencer       v_sqr;
`ifdef SCR1_MEM_AGENT
    // stage B: reactive AHB memory agent (replaces the legacy
    // scr1_memory_tb_ahb in the harness); owns its protocol scoreboard
    // and the injection sequencer; mon.ap doubles as the DRVFuzz hook
    scr1_mem_agent        mem_agt;
    // ibex-style IRQ agent: TB stimulus owner of the core interrupt pins;
    // gated with the mem agent (MEM_AGENT=0 keeps the pins on the native
    // device window, bit-exact)
    scr1_irq_agent        irq_agt;
`endif // SCR1_MEM_AGENT

    // CSR RAL model (milestone 3)
    scr1_csr_top_block    reg_top_model;

    function new(string name = "scr1_env", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      string ref_path;
      super.build_phase(phase);

      // RAL model: create -> build -> lock -> reset, publish via config_db
      reg_top_model = scr1_csr_top_block::type_id::create("reg_top_model");
      reg_top_model.build();
      reg_top_model.lock_model();
      reg_top_model.reset();
      uvm_config_db#(scr1_csr_top_block)::set(uvm_root::get(), "*",
                                              "reg_top_model", reg_top_model);

      agt     = scr1_agent::type_id::create("agt", this);
      scb     = scr1_scoreboard::type_id::create("scb", this);
      csr_agt = scr1_csr_agent::type_id::create("csr_agt", this);
      v_sqr   = scr1_vsequencer::type_id::create("v_sqr", this);
`ifdef SCR1_MEM_AGENT
      // built before the run: its build_phase publishes g_mem_model for the
      // harness loader
      mem_agt = scr1_mem_agent::type_id::create("mem_agt", this);
      irq_agt = scr1_irq_agent::type_id::create("irq_agt", this);
`endif // SCR1_MEM_AGENT

      // cosim cfg (ibex core_ibex_cosim_cfg flow): backend plusargs become
      // config-object fields; +SPIKE_HEX wins over +REF_CSV; COSIM_NONE
      // keeps the agent inert (differential checks disabled)
      cosim_cfg = scr1_cosim_cfg::type_id::create("cosim_cfg");
`ifdef SCR1_SPIKE_COSIM
      if ($value$plusargs("SPIKE_HEX=%s", ref_path)) begin
        cosim_cfg.mode     = COSIM_SPIKE;
        cosim_cfg.hex_path = ref_path;
      end else
`endif
      if ($value$plusargs("REF_CSV=%s", ref_path)) begin
        cosim_cfg.mode     = COSIM_CSV;
        cosim_cfg.csv_path = ref_path;
      end
      uvm_config_db#(scr1_cosim_cfg)::set(this, "*", "cosim_cfg", cosim_cfg);
      cosim_agt = scr1_cosim_agent::type_id::create("cosim_agt", this);
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agt.mon.ap.connect(scb.analysis_export);
      // CSR agent: the commit channel is sampled by its OWN monitor; the env
      // only feeds the run-end stream (exit CSR snapshots)
      agt.mon.ap.connect(csr_agt.run_export);
      // cosim agent: own monitor samples commits into scb.commit_imp; the env
      // feeds the run-exit transactions (CSR snapshot) for phase B
      agt.mon.ap.connect(cosim_agt.run_export);
      // virtual sequencer wiring (agent is active in the env)
      if (agt.get_is_active() == UVM_ACTIVE) begin
        v_sqr.sqr = agt.sqr;
      end
`ifdef SCR1_MEM_AGENT
      // expose the memory agent's injection sequencer to virtual sequences
      if (mem_agt.get_is_active() == UVM_ACTIVE) begin
        v_sqr.mem_sqr = mem_agt.sqr;
      end
      // (the mem-agent protocol scoreboard is agent-owned, wired inside it)
      // expose the IRQ sequencer to vseqs; the monitor ap stays a free hook -
      // IRQ coverage is sampled from the commit stream in scr1_fcov_if
      if (irq_agt.get_is_active() == UVM_ACTIVE) begin
        v_sqr.irq_sqr = irq_agt.sqr;
      end
`endif // SCR1_MEM_AGENT
    endfunction : connect_phase

  endclass : scr1_env
