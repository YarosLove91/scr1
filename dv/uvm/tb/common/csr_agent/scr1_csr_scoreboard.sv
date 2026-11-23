// ============================================================
// File    : scr1_csr_scoreboard.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR RAL scoreboard: milestone 3 (run-exit snapshot checks) +
// milestone 7 (LIVE frontdoor-style predict on the commit stream).
// Live path: decode the CSR instruction independently of the DUT,
// compute the golden new value through the per-CSR WARL legalizer
// (SCR1 truth), check write presence/data and the read data;
// trap/MRET hardware updates bypass the exu2csr bus, so the mirror
// re-syncs from the commit records. Run-end path: COMPARE the DUT
// exit snapshot against the live-built mirror (catches the "write
// reached the mux but not the flop" class), then the legacy
// constants/invariants. Verdict via g_csr_* in scr1_tb_pkg.
// Details: dv/uvm/README.md (milestones 3, 7).
// ============================================================
  class scr1_csr_scoreboard extends uvm_subscriber #(scr1_transaction);
    `uvm_component_utils(scr1_csr_scoreboard)

    // RAL model, fetched from uvm_config_db (built/published by scr1_env)
    scr1_csr_top_block ral;

    protected csr_shadow_t shadow;

    // CSR address classes for the live path
    localparam int CLS_UNTRACKED = 0;  // not in RAL / not modeled (IPIC...)
    localparam int CLS_RW        = 1;  // full live tracking (read+write)
    localparam int CLS_COUNTER   = 2;  // write-checked, read/exit-lo skipped
    localparam int CLS_RO        = 3;  // constants (read-checked, no writes)
    localparam int CLS_HW        = 4;  // hardware-async (mip) - skipped

    // addr -> class map (built in new()); missing address = CLS_UNTRACKED
    // (IPIC 0xBF0-0xBF7, TDU 0x7A0-0x7A7 - not modeled in the RAL)
    protected int csr_class_of[csr_addr_t];

    // commit-stream TLM entry (imp_decl(_csr) in scr1_csr_agent_pkg); the
    // inherited analysis_export/write() stays the run-end stream entry
    uvm_analysis_imp_csr #(scr1_commit_tr, scr1_csr_scoreboard) commit_imp;

    function new(string name = "scr1_csr_scoreboard", uvm_component parent = null);
      super.new(name, parent);
      commit_imp = new("commit_imp", this);
      csr_class_of = '{
        CSR_MSTATUS:   CLS_RW,       CSR_MIE:       CLS_RW,
        CSR_MTVEC:     CLS_RW,       CSR_MSCRATCH:  CLS_RW,
        CSR_MEPC:      CLS_RW,       CSR_MCAUSE:    CLS_RW,
        CSR_MTVAL:     CLS_RW,       CSR_MCOUNTEN:  CLS_RW,
        CSR_MCYCLE:    CLS_COUNTER,  CSR_MINSTRET:  CLS_COUNTER,
        CSR_MCYCLEH:   CLS_COUNTER,  CSR_MINSTRETH: CLS_COUNTER,
        CSR_MISA:      CLS_RO,       CSR_MVENDORID: CLS_RO,
        CSR_MARCHID:   CLS_RO,       CSR_MIMPID:    CLS_RO,
        CSR_MHARTID:   CLS_RO,
        CSR_MIP:       CLS_HW        // device lines, not flops
      };
    endfunction : new

    // the agent owns its golden model (ibex pattern): fetch the RAL itself
    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_csr_top_block)::get(this, "", "reg_top_model", ral)) begin
        `uvm_fatal({get_type_name(), ".NORAL"},
            {"CSR RAL model (scr1_csr_top_block) not found in uvm_config_db ",
             "- scr1_env must publish it (uvm_root, \"*\", \"reg_top_model\") ",
             "before the CSR agent builds"})
      end
    endfunction : build_phase

    // ---- snapshot -> associative array (CSR addr -> value) -------------
    protected function void snapshot_pairs(scr1_csr_snap_s s,
                                          ref csr_shadow_t pairs);
      pairs = '{
        CSR_MSTATUS:   s.mstatus,   CSR_MISA:      s.misa,
        CSR_MIE:       s.mie,       CSR_MTVEC:     s.mtvec,
        CSR_MSCRATCH:  s.mscratch,  CSR_MEPC:      s.mepc,
        CSR_MCAUSE:    s.mcause,    CSR_MTVAL:     s.mtval,
        CSR_MIP:       s.mip,       CSR_MCOUNTEN:  s.mcounten,
        CSR_MCYCLE:    s.mcycle,    CSR_MINSTRET:  s.minstret,
        CSR_MCYCLEH:   s.mcycleh,   CSR_MINSTRETH: s.minstreth,
        CSR_MVENDORID: s.mvendorid, CSR_MARCHID:   s.marchid,
        CSR_MIMPID:    s.mimpid,    CSR_MHARTID:   s.mhartid
      };
    endfunction : snapshot_pairs

    protected function uvm_reg find_reg(csr_addr_t addr);
      uvm_reg r;
      if (ral == null) return null;
      r = ral.csr_map.get_reg_by_offset(addr);
      if (r == null) begin
        `uvm_error({get_type_name(), ".NOREG"},
            $sformatf("CSR 0x%03h not found in the RAL model", addr))
      end
      return r;
    endfunction : find_reg

    // quiet lookup for the live path (untracked addresses are legal there)
    protected function uvm_reg find_reg_quiet(csr_addr_t addr);
      if (ral == null) return null;
      return ral.csr_map.get_reg_by_offset(addr);
    endfunction : find_reg_quiet

    // ---- CSR classification / WARL legalizers -------------------------
    protected function int csr_class(csr_addr_t a);
      return csr_class_of.exists(a) ? csr_class_of[a] : CLS_UNTRACKED;
    endfunction : csr_class

    // SCR1 WARL truth (scr1_pipe_csr.sv): legal value stored for a raw write
    protected function csr_data_t csr_legalize(csr_addr_t a, csr_data_t raw);
      case (a)
        CSR_MSTATUS: csr_legalize = (raw & MSTATUS_WR_MASK) | MSTATUS_MPP;
                                  // mstatus: MIE|MPIE writable, MPP=11
        CSR_MIE:     csr_legalize = raw & MIE_MASK;        // MSIE|MTIE|MEIE
        CSR_MTVEC:   csr_legalize = {raw[XLEN-1:MTVEC_BASE_LSB],
                                     {(MTVEC_BASE_LSB-MTVEC_MODE_BITS){1'b0}},
                                     1'b0, raw[0]};
                                   // structural WARL: BASE 64B-granular
                                   // ([5:2]=0), MODE 1 bit (bit1 ignored)
        CSR_MSCRATCH: csr_legalize = raw;                  // mscratch: full RW
        CSR_MEPC:    csr_legalize = raw & MEPC_MASK;
                                  // mepc: low MEPC_PAD bits hardwired 0
        CSR_MCAUSE:  csr_legalize = raw & MCAUSE_MASK;
                                   // mcause {i,ec}: ec flop is 4 bits
                                   // (codes 0..11 fit) - legal WARL
                                   // truncation of [5:4] (CSR-fuzz
                                   // finding, seed 1519025353)
        CSR_MTVAL:   csr_legalize = raw;                  // mtval: full RW
        CSR_MCOUNTEN: csr_legalize = raw & MCOUNTEN_MASK;  // mcounten: CY|IR
        CSR_MCYCLE, CSR_MINSTRET,
        CSR_MCYCLEH, CSR_MINSTRETH: csr_legalize = raw;    // counters: full RW
        default: csr_legalize = raw;
      endcase
    endfunction : csr_legalize

    protected function csr_data_t mirror_get(csr_addr_t a);
      uvm_reg r = find_reg_quiet(a);
      return (r != null) ? r.get() : '0;
    endfunction : mirror_get

    protected function void mirror_set(csr_addr_t a, csr_data_t v);
      uvm_reg r = find_reg_quiet(a);
      if (r != null) void'(r.predict(v));
    endfunction : mirror_set

    // ---- LIVE PATH entry: commit-stream TLM write (imp_decl(_csr)) ----
    virtual function void write_csr(scr1_commit_tr t);
      on_commit(t.c);
    endfunction : write_csr

    // ---- LIVE PATH: one commit record ----------------------------------
    virtual function void on_commit(scr1_commit_s c);
      csr_addr_t     a;
      csr_data_t     old_v, operand, exp_operand, raw_new, exp;
      bit            should_write, writable;
      int            cls;
      scr1_csr_dec_s d;

      if (ral == null) return;

      // ---- trap record: re-sync the mirror with the trap-entry hardware
      // writes (they bypass the exu2csr_w_req bus) ----
      if (c.trap) begin
        mirror_set(CSR_MEPC, c.pc);        // mepc  <- trapping pc
        mirror_set(CSR_MCAUSE, c.mcause);  // mcause
        old_v = mirror_get(CSR_MSTATUS);   // mstatus: MPIE<-MIE, MIE<-0
        mirror_set(CSR_MSTATUS,
            (old_v & ~MSTATUS_WR_MASK) |
            ((old_v & MSTATUS_MIE) << MSTATUS_IE_SHIFT));
        // mtval: exceptions latch exu2csr_trap_val, IRQs write zero
        // (csr_mtval_next mux in scr1_pipe_csr.sv)
        mirror_set(CSR_MTVAL,
            ((c.mcause & MCAUSE_IRQ_BIT) != 0) ? '0 : c.trap_val);
        return;
      end

      // ---- MRET: mstatus MIE<-MPIE, MPIE<-1 ----
      if (c.instr == OPCODE_MRET) begin
        old_v = mirror_get(CSR_MSTATUS);
        mirror_set(CSR_MSTATUS,
            (old_v & ~MSTATUS_WR_MASK) |
            ((old_v & MSTATUS_MPIE) >> MSTATUS_IE_SHIFT) |
            MSTATUS_MPIE);
        return;
      end

      if (!c.csr_r_req && !c.csr_w_req) return;

      // ---- single-point instruction decode (scr1_csr_dec): CSR index,
      // access type (READ/WRITE/ATOMIC_RW), is_imm, SET/CLEAR family ----
      d = scr1_csr_dec(c.instr);
      if (!d.valid || (d.txn == CSR_TXN_NONE)) begin
        `uvm_error({get_type_name(), ".PROBE_ALIGN"},
            $sformatf("CSR req on a non-CSR commit: %s (probe capture misaligned?)",
                csr_evt_str(c)))
        return;
      end
      // addr canary: decoded index vs the probe-latched bus address
      if (d.addr !== c.csr_addr) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".PROBE_ALIGN"},
            $sformatf("decoded CSR 0x%03h != probed csr_addr 0x%03h | %s",
                d.addr, c.csr_addr, csr_evt_str(c)))
        return;
      end

      a   = d.addr;
      cls = csr_class(a);
      if (cls == CLS_UNTRACKED || cls == CLS_HW) return;  // IPIC etc. / mip
      if (find_reg_quiet(a) == null) return;

      // EXU muxes the operand onto exu2csr_w_data (rs1 or zimm,
      // scr1_pipe_exu.sv), so w_data IS the OPERAND (pipe_csr applies
      // WRITE/SET/CLEAR); the decode cross-checks the EXU routing
      operand     = c.csr_w_data;
      // zero-extended zimm operand (uimm lives in the rs1 field)
      exp_operand = d.is_imm ? csr_data_t'(d.rs1) : c.csr_rs1;
      // spec write gating: CSRRW always writes; CSRRS/C iff rs1/uimm
      // field != 0 (matches the scr1_pipe_exu.sv |rs1_addr gating)
      should_write = (d.txn == CSR_TXN_WRITE) || (d.txn == CSR_TXN_ATOMIC_RW);

      g_csr_live++;
      old_v = mirror_get(a);

      // ---- probe alignment canary: GPR writeback == CSR read data ----
      if (c.rd_wr && c.csr_r_req && (c.rd_data !== c.csr_r_data)) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".PROBE_ALIGN"},
            $sformatf("rd_data 0x%08h != csr_r_data 0x%08h: %s",
                c.rd_data, c.csr_r_data, csr_evt_str(c)))
      end

      // ---- operand routing check: EXU w_data vs the instruction decode ----
      if (operand !== exp_operand) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".OPERAND"},
            $sformatf({"CSR 0x%03h: EXU operand w_data 0x%08h != decoded ",
                       "%s operand 0x%08h | %s"},
                a, operand, d.is_imm ? "zimm" : "rs1", exp_operand,
                csr_evt_str(c)))
      end

      // ---- old-value check: probe latch captures the pre-write value at
      // the request cycle; skipped for counters (free-running) ----
      if ((cls == CLS_RW) || (cls == CLS_RO)) begin
        if (c.csr_r_data !== old_v) begin
          g_csr_mismatches++;
          `uvm_error({get_type_name(), ".LIVE_READ"},
              $sformatf({"CSR 0x%03h old value: DUT r_data 0x%08h != ",
                         "RAL golden 0x%08h | %s"},
                  a, c.csr_r_data, old_v, csr_evt_str(c)))
        end
      end

      // ---- write check + golden predict; the DUT-flopped result is
      // verified deferred (next-access old-value check + exit snapshot vs
      // live mirror - catches BUG-001/#80 mcycleh class) ----
      writable = (cls == CLS_RW) || (cls == CLS_COUNTER);
      if (should_write && writable) begin
        raw_new = (!d.op_set && !d.op_clear) ? operand :
                  d.op_set                   ? (old_v | operand) :
                                               (old_v & ~operand);
        exp = csr_legalize(a, raw_new);
        if (!c.csr_w_req) begin
          g_csr_mismatches++;
          `uvm_error({get_type_name(), ".WRITE_MISSING"},
              $sformatf({"CSR 0x%03h: golden write 0x%08h expected, ",
                         "DUT w_req=0 | %s"}, a, exp, csr_evt_str(c)))
        end
        mirror_set(a, exp);
      end else if (c.csr_w_req) begin
        if (!writable) begin
          `uvm_warning({get_type_name(), ".RO_WRITE"},
              $sformatf("DUT write strobe to RO CSR 0x%03h | %s",
                  a, csr_evt_str(c)))
        end else begin
          g_csr_mismatches++;
          `uvm_error({get_type_name(), ".WRITE_UNEXPECTED"},
              $sformatf({"CSR 0x%03h: DUT w_req=1 but the spec gates the ",
                         "write (rs1/uimm field = 0) | %s"},
                  a, csr_evt_str(c)))
        end
      end
    endfunction : on_commit

    protected function string csr_evt_str(scr1_commit_s c);
      return $sformatf("pc=0x%08h instr=0x%08h %s csr[0x%03h r=%0b w=%0b rdata=0x%08h wdata=0x%08h rs1=0x%08h]",
          c.pc, c.instr, scr1_csr_txn_name(scr1_csr_txn_of(c.instr)),
          c.csr_addr, c.csr_r_req, c.csr_w_req,
          c.csr_r_data, c.csr_w_data, c.csr_rs1);
    endfunction : csr_evt_str

    // ---- RUN-END PATH: one run transaction = one CSR snapshot ----------
    virtual function void write(scr1_transaction tr);
      csr_shadow_t snap;
      uvm_reg r;
      int cls;
      int unsigned live_mm_before;

      if (ral == null) return;
      snapshot_pairs(tr.csr, snap);
      live_mm_before = g_csr_mismatches;

      // 1. LIVE-mirror comparison (M7): the snapshot must equal the mirror
      //    built from golden semantics. Skipped: counters (lo halves tick
      //    every retire, hi halves take the lo-overflow carry - mcycle.hex
      //    provokes it by design; counter WRITES stay golden-checked live,
      //    hi-half flop bugs are caught by the run verdict and the Spike
      //    lockstep) and mip (device lines).
      foreach (snap[addr]) begin
        cls = csr_class(addr);
        if ((cls == CLS_HW) || (cls == CLS_COUNTER)) continue;
        if (snap[addr] !== mirror_get(addr)) begin
          g_csr_mismatches++;
          `uvm_error({get_type_name(), ".SNAPSHOT"},
              $sformatf({"run %0d: exit snapshot CSR 0x%03h = 0x%08h ",
                         "!= live RAL golden 0x%08h"},
                  tr.id, addr, snap[addr], mirror_get(addr)))
        end
      end
      if (g_csr_mismatches != live_mm_before) begin
        `uvm_info({get_type_name(), ".SNAPSHOT"},
            $sformatf({"run %0d: live-built mirror DIVERGED from the exit ",
                       "snapshot (see errors above)"}, tr.id), UVM_LOW)
      end

      // 2. predict the snapshot into RAL + shadow (M3: truthful report
      //    dump, feeds the constant checks)
      shadow = snap;
      foreach (snap[addr]) begin
        r = find_reg(addr);
        if (r != null) begin
          r.predict(snap[addr]);
          `uvm_info({get_type_name(), ".PREDICT"},
              $sformatf("WR 0x%03h <- 0x%08h [%s]", addr, snap[addr],
                        r.get_name()), UVM_HIGH)
        end
      end

      // 3. RAL vs shadow consistency
      check_ral_vs_shadow();

      // 4. hardware constants and run invariants
      check_const(tr, CSR_MVENDORID, "mvendorid", MVENDORID_RST_VAL);
      check_const(tr, CSR_MARCHID,   "marchid",   MARCHID_RST_VAL);
      check_const(tr, CSR_MIMPID,    "mimpid",    MIMPID_RST_VAL);
      check_const(tr, CSR_MHARTID,   "mhartid",   MHARTID_RST_VAL);
      check_const(tr, CSR_MISA,      "misa",      MISA_RST_VAL);
      if ((tr.csr.mstatus & MSTATUS_MPP) != MSTATUS_MPP) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".MPP"},
            $sformatf({"run %0d: mstatus 0x%08h: MPP != 2'b11 ",
                       "(expected 2'b11, M-only)"},
                      tr.id, tr.csr.mstatus))
      end
      if (tr.csr.minstret == 0 && tr.csr.minstreth == 0) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".MINSTRET"},
            $sformatf("run %0d: minstret is zero after a completed run", tr.id))
      end
      if ({tr.csr.mcycleh, tr.csr.mcycle} < {tr.csr.minstreth, tr.csr.minstret}) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".MCYCLE"},
            $sformatf("run %0d: mcycle(0x%08h_%08h) < minstret(0x%08h_%08h)",
                      tr.id, tr.csr.mcycleh, tr.csr.mcycle,
                      tr.csr.minstreth, tr.csr.minstret))
      end
      g_csr_checked++;

      // 5. NUM_RUNS > 1: the driver resets the DUT between runs - the
      //    mirror must reset too, else run k+1 compares against the
      //    previous run's leftovers. ral.reset() lands on the hardware
      //    reset values (RAL constants from scr1_pipe_csr.sv); the LAST
      //    run keeps the snapshot for the report dump.
      if (tr.id < NUM_RUNS) begin
        ral.reset();
        shadow.delete();
        `uvm_info({get_type_name(), ".RUN_RESET"},
            $sformatf({"run %0d of %0d done - RAL mirror/shadow reset ",
                       "for the next run"}, tr.id, NUM_RUNS), UVM_MEDIUM)
      end
    endfunction : write

    protected function void check_const(scr1_transaction tr, csr_addr_t addr,
                                        string name, csr_data_t expected);
      if (shadow.exists(addr) && (shadow[addr] !== expected)) begin
        g_csr_mismatches++;
        `uvm_error({get_type_name(), ".CONST"},
            $sformatf("run %0d: %s (0x%03h) = 0x%08h, expected 0x%08h",
                      tr.id, name, addr, shadow[addr], expected))
      end
    endfunction : check_const

    // ---- RAL mirror vs shadow (probe_scoreboard pattern) ---------------
    protected function void check_ral_vs_shadow();
      uvm_reg r;
      foreach (shadow[addr]) begin
        r = ral.csr_map.get_reg_by_offset(addr);
        if (r == null) continue;
        if (r.get() !== shadow[addr]) begin
          g_csr_mismatches++;
          `uvm_error({get_type_name(), ".RAL_SHADOW"},
              $sformatf("%s (0x%03h) mismatch: RAL=0x%08h shadow=0x%08h",
                        r.get_name(), addr, r.get(), shadow[addr]))
        end
      end
    endfunction : check_ral_vs_shadow

    virtual function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info({get_type_name(), ".SUMMARY"},
          $sformatf("CSR snapshots checked: %0d | live CSR events golden-checked: %0d | mismatches: %0d | shadow regs: %0d",
                    g_csr_checked, g_csr_live, g_csr_mismatches, shadow.size()), UVM_LOW)
      if (ral != null) begin
        `uvm_info({get_type_name(), ".DUMP"}, ral.sprint(), UVM_HIGH)
      end
    endfunction : report_phase

  endclass : scr1_csr_scoreboard
