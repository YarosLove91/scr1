// ============================================================
// File    : scr1_run_prog_seq.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Run-program sequence: passes the test vectors (.hex paths) to
// the driver through the sequencer, one scr1_transaction per
// program, in queue order. The test fills prog_paths (e.g. from
// +SCR1_TEST_HEX); the driver does the rest (load, reset, run,
// completion wait).
// ============================================================
  class scr1_run_prog_seq extends scr1_base_seq;
    `uvm_object_utils(scr1_run_prog_seq)

    // test vectors to run, in order
    string prog_paths[$];

    function new(string name = "scr1_run_prog_seq");
      super.new(name);
    endfunction : new

    virtual task body();
      if (prog_paths.size() == 0) begin
        `uvm_warning({get_type_name(), ".EMPTY"},
                     "prog_paths is empty, nothing to run")
        return;
      end
      foreach (prog_paths[i]) begin
        req = scr1_transaction::type_id::create($sformatf("req%0d", i));
        start_item(req);
        req.id        = g_item_id++;
        req.prog_path = prog_paths[i];
        finish_item(req);
        `uvm_info({get_type_name(), ".DONE"},
                  $sformatf("[%0d] finished: %s", req.id, req.outputs2str()),
                  UVM_MEDIUM)
      end
    endtask : body

  endclass : scr1_run_prog_seq
