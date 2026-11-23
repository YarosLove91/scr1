// ============================================================
// File    : scr1_csr_test.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR RAL test (milestone 3): runs the program vector like the
// smoke test; the CSR checks are performed by scr1_csr_scoreboard
// on every run transaction (RAL mirror predict + shadow +
// hardware constants + counter invariants), the verdict counters
// feed SCR1_RESULT. The explicit test exists as a regression
// entry point and dumps the RAL model at UVM_HIGH.
// ============================================================

  class scr1_csr_test extends scr1_smoke_test;
    `uvm_component_utils(scr1_csr_test)

    function new(string name = "scr1_csr_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      if (env_h.reg_top_model != null) begin
        `uvm_info({get_type_name(), ".RAL"},
            $sformatf("CSR RAL mirror after run(s):\n%s",
                      env_h.reg_top_model.sprint()), UVM_LOW)
      end
    endfunction : report_phase

  endclass : scr1_csr_test
