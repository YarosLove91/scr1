// ============================================================
// File    : scr1_irq_driver.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ agent driver - the ONLY driver of the TB stimulus lines
// (scr1_irq_if ext_lines/soft_irq via driver_cb); the core pins
// are the OR with the mem-agent device mirror (continuous assign
// in scr1_irq_if) - one procedural driver per signal. TWO
// independent processes: (a) per-clock pin re-drive
// (registered-output semantics; reset CLEARS the state so no
// stimulus leaks across the NUM_RUNS per-run resets); (b)
// sequencer side-channel applying items with ZERO sim time
// (level semantics: an item is the new joint state, held until
// the next item) - get_next_item never blocks the pin driver.
// ============================================================
  class scr1_irq_driver extends uvm_driver #(scr1_irq_seq_item);
    `uvm_component_utils(scr1_irq_driver)

    scr1_irq_vif vif;

    // current stimulus state (written by the side-channel only)
    protected irq_lines_t stim_ext;
    protected bit                     stim_soft;

    function new(string name = "scr1_irq_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_irq_vif)::get(this, "", "irq_vif", vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "irq_vif not found in uvm_config_db (IRQ agent build?)")
      end
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      super.run_phase(phase);
      stim_ext  = '0;
      stim_soft = 1'b0;
      fork
        // (a) per-clock pin driver (never blocked by anything)
        forever begin
          @(vif.driver_cb);
          step();
        end
        // (b) sequencer side-channel: apply items to the state
        forever begin
          seq_item_port.get_next_item(req);
          apply_item(req);
          seq_item_port.item_done();
        end
      join
    endtask : run_phase

    // one pin-driver clock: reset drives lines low and drops pending
    // stimulus (per-run isolation); otherwise re-drive the state
    protected task step();
      if (vif.driver_cb.rst_n !== 1'b1) begin
        stim_ext  = '0;
        stim_soft = 1'b0;
        vif.driver_cb.ext_lines <= '0;
        vif.driver_cb.soft_irq  <= 1'b0;
        return;
      end
      vif.driver_cb.ext_lines <= stim_ext;
      vif.driver_cb.soft_irq  <= stim_soft;
    endtask : step

    // apply one item: full joint state of both channels (level
    // semantics), zero simulation time
    protected function void apply_item(scr1_irq_seq_item item);
      if (item == null) return;
      stim_ext  = item.ext_mask;
      stim_soft = item.soft_irq;
      `uvm_info({get_type_name(), ".IRQ_DRIVE"}, item.convert2string(),
          UVM_LOW)
    endfunction : apply_item

  endclass : scr1_irq_driver
