// ============================================================
// File    : scr1_scoreboard.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Scoreboard (milestone 1): checks the observed program runs -
// exit_a0 vs the SCR1 pass/fail convention (a0 == 0), logs the
// console of every run and keeps the verdict counters consumed by
// scr1_base_test (SCR1_RESULT line); the detailed log is capped at
// SCB_MAX_LOG messages.
// ============================================================
  class scr1_scoreboard extends uvm_subscriber #(scr1_transaction);
    `uvm_component_utils(scr1_scoreboard)

    function new(string name = "scr1_scoreboard", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void write(scr1_transaction tr);
      g_runs_checked++;

      `uvm_info({get_type_name(), ".CONSOLE"},
                $sformatf("console of run %0d: \"%s\"", tr.id, tr.console),
                UVM_MEDIUM)

      if (tr.exit_a0 == '0) begin
        g_runs_passed++;
        `uvm_info({get_type_name(), ".MATCHED"},
            $sformatf("run %0d PASS (a0=0x%08h at exit PC)", tr.id, tr.exit_a0),
            UVM_MEDIUM)
      end else begin
        g_runs_failed++;
        if (g_runs_failed <= SCB_MAX_LOG) begin
          `uvm_error({get_type_name(), ".MISMATCH"},
              $sformatf("run %0d FAIL: a0=0x%08h (expected 0x00000000)",
                        tr.id, tr.exit_a0))
        end
        else if (g_runs_failed == SCB_MAX_LOG + 1) begin
          `uvm_error({get_type_name(), ".LOG_LIMIT"},
              $sformatf("detailed mismatch log capped at %0d messages, further mismatches counted only",
                        SCB_MAX_LOG))
        end
      end
    endfunction : write

    virtual function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info({get_type_name(), ".SUMMARY"},
                $sformatf("runs checked: %0d | passed: %0d | failed: %0d | console chars: %0d",
                          g_runs_checked, g_runs_passed, g_runs_failed,
                          g_console_chars),
                UVM_LOW)
    endfunction : report_phase

  endclass : scr1_scoreboard
