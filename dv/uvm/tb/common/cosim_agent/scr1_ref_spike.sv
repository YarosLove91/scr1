// ============================================================
// File    : scr1_ref_spike.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Pattern 2B: in-process Spike reference model (DPI-C lockstep,
// co-located spike_cosim_dpi.cc - ibex ibex_cosim_agent layout).
// SCR1_SPIKE_COSIM builds only; selected by +SPIKE_HEX (wins over
// +REF_CSV). Trap-entry steps are returned as golden TRAP records
// (pc=mepc, instr=marker) for 1:1 precise-exception comparison;
// after EXIT_PC Spike keeps producing spin commits, lockstep stays
// consistent. Details: dv/uvm/README.md (milestone 2B).
// ============================================================
`ifdef SCR1_SPIKE_COSIM

  // DPI-C imports live at package scope (spike_cosim_dpi.svh, included
  // by scr1_cosim_agent_pkg.sv before this file)

  class scr1_ref_spike extends scr1_ref_model;
    `uvm_component_utils(scr1_ref_spike)

    protected int unsigned steps_done;
    protected string       hex_path;

    function new(string name = "scr1_ref_spike", uvm_component parent = null);
      super.new(name, parent);
      steps_done = 0;
    endfunction : new

    virtual function string model_name();
      return $sformatf("ref_spike_dpi(%s, steps=%0d)", hex_path, steps_done);
    endfunction : model_name

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if ((cfg == null) || (cfg.hex_path == "")) begin
        `uvm_fatal({get_type_name(), ".NOHEX"},
            {"scr1_ref_spike selected but the agent cfg carries no hex_path ",
             "(+SPIKE_HEX=<path> plusarg missing?)"})
      end
      hex_path = cfg.hex_path;
      // cfg-driven Spike init (ibex init_cosim): isa/reset vector + reset calibration
      if (scr1_spike_init(hex_path, cfg.isa, cfg.start_pc,
                          cfg.mtvec_reset, cfg.mstatus_reset) != 0) begin
        `uvm_fatal({get_type_name(), ".INIT"},
            $sformatf("spike init failed for %s", hex_path))
      end
      `uvm_info({get_type_name(), ".INIT"},
          $sformatf({"in-process Spike ready: %s isa=%s pc=0x%0h mtvec=0x%0h ",
                     "mstatus=0x%0h (SCR1-calibrated reset state)"},
                    hex_path, cfg.isa, cfg.start_pc, cfg.mtvec_reset,
                    cfg.mstatus_reset), UVM_LOW)
    endfunction : build_phase

    virtual function bit supports_traps();
      return 1'b1;
    endfunction : supports_traps

    virtual function bit supports_csr_read();
      return 1'b1;
    endfunction : supports_csr_read

    // live Spike CSR peek via DPI; 0 = not readable in the model (e.g. the
    // SCR1-custom mcounten 0x7E0 makes processor_t::get_csr throw)
    virtual function bit get_csr_value(csr_addr_t a, output csr_data_t v);
      int val;
      if (scr1_spike_get_csr(int'(a), val) != 0) return 1'b0;
      v = csr_data_t'(val);
      return 1'b1;
    endfunction : get_csr_value

    virtual function bit get_next(output scr1_commit_s c);
      int pc, instr, wr, rd, val, trap, mcause, mepc;
      int csr_wv, csr_wa, csr_wd;
      if (scr1_spike_step(pc, instr, wr, rd, val, trap, mcause, mepc,
                          csr_wv, csr_wa, csr_wd) != 0)
        return 1'b0;
      c       = '0;
      c.valid = 1'b1;
      if (trap) begin
        // golden trap record: pc = mepc (faulting instruction), instr = marker
        c.trap   = 1'b1;
        c.mcause = csr_data_t'(mcause);
        c.pc     = xlen_word_t'(mepc);
        c.instr  = TRAP_INSTR_MARKER;
      end else begin
        c.pc      = xlen_word_t'(pc);
        c.instr   = raw_opcode_t'(instr);
        c.rd_wr   = (wr != 0);
        c.rd_addr = reg_idx_t'(rd);
        c.rd_data = xlen_word_t'(val);
        // golden CSR-write event of the step (Spike log_reg_write; NOT emitted
        // for trap/mret steps - DPI wrapper). NB: csr_w_data here is the write
        // RESULT while the DUT bus carries the OPERAND (pipe_csr applies
        // WRITE/SET/CLEAR) - the scoreboard compares presence+address only;
        // values: M7 live mirror (vs DUT) + run-exit check (vs Spike).
        c.csr_w_req  = (csr_wv != 0);
        c.csr_addr   = csr_addr_t'(csr_wa);
        c.csr_w_data = csr_data_t'(csr_wd);
      end
      steps_done++;
      return 1'b1;
    endfunction : get_next

    virtual function int unsigned remaining();
      return 0;  // live model: the stream ends with the simulation
    endfunction : remaining

    virtual function void final_phase(uvm_phase phase);
      scr1_spike_fini();
      super.final_phase(phase);
    endfunction : final_phase

  endclass : scr1_ref_spike

`endif // SCR1_SPIKE_COSIM
