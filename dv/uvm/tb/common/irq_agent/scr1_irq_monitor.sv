// ============================================================
// File    : scr1_irq_monitor.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ agent monitor (donor: ibex irq_monitor - collect on change,
// not every cycle). Samples the pins the core actually sees
// (core_ext_lines/core_soft_irq = agent stimulus OR device mirror)
// through monitor_cb, one item per transition; while reset is
// asserted the state silently resyncs to zero (no items on the
// NUM_RUNS per-run reset boundaries).
// ============================================================
  class scr1_irq_monitor extends uvm_monitor;
    `uvm_component_utils(scr1_irq_monitor)

    scr1_irq_vif vif;

    // observed-state memory (transition detector)
    protected irq_lines_t prev_ext;
    protected bit                     prev_soft;

    uvm_analysis_port#(scr1_irq_seq_item) ap;

    function new(string name = "scr1_irq_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_irq_vif)::get(this, "", "irq_vif", vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "irq_vif not found in uvm_config_db (IRQ agent build?)")
      end
      prev_ext  = '0;
      prev_soft = 1'b0;
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      irq_lines_t cur_ext;
      bit                     cur_soft;
      scr1_irq_seq_item       item;
      super.run_phase(phase);
      forever begin
        @(vif.monitor_cb);
        if (vif.monitor_cb.rst_n !== 1'b1) begin
          // reset: the pins are driven low - resync silently
          prev_ext  = '0;
          prev_soft = 1'b0;
          continue;
        end
        cur_ext  = vif.monitor_cb.core_ext_lines;
        cur_soft = vif.monitor_cb.core_soft_irq;
        if ((cur_ext !== prev_ext) || (cur_soft !== prev_soft)) begin
          prev_ext  = cur_ext;
          prev_soft = cur_soft;
          item = scr1_irq_seq_item::type_id::create("irq_item");
          item.ext_mask         = cur_ext;
          item.soft_irq         = cur_soft;
          item.num_of_interrupt = $countones({cur_ext, cur_soft});
          `uvm_info({get_type_name(), ".IRQ_CHANGE"}, item.convert2string(),
              UVM_HIGH)
          ap.write(item);
        end
      end
    endtask : run_phase

  endclass : scr1_irq_monitor
