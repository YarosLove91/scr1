// ============================================================
// File    : scr1_irq_agent.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// SCR1 IRQ agent (donor: ibex irq_request_agent) - single owner
// of the core interrupt-pin TB stimulus: plain sequencer typedef;
// driver = the ONLY driver of the scr1_irq_if stimulus lines;
// monitor = one item per core-pin transition. Details:
// dv/uvm/README.md (milestone 6).
// ============================================================
  class scr1_irq_agent extends uvm_agent;
    `uvm_component_utils(scr1_irq_agent)

    scr1_irq_sequencer sqr;
    scr1_irq_driver    drv;
    scr1_irq_monitor   mon;

    function new(string name = "scr1_irq_agent", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = scr1_irq_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        sqr = scr1_irq_sequencer::type_id::create("sqr", this);
        drv = scr1_irq_driver::type_id::create("drv", this);
      end
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (get_is_active() == UVM_ACTIVE) begin
        drv.seq_item_port.connect(sqr.seq_item_export);
      end
    endfunction : connect_phase

  endclass : scr1_irq_agent
