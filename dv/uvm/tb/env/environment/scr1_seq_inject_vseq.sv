// ============================================================
// File    : scr1_seq_inject_vseq.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Demo vseq for SEQUENCE-driven memory ERROR injection (mem-agent
// side channel): forks the normal program run against a
// scr1_mem_err_seq on p_sequencer.mem_sqr - hresp ERROR is armed
// at runtime by a SEQUENCE, not by +AGENT_DMEM_ERROR_ADDR.
// Default target: the console word address (PRINT_ADDR 0xF0000000,
// normally OKAY); arming ERROR there faults the program's console
// stores (store access fault, mcause=7), and a vector with a trap
// handler (sw_directed/scr1_seq_inject.S) skips them and exits
// a0=0 - the exact effect of AGENT_DMEM_ERROR_ADDR=f0000000,
// produced by a sequence. Requires MEM_AGENT=1; the bus FSM is
// never blocked (the driver pulls items in a separate process).
// ============================================================
  class scr1_seq_inject_vseq extends scr1_base_vseq;
    `uvm_object_utils(scr1_seq_inject_vseq)

    // program vectors to run (passed through to scr1_run_prog_seq)
    string prog_paths[$];

    // injection spec (overridable via +SEQ_INJECT_* plusargs in the test)
    ahb_addr_t   inj_addr;    // word address to arm ERROR on
    int unsigned inj_count;   // number of matching transfers to fault
    bit          inj_imem;    // channel: 0 = dmem (default), 1 = imem

    function new(string name = "scr1_seq_inject_vseq");
      super.new(name);
      inj_addr  = PRINT_ADDR;  // console
      inj_count = 4;
      inj_imem  = 1'b0;
    endfunction : new

    virtual task body();
      scr1_run_prog_seq seq;
      scr1_mem_err_seq  err_seq;

      if (p_sequencer.mem_sqr == null) begin
        `uvm_fatal({get_type_name(), ".NOMEMSQR"},
            {"sequence-driven mem injection needs the reactive memory agent ",
             "(MEM_AGENT=1): v_sqr.mem_sqr is null"})
      end

      `uvm_info({get_type_name(), ".CFG"},
          $sformatf({"seq injection: %s ERROR x%0d on word addr 0x%08h ",
                     "(sequence-driven, not a plusarg)"},
              inj_imem ? "IMEM" : "DMEM", inj_count,
              (inj_addr & AHB_WORD_MASK)),
          UVM_LOW)

      fork
        begin
          seq = scr1_run_prog_seq::type_id::create("seq");
          seq.prog_paths = prog_paths;
          seq.start(p_sequencer.sqr);
        end
        begin
          err_seq = scr1_mem_err_seq::type_id::create("err_seq");
          err_seq.add_err(inj_addr, inj_count, inj_imem);
          err_seq.start(p_sequencer.mem_sqr);
        end
      join
    endtask : body

  endclass : scr1_seq_inject_vseq
