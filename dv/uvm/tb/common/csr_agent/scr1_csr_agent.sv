// ============================================================
// File    : scr1_csr_agent.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR agent (ibex ibex_cosim_agent form): CSR golden-model checker
// layer - the M3/M7 scoreboard plus its OWN commit monitor (ibex
// rvfi_monitor pattern) and run_export; PASSIVE (checker never
// drives the core, no driver/sequencer). Streams: mon.ap ->
// scb.commit_imp (CSR-relevant events only); run_export ->
// scb.analysis_export (the scoreboard is a uvm_subscriber for the
// run-end snapshot). scb fetches the RAL model ("reg_top_model")
// from config_db itself. Details: dv/uvm/README.md (M3/M7).
// ============================================================
  class scr1_csr_agent extends uvm_agent;
    `uvm_component_utils(scr1_csr_agent)

    scr1_csr_monitor    mon;
    scr1_csr_scoreboard scb;

    // run-end stream (ibex dmem_port/imem_port pattern): exit CSR snapshot
    uvm_analysis_export #(scr1_transaction) run_export;

    function new(string name = "scr1_csr_agent", uvm_component parent = null);
      super.new(name, parent);
      run_export = new("run_export", this);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = scr1_csr_monitor::type_id::create("mon", this);
      scb = scr1_csr_scoreboard::type_id::create("scb", this);
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mon.ap.connect(scb.commit_imp);
      run_export.connect(scb.analysis_export);
    endfunction : connect_phase

  endclass : scr1_csr_agent
