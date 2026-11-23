// ============================================================
// File    : scr1_cosim_agent.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Cosim agent (ibex ibex_cosim_agent pattern): cfg + reference
// backends + own commit monitor + scoreboard; PASSIVE (the ref
// model never drives the core, no driver/sequencer). Streams:
// mon.ap -> scb.commit_imp; run_export -> scb.run_imp (both via
// `uvm_analysis_imp_decl - verified working on 5.053 stack).
// Details: dv/uvm/README.md (cosim sections).
// ============================================================
  class scr1_cosim_agent extends uvm_agent;
    `uvm_component_utils(scr1_cosim_agent)

    scr1_cosim_monitor    mon;
    scr1_cosim_scoreboard scb;

    // run-end stream (ibex dmem_port/imem_port pattern): exit CSR snapshot
    uvm_analysis_export #(scr1_transaction) run_export;

    function new(string name = "scr1_cosim_agent", uvm_component parent = null);
      super.new(name, parent);
      run_export = new("run_export", this);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // scb fetches scr1_cosim_cfg from uvm_config_db itself (ibex flow)
      mon = scr1_cosim_monitor::type_id::create("mon", this);
      scb = scr1_cosim_scoreboard::type_id::create("scb", this);
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mon.ap.connect(scb.commit_imp);
      run_export.connect(scb.run_imp);
    endfunction : connect_phase

  endclass : scr1_cosim_agent
