// ============================================================
// File    : scr1_mem_scoreboard.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Memory-agent scoreboard: passive uvm_subscriber on the monitor
// ap (one scr1_mem_txn per completed AHB transfer). Conservative
// PROTOCOL checks (doubtful = WARNING, clear violation = ERROR;
// every ERROR cross-referenced against the model/injection state)
// + traffic counters, SUMMARY in report_phase:
//   1. hresp ERROR legitimacy: iff WIN_UNMAPPED (stage-B
//      deviation) or a recorded injection (plusarg/sequence);
//   2. no transactions during reset (monitor gates; re-checked
//      here as a monitor-regression guard);
//   3. hsize sanity (WARNING; phase ordering is inherent - one
//      item per completed transfer).
// Deeper data-integrity (wdata vs model) is left to the future
// DRVFuzz store-stream comparison.
// ============================================================
  class scr1_mem_scoreboard extends uvm_subscriber #(scr1_mem_txn);
    `uvm_component_utils(scr1_mem_scoreboard)

    // optional handle for the independent reset guard (config_db "mem_vif")
    scr1_mem_vif vif;

    // traffic counters
    int unsigned n_imem;
    int unsigned n_dmem;
    int unsigned n_read;
    int unsigned n_write;
    int unsigned n_okay;
    int unsigned n_error;
    int unsigned n_err_unmapped;   // ERROR on an unmapped window (by design)
    int unsigned n_err_injected;   // ERROR on an injected address (plusarg/seq)
    int unsigned n_violations;     // illegitimate ERROR / reset-window items
    bit          reset_guard_warned;

    function new(string name = "scr1_mem_scoreboard", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      // the reset guard is a bonus - degrade gracefully if the vif is absent
      if (!uvm_config_db#(scr1_mem_vif)::get(this, "", "mem_vif", vif)) begin
        vif = null;
        `uvm_info({get_type_name(), ".NOVIF"},
            "mem_vif not in config_db - the independent reset guard is disabled",
            UVM_MEDIUM)
      end
    endfunction : build_phase

    virtual function void write(scr1_mem_txn t);
      scr1_mem_model::scr1_mem_win_e win;
      ahb_addr_t wkey;

      if (t == null) return;

      // ---- check 2: no transactions during reset (monitor already gates) ----
      if ((vif != null) && (vif.rst_n !== 1'b1)) begin
        n_violations++;
        `uvm_error({get_type_name(), ".RESET_TXN"},
            $sformatf("mem transaction observed while rst_n!=1: %s",
                      t.convert2string()))
      end

      // ---- counters ----
      if (t.is_imem) n_imem++; else n_dmem++;
      if (t.write)   n_write++; else n_read++;

      // ---- check 1: hresp ERROR legitimacy ----
      if (t.resp_err) begin
        n_error++;
        wkey = t.addr & AHB_WORD_MASK;
        win  = (g_mem_model != null) ? g_mem_model.decode(t.addr)
                                     : scr1_mem_model::WIN_UNMAPPED;
        if (win == scr1_mem_model::WIN_UNMAPPED) begin
          n_err_unmapped++;   // stage-B unmapped-window deviation: expected
        end else if ((g_mem_model != null) && g_mem_model.err_was_injected(wkey)) begin
          n_err_injected++;   // plusarg / sequence injection: expected
        end else begin
          n_violations++;
          `uvm_error({get_type_name(), ".BAD_ERROR"},
              $sformatf({"hresp ERROR on a mapped, non-injected address: %s ",
                         "(decode window != UNMAPPED, no injection recorded)"},
                        t.convert2string()))
        end
      end else begin
        n_okay++;
      end

      // ---- check 3: hsize sanity (cheap address->data phase observable) ----
      if (t.size > HSIZE_32B) begin
        `uvm_warning({get_type_name(), ".BAD_SIZE"},
            $sformatf("unexpected hsize=%03b (> word) on %s",
                      t.size, t.convert2string()))
      end
    endfunction : write

    virtual function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info({get_type_name(), ".SUMMARY"},
          $sformatf({"mem transactions: total %0d | imem %0d dmem %0d | ",
                     "read %0d write %0d | resp OKAY %0d ERROR %0d ",
                     "(unmapped %0d injected %0d) | violations %0d"},
              (n_imem + n_dmem), n_imem, n_dmem, n_read, n_write,
              n_okay, n_error, n_err_unmapped, n_err_injected, n_violations),
          UVM_LOW)
    endfunction : report_phase

  endclass : scr1_mem_scoreboard
