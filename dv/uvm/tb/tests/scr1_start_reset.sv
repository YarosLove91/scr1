// ============================================================
// File    : scr1_start_reset.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Abstract test with an initial reset stage (SCR1 analog of the
// lab pattern alu_start_reset). Concrete tests extend this when
// they need a known starting state: do_reset() keeps a full reset
// window (rst_n_req asserted from time 0 by the scr1_if initial;
// per-run release stays with the driver), clears the memory-model
// devices and settles the bus before body_seq(). The test NEVER
// drives rst_n_req itself - the driver stays the single source of
// the interface signals (single-driver rule). Objection/drain/
// verdict flow matches scr1_base_test.
// ============================================================

  virtual class scr1_start_reset extends scr1_base_test;
    `uvm_component_utils(scr1_start_reset)

    scr1_vif vif;

    function new(string name = "scr1_start_reset", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_vif)::get(this, "", "vif", vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "virtual interface not found in uvm_config_db")
      end
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      `uvm_info({get_type_name(), ".START"},
          $sformatf("starting test: DUT=scr1_top_ahb cfg: RST_CYCLES=%0d TIMEOUT_CYCLES=%0d NUM_RUNS=%0d",
              RST_CYCLES, TIMEOUT_CYCLES, NUM_RUNS),
          UVM_HIGH)
      phase.raise_objection(this);
      do_reset();
      body_seq();
      #(DRAIN_TIME_NS);  // pipeline drain: monitor -> scb
      phase.drop_objection(this);
    endtask : run_phase

    // initial stage: hold a full RST_CYCLES window with reset asserted
    // (race-free mon_cb sampling), verify the assertion, clear the memory
    // agent's device state (no-op on MEM_AGENT=0) and settle the bus - the
    // test starts from a known clean state before loading the vector
    virtual task do_reset();
      `uvm_info({get_type_name(), ".RESET"},
          "initialization stage: reset asserted (active LOW), clearing the memory-model devices, settling the bus",
          UVM_HIGH)
      repeat (RST_CYCLES) @(vif.mon_cb);
      if (vif.mon_cb.rst_n_req !== 1'b0) begin
        `uvm_warning({get_type_name(), ".RESET"},
            {"rst_n_req is not asserted at the initialization stage - ",
             "the per-run driver reset will re-establish the known state"})
      end
      if (g_mem_model != null) g_mem_model.reset_devices();
      repeat (RST_CYCLES) @(vif.mon_cb);
      `uvm_info({get_type_name(), ".RESET"},
          $sformatf({"initialization done: %0d reset clocks held, ",
                     "devices cleared, bus idle"}, 2 * RST_CYCLES),
          UVM_HIGH)
    endtask : do_reset

  endclass : scr1_start_reset
