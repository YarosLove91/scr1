// ============================================================
// File    : scr1_mem_monitor.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Memory agent monitor: watches both AHB channels through mon_cb,
// one scr1_mem_txn per COMPLETED transfer (address accept +
// data-phase response, both at hready=1); same-clock pipelined
// completion + next accept supported (completion published first).
// The ap is the DRVFuzz store-stream hook; console/exit checking
// stays with the core agent's monitor (scr1_if dmem taps).
// ============================================================
  class scr1_mem_monitor extends uvm_monitor;
    `uvm_component_utils(scr1_mem_monitor)

    scr1_mem_vif vif;
    uvm_analysis_port #(scr1_mem_txn) ap;

    // per-channel address->data pipeline (0 = imem, 1 = dmem)
    protected bit          pend      [AHB_CH_NUM];
    protected ahb_addr_t   pend_addr [AHB_CH_NUM];
    protected bit          pend_wr   [AHB_CH_NUM];
    protected ahb_hsize_t  pend_size [AHB_CH_NUM];

    function new(string name = "scr1_mem_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_mem_vif)::get(this, "", "mem_vif", vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "mem_vif not found in uvm_config_db (MEM_AGENT build?)")
      end
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      super.run_phase(phase);
      pend[0] = 1'b0;
      pend[1] = 1'b0;
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.rst_n !== 1'b1) begin
          pend[0] = 1'b0;
          pend[1] = 1'b0;
          continue;
        end
        mon_imem();
        mon_dmem();
      end
    endtask : run_phase

    protected task mon_imem();
      scr1_mem_txn tr;
      // data phase completion of a pending fetch
      if (pend[0] && (vif.mon_cb.imem_hready === 1'b1)) begin
        tr         = scr1_mem_txn::type_id::create("tr");
        tr.is_imem = 1'b1;
        tr.addr    = pend_addr[0];
        tr.write   = 1'b0;
        tr.size    = pend_size[0];
        tr.wdata   = '0;
        tr.rdata   = vif.mon_cb.imem_hrdata;
        tr.resp_err = vif.mon_cb.imem_hresp;
        `uvm_info({get_type_name(), ".IMEM"}, tr.convert2string(), UVM_DEBUG)
        ap.write(tr);
        pend[0] = 1'b0;
      end
      // address phase accept (possibly the next pipelined fetch)
      if ((vif.mon_cb.imem_htrans == HTRANS_NONSEQ) &&
          (vif.mon_cb.imem_hready === 1'b1)) begin
        pend[0]      = 1'b1;
        pend_addr[0] = vif.mon_cb.imem_haddr;
        pend_size[0] = vif.mon_cb.imem_hsize;
      end
    endtask : mon_imem

    protected task mon_dmem();
      scr1_mem_txn tr;
      // data phase completion of a pending access
      if (pend[1] && (vif.mon_cb.dmem_hready === 1'b1)) begin
        tr         = scr1_mem_txn::type_id::create("tr");
        tr.is_imem = 1'b0;
        tr.addr    = pend_addr[1];
        tr.write   = pend_wr[1];
        tr.size    = pend_size[1];
        tr.wdata   = vif.mon_cb.dmem_hwdata;
        tr.rdata   = vif.mon_cb.dmem_hrdata;
        tr.resp_err = vif.mon_cb.dmem_hresp;
        `uvm_info({get_type_name(), ".DMEM"}, tr.convert2string(), UVM_DEBUG)
        ap.write(tr);
        pend[1] = 1'b0;
      end
      // address phase accept
      if ((vif.mon_cb.dmem_htrans == HTRANS_NONSEQ) &&
          (vif.mon_cb.dmem_hready === 1'b1)) begin
        pend[1]      = 1'b1;
        pend_addr[1] = vif.mon_cb.dmem_haddr;
        pend_wr[1]   = vif.mon_cb.dmem_hwrite;
        pend_size[1] = vif.mon_cb.dmem_hsize;
      end
    endtask : mon_dmem

  endclass : scr1_mem_monitor
