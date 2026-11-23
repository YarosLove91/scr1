// ============================================================
// File    : scr1_agent.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Agent: sequencer + driver + monitor (active by default).
// ============================================================
  class scr1_agent extends uvm_agent;
    `uvm_component_utils(scr1_agent)

    scr1_sequencer sqr;
    scr1_driver    drv;
    scr1_monitor   mon;

    function new(string name = "scr1_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = scr1_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = scr1_sequencer::type_id::create("sqr", this);
        drv = scr1_driver::type_id::create("drv", this);
      end
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (get_is_active() == UVM_ACTIVE) begin
        drv.seq_item_port.connect(sqr.seq_item_export);
      end
    endfunction : connect_phase

  endclass : scr1_agent
