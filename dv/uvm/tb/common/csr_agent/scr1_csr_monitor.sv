// ============================================================
// File    : scr1_csr_monitor.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR agent monitor (donor: ibex rvfi_monitor). Samples the bound
// commit interface (scr1_commit_if mon_cb, race-free #1step) and
// publishes only the CSR-relevant retires (trap / MRET /
// csr_r|w_req) - exactly the scr1_csr_scoreboard.on_commit
// predicate, so the filtered stream is semantically identical to
// the full one (irq_stress: ~139 of ~300k retires). Read-only.
// ============================================================
  class scr1_csr_monitor extends uvm_monitor;
    `uvm_component_utils(scr1_csr_monitor)

    scr1_commit_vif commit_vif;
    uvm_analysis_port #(scr1_commit_tr) ap;

    function new(string name = "scr1_csr_monitor", uvm_component parent = null);
      super.new(name, parent);
      ap = new("ap", this);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_commit_vif)::get(this, "", "commit_vif", commit_vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "commit virtual interface not found in uvm_config_db")
      end
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      scr1_commit_tr ctr;
      super.run_phase(phase);
      forever begin
        @(commit_vif.mon_cb);
        if (commit_vif.mon_cb.commit_valid !== 1'b1) continue;
        // CSR-relevant retire filter - the exact set the scoreboard's
        // on_commit consumes before its early returns
        if ((commit_vif.mon_cb.commit_trap      !== 1'b1) &&
            (commit_vif.mon_cb.commit_csr_r_req !== 1'b1) &&
            (commit_vif.mon_cb.commit_csr_w_req !== 1'b1) &&
            (commit_vif.mon_cb.commit_instr     !=  OPCODE_MRET)) begin
          continue;
        end
        ctr = scr1_commit_tr::type_id::create("ctr");
        ctr.c.valid      = 1'b1;
        ctr.c.trap       = commit_vif.mon_cb.commit_trap;
        ctr.c.mcause     = commit_vif.mon_cb.commit_mcause;
        ctr.c.trap_val   = commit_vif.mon_cb.commit_trap_val;
        ctr.c.pc         = commit_vif.mon_cb.commit_pc;
        ctr.c.instr      = commit_vif.mon_cb.commit_instr;
        ctr.c.rd_wr      = commit_vif.mon_cb.commit_rd_wr;
        ctr.c.rd_addr    = commit_vif.mon_cb.commit_rd_addr;
        ctr.c.rd_data    = commit_vif.mon_cb.commit_rd_data;
        ctr.c.mem_we     = commit_vif.mon_cb.commit_mem_we;
        ctr.c.mem_valid  = commit_vif.mon_cb.commit_mem_addr_valid;
        ctr.c.mem_addr   = commit_vif.mon_cb.commit_mem_addr;
        ctr.c.mem_wdata  = commit_vif.mon_cb.commit_mem_wdata;
        ctr.c.csr_r_req  = commit_vif.mon_cb.commit_csr_r_req;
        ctr.c.csr_w_req  = commit_vif.mon_cb.commit_csr_w_req;
        ctr.c.csr_addr   = commit_vif.mon_cb.commit_csr_addr;
        ctr.c.csr_r_data = commit_vif.mon_cb.commit_csr_r_data;
        ctr.c.csr_w_data = commit_vif.mon_cb.commit_csr_w_data;
        ctr.c.csr_rs1    = commit_vif.mon_cb.commit_csr_rs1;
        `uvm_info({get_type_name(), ".CSR_EVENT"},
                  ctr.convert2string(), UVM_HIGH)
        ap.write(ctr);
      end
    endtask : run_phase

  endclass : scr1_csr_monitor
