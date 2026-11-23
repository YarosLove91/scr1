// ============================================================
// File    : scr1_cosim_scoreboard.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Cosim scoreboard inside the cosim agent (ibex
// ibex_cosim_scoreboard pattern). Phase A: pull-lockstep of the
// DUT commit stream vs the reference backend (2B Spike DPI / 2A
// CSV / none = inert), comparing pc/instr/GPR writeback (+mepc/
// mcause on traps); phase B: run-exit CSR cross-check vs the live
// golden state. Skip filters and the CSR-diff value semantics are
// documented at the code; exit-mask legal divergences at the
// on_run_end call site. Verdict counters g_diff_*/g_csr_diff_*
// live in scr1_tb_pkg. Details: dv/uvm/README.md (milestones
// 2A/2B, 7).
// ============================================================
  class scr1_cosim_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(scr1_cosim_scoreboard)

    // agent configuration (published by scr1_env via uvm_config_db)
    scr1_cosim_cfg cfg;

    // reference backend, built in build_phase (null = COSIM_NONE: inert)
    scr1_ref_model ref_m;

    // TLM entries (`uvm_analysis_imp_decl in scr1_cosim_agent_pkg):
    // commit_imp - phase A (own monitor); run_imp - phase B (env run_export)
    uvm_analysis_imp_commit #(scr1_commit_tr, scr1_cosim_scoreboard)   commit_imp;
    uvm_analysis_imp_run    #(scr1_transaction, scr1_cosim_scoreboard) run_imp;

    function new(string name = "scr1_cosim_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      commit_imp = new("commit_imp", this);
      run_imp    = new("run_imp", this);
    endfunction : new

    virtual function void write_run(scr1_transaction tr);
      on_run_end(tr);
    endfunction : write_run

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_cosim_cfg)::get(this, "", "cosim_cfg", cfg)) begin
        `uvm_fatal({get_type_name(), ".NOCFG"},
            {"cosim configuration not found in uvm_config_db - ",
             "scr1_env must publish it before building the agent"})
      end
      `uvm_info({get_type_name(), ".CFG"},
          $sformatf({"cosim cfg: mode=%s hex=%s csv=%s isa=%s ",
                     "start_pc=0x%0h mtvec_reset=0x%0h mstatus_reset=0x%0h"},
                    cfg.mode_name(), cfg.hex_path, cfg.csv_path, cfg.isa,
                    cfg.start_pc, cfg.mtvec_reset, cfg.mstatus_reset), UVM_LOW)
      // backend selection: the agent owns its golden model (ibex pattern)
      case (cfg.mode)
`ifdef SCR1_SPIKE_COSIM
        COSIM_SPIKE: begin
          ref_m = scr1_ref_spike::type_id::create("ref_m", this);
          `uvm_info({get_type_name(), ".REF"},
              $sformatf("reference model: in-process Spike DPI, vector %s",
                        cfg.hex_path), UVM_LOW)
        end
`endif
        COSIM_CSV: begin
          ref_m = scr1_ref_csv::type_id::create("ref_m", this);
          `uvm_info({get_type_name(), ".REF"},
              $sformatf("reference model: CSV replay %s", cfg.csv_path), UVM_LOW)
        end
        default: begin
          // COSIM_NONE: inert, differential checks disabled
          ref_m = null;
        end
      endcase
      // the child ref model builds AFTER this function: it consumes cfg
      if (ref_m != null) ref_m.cfg = cfg;
    endfunction : build_phase

    // ---- filter helpers -------------------------------------------------
    protected function bit is_counter_csr_read(raw_opcode_t instr);
      opcode_t    opcode;
      csr_addr_t  csr;
      opcode = opcode_t'(instr);
      csr    = csr_addr_t'(instr >> 20);
      if (opcode != OPCODE_SYSTEM) return 1'b0;
      // counter CSRs: mcycle/minstret B00/B02 (+h B80/B82),
      // cycle/time/instret C00/C01/C02 (+h C80..C82) - timing by nature
      case (csr)
        CSR_MCYCLE, CSR_MINSTRET, CSR_MCYCLEH, CSR_MINSTRETH,
        CSR_CYCLE,  CSR_TIME,     CSR_INSTRET,
        CSR_CYCLEH, CSR_TIMEH,    CSR_INSTRETH: return 1'b1;
        default: return 1'b0;
      endcase
    endfunction : is_counter_csr_read

    // page-granular MMIO match via the named cfg mask (MMIO_REGION_MASK)
    protected function bit is_mmio_addr(xlen_word_t addr);
      xlen_word_t region;
      region = addr & MMIO_REGION_MASK;
      return (region == (MMIO_SIM_BASE & MMIO_REGION_MASK)) ||
             (region == (MMIO_TIMER_BASE & MMIO_REGION_MASK));
    endfunction : is_mmio_addr

    // retiring load with an MMIO address hint?
    protected function bit is_mmio_load(scr1_commit_s c);
      opcode_t opcode;
      opcode = opcode_t'(c.instr);
      return (opcode == OPCODE_LOAD) && c.mem_valid &&
             is_mmio_addr(c.mem_addr);
    endfunction : is_mmio_load

    // ---- main comparison (phase A, per DUT commit) -----------------------
    virtual function void write_commit(scr1_commit_tr tr);
      scr1_commit_s d, r;
      string bad;
      bit    irq_trap;

      if (ref_m == null) return;  // compare disabled (no ref configured)

      // DUT-only traps: IRQ devices (timer/IPIC/soft) are not modeled by
      // the refs; 2A CSV replay produces no trap records at all
      irq_trap = ((tr.c.mcause & MCAUSE_IRQ_BIT) != 0);
      if (tr.c.trap && (irq_trap || !ref_m.supports_traps())) begin
        g_diff_skipped++;
        `uvm_info({get_type_name(), ".SKIP_TRAP"},
            $sformatf("trap commit skipped (%s): pc=0x%08h mcause=0x%08h",
                      irq_trap ? "IRQ, devices not modeled"
                               : "ref model without trap records",
                      tr.c.pc, tr.c.mcause), UVM_HIGH)
        return;
      end

      d = tr.c;
      if (!ref_m.get_next(r)) begin
        // golden stream ends at the first EXIT_PC commit; post-exit spin
        // (j .) commits until the driver retires the run are benign
        if (d.pc == EXIT_PC) begin
          g_diff_skipped++;
          `uvm_info({get_type_name(), ".EXIT_SPIN"},
              "post-exit spin commit at 0xF8 skipped (golden stream complete)",
              UVM_HIGH)
          return;
        end
        g_diff_mismatches++;
        `uvm_error({get_type_name(), ".REF_EMPTY"},
            $sformatf("reference exhausted, DUT commit has no golden pair: %s",
                      tr.convert2string()))
        return;
      end

      bad = "";
      if (d.trap) begin
        // trap alignment (2B): compare mepc+mcause only; DUT instr is the
        // FFFFFFFF marker (golden carries the faulting opcode)
        g_diff_traps++;
        if (!r.trap) begin
          bad = {bad, $sformatf(
              " trap[dut=EXC(mcause=0x%08h) ref=NORMAL - golden did not trap]",
              d.mcause)};
          if (d.pc !== r.pc)
            bad = {bad, $sformatf(" pc[dut=0x%08h ref=0x%08h]", d.pc, r.pc)};
        end else begin
          if (d.pc !== r.pc)
            bad = {bad, $sformatf(" mepc[dut=0x%08h ref=0x%08h]", d.pc, r.pc)};
          if (d.mcause !== r.mcause)
            bad = {bad, $sformatf(" mcause[dut=0x%08h ref=0x%08h]",
                                  d.mcause, r.mcause)};
        end
      end else begin
        if (r.trap)
          bad = {bad, $sformatf(
              " trap[dut=NORMAL ref=EXC(mcause=0x%08h) - DUT missed the trap]",
              r.mcause)};
        if (d.pc !== r.pc)
          bad = {bad, $sformatf(" pc[dut=0x%08h ref=0x%08h]", d.pc, r.pc)};
        if (d.instr !== r.instr)
          bad = {bad, $sformatf(" instr[dut=0x%08h ref=0x%08h]", d.instr, r.instr)};
        if (d.rd_wr !== r.rd_wr) begin
          bad = {bad, $sformatf(" rd_wr[dut=%0b ref=%0b]", d.rd_wr, r.rd_wr)};
        end else if (d.rd_wr) begin
          if (d.rd_addr !== r.rd_addr)
            bad = {bad, $sformatf(" rd[dut=x%0d ref=x%0d]", d.rd_addr, r.rd_addr)};
          // value filters (timing/device dependent sources)
          if (is_counter_csr_read(d.instr) || is_mmio_load(d)) begin
            g_diff_skipped++;
            `uvm_info({get_type_name(), ".SKIP_VAL"},
                $sformatf("rd value filter (%s): %s",
                    is_counter_csr_read(d.instr) ? "counter CSR" : "MMIO load",
                    tr.convert2string()), UVM_HIGH)
          end else if (d.rd_data !== r.rd_data) begin
            bad = {bad, $sformatf(" rd_data[dut=0x%08h ref=0x%08h x%0d]",
                                  d.rd_data, r.rd_data, d.rd_addr)};
          end
        end
        // ---- CSR write event (phase A): presence + address only. Values
        // diverge by design: DUT csr_w_data is the bus OPERAND (pipe_csr
        // applies WRITE/SET/CLEAR), golden is the RESULT - value checking
        // is the M7 live mirror's and phase B's job. Trap steps carry no
        // golden event; MRET mstatus update bypasses the CSR bus. ----
        if (!r.trap && (d.csr_w_req || r.csr_w_req)) begin
          g_csr_diff_checked++;
          if (d.csr_w_req !== r.csr_w_req) begin
            csr_diff_err($sformatf(
                "csr_w_req[dut=%0b ref=%0b] csr_addr[dut=0x%03h ref=0x%03h]",
                d.csr_w_req, r.csr_w_req, d.csr_addr, r.csr_addr), tr);
          end else if (d.csr_addr !== r.csr_addr) begin
            csr_diff_err($sformatf("csr_addr[dut=0x%03h ref=0x%03h]",
                                   d.csr_addr, r.csr_addr), tr);
          end
        end
      end

      g_diff_checked++;
      if (bad == "") begin
        g_diff_matched++;
        `uvm_info({get_type_name(), ".MATCHED"}, tr.convert2string(), UVM_HIGH)
      end else begin
        g_diff_mismatches++;
        if (g_diff_mismatches <= SCB_MAX_LOG) begin
          `uvm_error({get_type_name(), ".MISMATCH"},
              $sformatf("commit #%0d mismatch:%s | dut: %s", g_diff_checked, bad,
                        tr.convert2string()))
        end else if (g_diff_mismatches == SCB_MAX_LOG + 1) begin
          `uvm_error({get_type_name(), ".LOG_LIMIT"},
              $sformatf("detailed mismatch log capped at %0d messages, further mismatches counted only",
                        SCB_MAX_LOG))
        end
      end
    endfunction : write_commit

    // ---- CSR_DIFF error (phase A), detailed log capped like MISMATCH ----
    protected function void csr_diff_err(string what, scr1_commit_tr tr);
      g_csr_diff_mismatches++;
      if (g_csr_diff_mismatches <= SCB_MAX_LOG) begin
        `uvm_error({get_type_name(), ".CSR_DIFF"},
            $sformatf("CSR write event mismatch: %s | dut: %s",
                      what, tr.convert2string()))
      end else if (g_csr_diff_mismatches == SCB_MAX_LOG + 1) begin
        `uvm_error({get_type_name(), ".CSR_DIFF_LIMIT"},
            $sformatf({"detailed CSR diff log capped at %0d messages, ",
                       "further mismatches counted only"}, SCB_MAX_LOG))
      end
    endfunction : csr_diff_err

    // ---- RUN-EXIT CSR CROSS-CHECK (phase B, 2B only) ---------------------
    // Inert without a ref model or without live CSR state (2A CSV).
    virtual function void on_run_end(scr1_transaction tr);
      if (ref_m == null) return;
      if (!ref_m.supports_csr_read()) begin
        `uvm_info({get_type_name(), ".CSR_EXIT_DIFF"},
            $sformatf({"run %0d: ref model %s has no CSR read API - ",
                       "exit cross-check skipped"},
                      tr.id, ref_m.model_name()), UVM_HIGH)
        return;
      end
      // INCLUDE list; masks neutralize known-legal WARL/model divergences
      // (README 2B section):
      //   mstatus 0x1888 - MIE|MPIE|MPP only (no S/U bits on SCR1; Spike
      //     M-only legalizes MPP to 11 like the SCR1 hardwiring);
      //   mie 0x0888 - MSIE|MTIE|MEIE only;
      //   mtvec 0xFFC1 - SCR1 BASE is 64B-granular (Spike 4B), MODE 1 bit;
      //   mepc ~(2**MEPC_PAD-1) - both sides hard-zero low align bits;
      //   mcause 0x8000_000F - SCR1 ec is a 4-bit WARL truncation of the
      //     wider Spike ec (e46329b finding);
      //   mscratch - full RW both sides, complete compare.
      // Excluded: counters B00/B02/B80/B82 (free-running timing), mip 0x344
      //   (DUT device lines vs none in Spike), mcounten 0x7E0 (SCR1 custom,
      //   Spike get_csr throws), misa 0x301 + F11-F14 (model constants;
      //   checked vs SCR1 truth by M3/M7 RAL), mtval 0x343 (trap-value
      //   semantics differ; live-tracked by M7 vs DUT truth).
      check_exit_csr(tr, CSR_MSTATUS,  tr.csr.mstatus,  MSTATUS_CMP_MASK);
      check_exit_csr(tr, CSR_MIE,      tr.csr.mie,      MIE_MASK);
      check_exit_csr(tr, CSR_MTVEC,    tr.csr.mtvec,    MTVEC_CMP_MASK);
      check_exit_csr(tr, CSR_MSCRATCH, tr.csr.mscratch, CSR_MASK_FULL);
      check_exit_csr(tr, CSR_MEPC,     tr.csr.mepc,     MEPC_MASK);
      check_exit_csr(tr, CSR_MCAUSE,   tr.csr.mcause,   MCAUSE_MASK);
    endfunction : on_run_end

    protected function void check_exit_csr(scr1_transaction tr, csr_addr_t a,
                                           csr_data_t dut_v, csr_data_t mask);
      csr_data_t ref_v;
      if (!ref_m.get_csr_value(a, ref_v)) begin
        `uvm_info({get_type_name(), ".CSR_EXIT_DIFF"},
            $sformatf("run %0d: CSR 0x%03h not readable in %s - skipped",
                      tr.id, a, ref_m.model_name()), UVM_LOW)
        return;
      end
      g_csr_diff_checked++;
      if ((dut_v & mask) !== (ref_v & mask)) begin
        g_csr_diff_mismatches++;
        `uvm_error({get_type_name(), ".CSR_EXIT_DIFF"},
            $sformatf({"run %0d: exit CSR 0x%03h DUT 0x%08h != ref 0x%08h ",
                       "(mask 0x%08h, ref %s)"},
                tr.id, a, dut_v, ref_v, mask, ref_m.model_name()))
      end
    endfunction : check_exit_csr

    virtual function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      if (ref_m != null) begin
        `uvm_info({get_type_name(), ".SUMMARY"},
            $sformatf({"%s: commits checked %0d | matched %0d | mismatches %0d",
                       " | traps compared %0d | skipped %0d | ref left %0d",
                       " | csr diff checked %0d | csr diff mismatches %0d"},
                ref_m.model_name(), g_diff_checked, g_diff_matched,
                g_diff_mismatches, g_diff_traps, g_diff_skipped,
                ref_m.remaining(), g_csr_diff_checked, g_csr_diff_mismatches),
            UVM_LOW)
      end
    endfunction : report_phase

  endclass : scr1_cosim_scoreboard
