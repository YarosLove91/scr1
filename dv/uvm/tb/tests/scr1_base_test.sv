// ============================================================
// File    : scr1_base_test.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Abstract base test: builds the environment, runs the
// test-specific sequence (body_seq), drains the pipeline and
// emits the final SCR1_RESULT verdict through the UVM report
// macros only (uvm_info on PASS / uvm_error on FAIL, UVM_NONE so
// the Makefile grep always sees it); on failure the report
// summary is forced in final_phase so the triage table is kept.
// ============================================================

  virtual class scr1_base_test extends uvm_test;
    `uvm_component_utils(scr1_base_test)

    scr1_env env_h;
    // require the scoreboard to have checked at least one run
    bit require_run_checks = 1'b1;

    function new(string name = "scr1_base_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      scr1_report_server scr1_srv;
      super.build_phase(phase);
      // install the custom report server: per-ID error triage, verbosity
      // histogram, verdict counters, optional XML log (+SCR1_XML_LOG);
      // earlier messages stay accounted by the default server
      scr1_srv = new("scr1_report_server");
      uvm_report_server::set_server(scr1_srv);
      `uvm_info({get_type_name(), ".REPORT_SERVER"},
          "custom scr1_report_server installed via uvm_report_server::set_server()",
          UVM_HIGH)
      env_h = scr1_env::type_id::create("env_h", this);
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      `uvm_info({get_type_name(), ".START"},
          $sformatf("starting test: DUT=scr1_top_ahb cfg: RST_CYCLES=%0d TIMEOUT_CYCLES=%0d NUM_RUNS=%0d",
              RST_CYCLES, TIMEOUT_CYCLES, NUM_RUNS),
          UVM_HIGH)
      phase.raise_objection(this);
      body_seq();
      #(DRAIN_TIME_NS);  // pipeline drain: monitor -> scb
      phase.drop_objection(this);
    endtask : run_phase

    // extension point: the concrete sequence of the test
    pure virtual task body_seq();

    // Final verdict (the SCR1_RESULT line is parsed by the Makefile)
    virtual function void final_phase(uvm_phase phase);
      uvm_report_server srv;
      bit ok;
      super.final_phase(phase);
      srv = uvm_report_server::get_server();
      ok = (g_runs_failed == 0) &&
        (g_diff_mismatches == 0) &&
        (g_csr_mismatches == 0) &&
        (srv.get_severity_count(UVM_ERROR) == 0) &&
        (srv.get_severity_count(UVM_FATAL) == 0) &&
        (!require_run_checks || g_runs_checked > 0);

      if (ok) begin
        `uvm_info({get_type_name(), ".RESULT"},
            $sformatf({"SCR1_RESULT: PASS  (DUT=scr1_top_ahb TEST=%s ",
                       "runs_checked=%0d diff_checked=%0d ",
                       "diff_mismatches=%0d trap_checked=%0d ",
                       "csr_checked=%0d csr_live=%0d csr_diff=%0d)"},
                get_type_name(), g_runs_checked, g_diff_checked,
                g_diff_mismatches, g_diff_traps, g_csr_checked, g_csr_live,
                g_csr_diff_checked),
            UVM_NONE)
      end else begin
        `uvm_error({get_type_name(), ".RESULT"},
            $sformatf({"SCR1_RESULT: FAIL  (DUT=scr1_top_ahb TEST=%s ",
                       "runs_checked=%0d failed=%0d diff_checked=%0d ",
                       "diff_mismatches=%0d trap_checked=%0d ",
                       "csr_checked=%0d csr_live=%0d csr_mismatches=%0d ",
                       "csr_diff=%0d csr_diff_mm=%0d errors=%0d)"},
                get_type_name(), g_runs_checked, g_runs_failed,
                g_diff_checked, g_diff_mismatches, g_diff_traps,
                g_csr_checked, g_csr_live, g_csr_mismatches,
                g_csr_diff_checked, g_csr_diff_mismatches,
                srv.get_severity_count(UVM_ERROR)))
        // final_phase runs after report_phase, so the runner's automatic
        // summary would not include this verdict - force the triage table
        srv.report_summarize();
      end
    endfunction : final_phase
  endclass : scr1_base_test
