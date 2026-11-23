// ============================================================
// File    : scr1_mem_agent.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Reactive AHB memory agent (stage B, MEM_AGENT=1; donor:
// ibex_mem_intf_response_agent). Sequencer = side-channel for the
// injection sequences ONLY; driver = reactive bus FSM + the
// non-blocking injection process; monitor = completed transfers;
// scoreboard = agent-owned protocol subscriber (ibex cohesion
// pattern, created regardless of is_active). build_phase publishes
// g_mem_model BEFORE the children - the DUT harness reaches the
// model through that global (stage-A load/peek/poke unchanged).
// ============================================================
  class scr1_mem_agent extends uvm_agent;
    `uvm_component_utils(scr1_mem_agent)

    scr1_mem_sequencer  sqr;
    scr1_mem_driver     drv;
    scr1_mem_monitor    mon;
    scr1_mem_scoreboard scb;

    function new(string name = "scr1_mem_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // the shared memory + device model (harness-side global)
      if (g_mem_model == null) begin
        g_mem_model = scr1_mem_model::type_id::create("g_mem_model");
        `uvm_info({get_type_name(), ".MODEL"},
            "scr1_tb_pkg::g_mem_model created (load/peek/poke go through it)",
            UVM_MEDIUM)
      end
      mon = scr1_mem_monitor::type_id::create("mon", this);
      scb = scr1_mem_scoreboard::type_id::create("scb", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = scr1_mem_sequencer::type_id::create("sqr", this);
        drv = scr1_mem_driver::type_id::create("drv", this);
      end
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      // protocol checks + traffic counters (agent-owned subscriber)
      mon.ap.connect(scb.analysis_export);
      if (get_is_active() == UVM_ACTIVE) begin
        drv.seq_item_port.connect(sqr.seq_item_export);
      end
    endfunction : connect_phase

  endclass : scr1_mem_agent
