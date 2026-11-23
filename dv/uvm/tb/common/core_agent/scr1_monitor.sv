// ============================================================
// File    : scr1_monitor.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Core agent monitor: samples every signal through mon_cb
// (#1step, race-free). One observed run = one transaction,
// published on the exit event (curr_pc == EXIT_PC): console
// capture (one char per store to SCR1_SIM_PRINT_ADDR, rebuilt
// from the AHB address->data pipeline; INTENTIONALLY redundant
// with the MEM_AGENT=1 model - this path feeds tr.console and is
// the only one in the legacy MEM_AGENT=0 mode), exit_a0 (the
// SCR1 pass/fail convention: a0==0 -> PASS) and the run-end CSR
// snapshot. The run re-arms when rst_n goes LOW.
// ============================================================
  class scr1_monitor extends uvm_monitor;
    `uvm_component_utils(scr1_monitor)

    scr1_vif vif;
    uvm_analysis_port #(scr1_transaction) ap;

    // state of the observed run
    protected bit          armed;       // reset seen, waiting for exit
    protected bit          rst_n_prev;
    protected string       console;     // characters of the current run
    // AHB write pipeline: address phase -> data phase
    protected bit          pend_wr;
    protected ahb_addr_t   pend_addr;

    function new(string name = "scr1_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_vif)::get(this, "", "vif", vif)) begin
          `uvm_fatal({get_type_name(), ".NOVIF"},
                      "virtual interface not found in uvm_config_db")
      end
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      scr1_transaction tr;
      mem_byte_t       cbyte;   // console character (low byte of hwdata)
      super.run_phase(phase);
      armed      = 1'b0;
      rst_n_prev = 1'b0;
      console    = "";
      pend_wr    = 1'b0;
      pend_addr  = '0;

      forever begin
        @(vif.mon_cb);

        // ---- run (re)arm: reset asserted = new vector load ----
        if (vif.mon_cb.rst_n_req !== 1'b1) begin
          if (rst_n_prev) begin
            console   = "";
            pend_wr   = 1'b0;
            pend_addr = '0;
          end
          armed      = 1'b1;
          rst_n_prev = 1'b0;
          continue;
        end
        rst_n_prev = 1'b1;

        // ---- console MMIO: data phase of the previous address phase ----
        if (vif.mon_cb.dmem_hready === 1'b1) begin
          if (pend_wr && (pend_addr == PRINT_ADDR)) begin
            cbyte = mem_byte_t'(vif.mon_cb.dmem_hwdata);
            console = {console, string'(cbyte)};
            g_console_chars++;
            `uvm_info({get_type_name(), ".CONSOLE"},
                $sformatf("char '%s' (0x%02h)", string'(cbyte), cbyte),
                UVM_HIGH)
          end
          // ---- latch the current address phase ----
          pend_wr   = (vif.mon_cb.dmem_hwrite === 1'b1) &&
                      (vif.mon_cb.dmem_htrans != HTRANS_IDLE) &&
                      (vif.mon_cb.dmem_htrans != HTRANS_BUSY);
          pend_addr = vif.mon_cb.dmem_haddr;
        end

        // ---- exit event: publish the run transaction ----
        if (armed && (vif.mon_cb.curr_pc == EXIT_PC)) begin
          armed = 1'b0;
          tr = scr1_transaction::type_id::create("tr");
          tr.id       = g_item_id;
          tr.run_done = 1'b1;
          tr.exit_a0  = vif.mon_cb.a0;
          tr.console  = console;
          tr.csr      = vif.mon_cb.csr_snap;
          `uvm_info({get_type_name(), ".SAMPLED"},
                    $sformatf("run finished: %s", tr.outputs2str()),
                    UVM_MEDIUM)
          ap.write(tr);
        end
      end
    endtask : run_phase

  endclass : scr1_monitor
