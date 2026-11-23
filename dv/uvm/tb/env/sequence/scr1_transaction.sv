// ============================================================
// File    : scr1_transaction.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Program-run transaction: one item = one "load vector, reset,
// run to completion" cycle. prog_path = test vector (.hex,
// objcopy -O verilog, $readmemh'd while reset is LOW);
// timeout_cycles = per-run watchdog. Observed results (monitor,
// exit event): run_done/exit_a0 (EXIT_PC reached; a0==0 -> PASS
// convention), console (SCR1_SIM_PRINT_ADDR chars), csr snapshot.
// ============================================================
  class scr1_transaction extends uvm_sequence_item;

    // ---- stimulus ----
    // NB: not rand - Verilator 5.053 cannot randomize string fields
    string            prog_path;       // test vector (.hex) to load
    rand int unsigned timeout_cycles;  // per-run watchdog, clocks

    // ---- observed results (monitor) ----
    bit               run_done;        // exit PC reached
    bit               timed_out;       // watchdog expired (driver)
    xlen_word_t       exit_a0;         // a0 (x10) at the exit PC
    string            console;         // captured console output
    scr1_csr_snap_s   csr;             // CSR snapshot at the run exit (RAL)

    // ---- housekeeping ----
    int unsigned      id;

    `uvm_object_utils_begin(scr1_transaction)
      `uvm_field_int (id,             UVM_ALL_ON | UVM_DEC)
      `uvm_field_int (timeout_cycles, UVM_ALL_ON | UVM_DEC)
      `uvm_field_int (run_done,       UVM_ALL_ON)
      `uvm_field_int (timed_out,      UVM_ALL_ON)
      `uvm_field_int (exit_a0,        UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "scr1_transaction");
      super.new(name);
      prog_path      = DEFAULT_TEST_HEX;
      timeout_cycles = TIMEOUT_CYCLES;
      run_done       = 1'b0;
      timed_out      = 1'b0;
      exit_a0        = '0;
      console        = "";
    endfunction : new

    function string inputs2str();
      return $sformatf("prog=%s timeout=%0d", prog_path, timeout_cycles);
    endfunction : inputs2str

    function string outputs2str();
      return $sformatf("done=%0b timed_out=%0b a0=0x%08h console=\"%s\"",
          run_done, timed_out, exit_a0, console);
    endfunction : outputs2str

    virtual function string convert2string();
      return $sformatf("[%0d] %s | %s", id, inputs2str(), outputs2str());
    endfunction : convert2string

  endclass : scr1_transaction
