// ============================================================
// File    : scr1_driver.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Core agent driver: applies program-run transactions through
// drv_cb. One transaction = one core run: $fopen pre-check of the
// vector (fail fast); hold rst_n LOW, pass the path via
// scr1_cfg_pkg::g_load_path (a string cannot cross the vif
// boundary) and pulse load_req - the harness zeroes the array and
// $readmemh's the file, answering load_done; backdoor-verify the
// reset-vector word is non-zero (catches the silent-zero
// $readmemh failure mode); hold reset RST_CYCLES, release (boot
// from 0x200); wait for EXIT_PC or the per-run timeout.
// peek32/poke32 backdoor: 32-bit LE words via the harness
// handshake. Details: dv/uvm/README.md (stage A loader).
// ============================================================
  class scr1_driver extends uvm_driver #(scr1_transaction);
    `uvm_component_utils(scr1_driver)

    scr1_vif vif;

    function new(string name = "scr1_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_vif)::get(this, "", "vif", vif)) begin
          `uvm_fatal({get_type_name(), ".NOVIF"},
              "virtual interface not found in uvm_config_db")
      end
    endfunction : build_phase

    // backdoor read of one 32-bit LE word: req up, wait done, sample
    virtual task peek32(xlen_word_t addr, output xlen_word_t data);
      vif.drv_cb.peek_addr <= addr;
      vif.drv_cb.peek_req  <= 1'b1;
      @(vif.drv_cb);
      while (vif.drv_cb.peek_done !== 1'b1) @(vif.drv_cb);
      data = vif.drv_cb.peek_data;
      vif.drv_cb.peek_req  <= 1'b0;
      @(vif.drv_cb);
    endtask : peek32

    // backdoor write of one 32-bit LE word: one-clock req, no done line
    virtual task poke32(xlen_word_t addr, xlen_word_t data);
      vif.drv_cb.poke_addr <= addr;
      vif.drv_cb.poke_data <= data;
      vif.drv_cb.poke_req  <= 1'b1;
      @(vif.drv_cb);
      vif.drv_cb.poke_req  <= 1'b0;
      @(vif.drv_cb);
    endtask : poke32

    virtual task run_phase(uvm_phase phase);
      super.run_phase(phase);
      // idle level: reset asserted (req lines init by the interface initial)
      @(vif.drv_cb);
      vif.drv_cb.rst_n_req <= 1'b0;

      forever begin
        seq_item_port.get_next_item(req);
        drive_run(req);
        seq_item_port.item_done();
      end
    endtask : run_phase

    virtual task drive_run(scr1_transaction req);
      int unsigned   cnt;
      int            fd;
      xlen_word_t    reset_word;

      // ---- phase 0: fail fast on an unreadable vector path ----
      fd = $fopen(req.prog_path, "r");
      if (fd == 0) begin
        `uvm_fatal({get_type_name(), ".VECOPEN"},
            $sformatf("[%0d] cannot open vector file '%s' for reading",
                      req.id, req.prog_path))
      end
      $fclose(fd);

      // ---- phase 1: hold reset, hand the string path to the harness ----
      vif.drv_cb.rst_n_req <= 1'b0;
      // a string cannot cross the vif boundary - pass it via the cfg global
      scr1_cfg_pkg::g_load_path = req.prog_path;
      @(vif.drv_cb);
      vif.drv_cb.load_req <= 1'b1;
      @(vif.drv_cb);
      while (vif.drv_cb.load_done !== 1'b1) @(vif.drv_cb);
      vif.drv_cb.load_req <= 1'b0;
      `uvm_info({get_type_name(), ".LOAD"},
                $sformatf("[%0d] vector %s loaded (zeroed + $readmemh, string path)",
                          req.id, req.prog_path),
                UVM_MEDIUM)

      // ---- phase 2: readback verification of the reset vector word; a zero
      // means $readmemh silently failed (trap loop) - stop before a timeout ----
      peek32(RST_VECTOR, reset_word);
      if (reset_word === '0) begin
        `uvm_fatal({get_type_name(), ".VECEMPTY"},
            $sformatf("[%0d] word at 0x200 reads 0 after loading '%s' - the vector did not reach the memory",
                      req.id, req.prog_path))
      end

      // ---- phase 3: hold the reset, then release - the core boots from 0x200 ----
      repeat (RST_CYCLES) @(vif.drv_cb);
      vif.drv_cb.rst_n_req <= 1'b1;
      `uvm_info({get_type_name(), ".RUN"},
                $sformatf("[%0d] reset released, running %s",
                          req.id, req.prog_path),
                UVM_HIGH)

      // ---- phase 4: wait for the exit PC or the watchdog ----
      cnt = 0;
      req.run_done  = 1'b0;
      req.timed_out = 1'b0;
      forever begin
        @(vif.drv_cb);
        cnt++;
        if ((vif.rst_n_req === 1'b1) && (vif.drv_cb.curr_pc == EXIT_PC)) begin
          req.run_done = 1'b1;
          break;
        end
        if (cnt >= req.timeout_cycles) begin
          req.timed_out = 1'b1;
          `uvm_error({get_type_name(), ".TIMEOUT"},
              $sformatf("[%0d] run of %s timed out after %0d cycles (pc=0x%08h)",
                        req.id, req.prog_path, cnt, vif.drv_cb.curr_pc))
          break;
        end
      end

      `uvm_info({get_type_name(), ".DRIVE"},
                $sformatf("[%0d] %s completed in %0d cycles (done=%0b)",
                          req.id, req.prog_path, cnt, req.run_done),
                UVM_MEDIUM)
    endtask : drive_run

  endclass : scr1_driver
