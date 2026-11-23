// ============================================================
// File    : scr1_fcov_if.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Functional coverage interface (lowRISC ibex fcov pattern):
// coverage lives in an RTL-side interface sampling the
// commit/pipeline signals, NOT in UVM classes (class-scope
// covergroups are unsupported by the host simulator;
// interface-scope are). Covergroups: uarch_cg (retire category x
// stall cross), insn_cg (ISA fields), exc_cg (mcause EC/IRQ),
// irq_cg / irq_line_cg (serviced ext IRQ line masks). Collected
// with COV=1 (--coverage-user); report via the simulator's
// coverage tool - see the 'run' recipe in dv/uvm/Makefile.
// NB: never start a comment line with the simulator vendor word -
// it is parsed as a lint meta-comment (BADVLTPRAGMA).
// ============================================================
`timescale 1ns/1ps

interface scr1_fcov_if
  import scr1_cfg_pkg::*;
(
    input logic        clk,
    input logic        rst_n,

    // ---- commit channel (scr1_commit_probe) ----
    input logic        commit_valid,
    input logic        commit_trap,
    input csr_data_t   commit_mcause,
    input raw_opcode_t commit_instr,
    input logic        commit_rd_wr,
    input reg_idx_t    commit_rd_addr,
    input logic        commit_stall_imem,
    input logic        commit_stall_dmem,
    input raw_opcode_t commit_trap_instr,  // real opcode of the trapping insn
                                           // (FIFO match), FFFFFFFF if unknown

    // ---- live pipeline state ----
    input logic        imem_stall,
    input logic        dmem_stall,
    input logic        redirect,

    // ---- live external IRQ lines to the core (IPIC inputs) ----
    input irq_lines_t    irq_lines
);

  // instruction categories (ibex InstrCategory pattern, adapted to RV32IMC +
  // the SCR1 SYSTEM subset)
  typedef enum {
    CatNone,
    CatALU,        // OP / OP-IMM
    CatMUL,        // M ext: mul/mulh*
    CatDIV,        // M ext: div/rem
    CatBranch,
    CatJump,       // jal/jalr
    CatLoad,
    CatStore,
    CatLuiAuipc,
    CatCSRAccess,
    CatECall,
    CatEBreak,
    CatMRet,
    CatWFI,
    CatFence,
    CatFenceI,
    CatCAlu,       // RVC arithmetic/misc
    CatCLdSt,      // RVC load/store (incl. sp variants)
    CatCBranch,    // c.beqz/c.bnez
    CatCJump,      // c.j/c.jal/c.jr/c.jalr
    CatOther
  } instr_cat_e;

  function automatic instr_cat_e decode_cat(raw_opcode_t ins);
    rvc_quadrant_t cq;    // compressed quadrant  (ins[1:0])
    funct3_t       cf3;   // compressed funct3    (ins[15:13])
    opcode_t       op;    // major opcode         (ins[6:0])
    funct3_t       f3;    // funct3               (ins[14:12])
    funct7_t       f7;    // funct7               (ins[31:25])
    csr_addr_t     csr;   // SYSTEM funct12       (ins[31:20])
    // ---- compressed (quadrant-level, coarse by design) ----
    cq = rvc_quadrant_t'(ins);
    if (cq != RVC_QUAD_32B) begin
      if (ins == raw_opcode_t'(RVC_C_EBREAK)) return CatEBreak;   // c.ebreak
      cf3 = funct3_t'(ins >> 13);
      case (cq)
        2'b00: return CatCLdSt;                // c.lw/c.sw (+ sp variants)
        2'b01: begin
          case (cf3)
            3'b101: return CatCJump;           // c.j
            3'b110,
            3'b111: return CatCBranch;         // c.beqz/c.bnez
            default: return CatCAlu;           // c.addi/c.li/c.lui/c.alu...
          endcase
        end
        default: begin                         // 2'b10
          case (cf3)
            3'b000: return CatCAlu;            // c.slli
            3'b010,
            3'b110: return CatCLdSt;           // c.lwsp/c.swsp
            3'b100: return CatCJump;           // c.jr/c.jalr (c.mv counted here too)
            default: return CatCAlu;
          endcase
        end
      endcase
    end
    // ---- 32-bit ----
    op  = opcode_t'(ins);
    f3  = funct3_t'(ins >> 12);
    f7  = funct7_t'(ins >> 25);
    csr = csr_addr_t'(ins >> 20);
    case (op)
      OPCODE_LUI,
      OPCODE_AUIPC: return CatLuiAuipc;
      OPCODE_MISC_MEM: return (f3 == FUNCT3_FENCE_I) ? CatFenceI : CatFence;
      OPCODE_LOAD:  return CatLoad;
      OPCODE_STORE: return CatStore;
      OPCODE_OP_IMM: return CatALU;            // OP-IMM
      OPCODE_OP: begin                         // OP
        if (f7 == FUNCT7_MULDIV)
          return (f3 inside {3'b000, 3'b001, 3'b010, 3'b011})
                 ? CatMUL : CatDIV;            // mul/mulh/mulhsu/mulhu vs div*
        return CatALU;
      end
      OPCODE_BRANCH: return CatBranch;
      OPCODE_JAL,
      OPCODE_JALR: return CatJump;
      OPCODE_SYSTEM: begin                     // SYSTEM
        if (f3 != '0) return CatCSRAccess;
        case (csr)
          FUNCT12_ECALL:  return CatECall;
          FUNCT12_EBREAK: return CatEBreak;
          FUNCT12_MRET:   return CatMRet;
          FUNCT12_WFI:    return CatWFI;
          default: return CatOther;
        endcase
      end
      default: return CatOther;
    endcase
  endfunction : decode_cat

  // Sampled/derived signals
  instr_cat_e retire_cat;
  instr_cat_e trap_cat;
  // {imem,dmem} sticky stall pair (2-bit aggregate sampled by cp_retire_stall)
  logic [1:0] retire_stall;
  logic       retire_insn;    // normal retired instruction
  logic       retire_trap;

  // typed field extraction for the insn_cg sample call (single point,
  // mirrors decode_cat - no raw slices at the sample arguments)
  opcode_t       smp_op;
  funct3_t       smp_f3;
  funct7_t       smp_f7;
  reg_idx_t      smp_rs1;
  csr_addr_t     smp_csr;
  rvc_quadrant_t smp_cq;
  bit            smp_is_c;

  always_comb begin
    retire_cat   = decode_cat(commit_instr);
    trap_cat     = (commit_trap_instr == TRAP_INSTR_MARKER) ? CatNone
                                                            : decode_cat(commit_trap_instr);
    retire_stall = {commit_stall_imem, commit_stall_dmem};
    retire_insn  = rst_n && commit_valid && !commit_trap;
    retire_trap  = rst_n && commit_valid && commit_trap;

    smp_cq   = rvc_quadrant_t'(commit_instr);
    smp_is_c = (smp_cq != RVC_QUAD_32B);
    smp_op   = opcode_t'(commit_instr);
    smp_f3   = funct3_t'(commit_instr >> 12);
    smp_f7   = funct7_t'(commit_instr >> 25);
    smp_rs1  = reg_idx_t'(commit_instr >> 15);
    smp_csr  = csr_addr_t'(commit_instr >> 20);
  end

  // uarch_cg - pipeline behavior (ibex uarch_cg pattern)
  covergroup uarch_cg @(posedge clk);
    option.per_instance = 1;
    cp_retire_cat: coverpoint retire_cat iff (retire_insn) {
      bins alu        = {CatALU};
      bins mul        = {CatMUL};
      bins div        = {CatDIV};
      bins branch     = {CatBranch};
      bins jump       = {CatJump};
      bins load       = {CatLoad};
      bins store      = {CatStore};
      bins lui_auipc  = {CatLuiAuipc};
      bins csr_access = {CatCSRAccess};
      bins mret       = {CatMRet};
      bins wfi        = {CatWFI};
      bins fence      = {CatFence};
      bins fence_i    = {CatFenceI};
      bins c_alu      = {CatCAlu};
      bins c_ldst     = {CatCLdSt};
      bins c_branch   = {CatCBranch};
      bins c_jump     = {CatCJump};
      bins other      = {CatOther};
      // NOTE: ecall/ebreak never retire (they trap) - covered by cp_trap_cat;
      // ibex samples categories in the ID stage instead.
    }
    // trapping instruction category (real opcode via the probe FIFO match):
    // closes the ecall/ebreak bins unreachable on the retire stream
    cp_trap_cat: coverpoint trap_cat iff (retire_trap) {
      bins ecall      = {CatECall};
      bins ebreak     = {CatEBreak};
      bins csr_access = {CatCSRAccess};   // illegal CSR access traps
      bins other      = {CatALU, CatMUL, CatDIV, CatBranch, CatJump,
                         CatLoad, CatStore, CatLuiAuipc, CatMRet, CatWFI,
                         CatFence, CatFenceI, CatCAlu, CatCLdSt, CatCBranch,
                         CatCJump, CatOther};
      bins unknown    = {CatNone};        // IRQ over a flushed slot etc.
    }
    cp_retire_stall: coverpoint retire_stall iff (retire_insn) {
      bins no_stall   = {2'b00};
      bins imem_stall = {2'b01};
      bins dmem_stall = {2'b10};
      bins both_stall = {2'b11};
    }
    // ibex cross: instruction category under stall conditions
    x_cat_stall: cross cp_retire_cat, cp_retire_stall;
    cp_live_imem_stall: coverpoint imem_stall iff (rst_n) {
      bins none_ = {1'b0}; bins stall_ = {1'b1};
    }
    cp_live_dmem_stall: coverpoint dmem_stall iff (rst_n) {
      bins none_ = {1'b0}; bins stall_ = {1'b1};
    }
    cp_redirect: coverpoint redirect iff (rst_n) {
      bins none_ = {1'b0}; bins redir_ = {1'b1};
    }
    cp_trap: coverpoint retire_trap iff (rst_n) {
      bins none_ = {1'b0}; bins trap_ = {1'b1};
    }
  endgroup

  // insn_cg - ISA coverage, sampled per retired instruction
  covergroup insn_cg with function sample(
      opcode_t       op,
      funct3_t       f3,
      funct7_t       f7,
      reg_idx_t      rd,
      reg_idx_t      rs1,
      csr_addr_t     csr,
      bit            is_c,
      bit            rd_wr,
      rvc_quadrant_t cq
  );
    option.per_instance = 1;

    cp_opcode: coverpoint op iff (!is_c) {
      bins lui     = {OPCODE_LUI};
      bins auipc   = {OPCODE_AUIPC};
      bins fence_  = {OPCODE_MISC_MEM};
      bins load    = {OPCODE_LOAD};
      bins store   = {OPCODE_STORE};
      bins op_imm  = {OPCODE_OP_IMM};
      bins op      = {OPCODE_OP};
      bins branch  = {OPCODE_BRANCH};
      bins jal     = {OPCODE_JAL};
      bins jalr    = {OPCODE_JALR};
      bins system  = {OPCODE_SYSTEM};
    }
    cp_rvc_quadrant: coverpoint cq iff (is_c) {
      bins c0 = {2'b00}; bins c1 = {2'b01}; bins c2 = {2'b10};
    }
    cp_alu_f3: coverpoint f3 iff (!is_c && ((op == OPCODE_OP && f7 != FUNCT7_MULDIV) ||
                                            op == OPCODE_OP_IMM)) {
      bins f3_bins[] = {[0:7]};
    }
    cp_m_f3: coverpoint f3 iff (!is_c && op == OPCODE_OP && f7 == FUNCT7_MULDIV) {
      bins m_bins[] = {[0:7]};
    }
    cp_branch_f3: coverpoint f3 iff (!is_c && op == OPCODE_BRANCH) {
      bins beq  = {3'b000}; bins bne  = {3'b001};
      bins blt  = {3'b100}; bins bge  = {3'b101};
      bins bltu = {3'b110}; bins bgeu = {3'b111};
    }
    cp_ls_f3: coverpoint f3 iff (!is_c && (op == OPCODE_LOAD || op == OPCODE_STORE)) {
      bins lb  = {3'b000}; bins lh  = {3'b001};
      bins lw  = {3'b010}; bins lbu = {3'b100};
      bins lhu = {3'b101};
    }
    cp_rd: coverpoint rd iff (rd_wr) {
      bins rd_bins[] = {[0:31]};
    }
    cp_rs1: coverpoint rs1 iff (!is_c && op != OPCODE_LUI && op != OPCODE_AUIPC &&
                                op != OPCODE_JAL) {
      bins rs1_bins[] = {[0:31]};
    }
    cp_csr: coverpoint csr iff (!is_c && op == OPCODE_SYSTEM && f3 != '0) {
      bins mstatus   = {CSR_MSTATUS}; bins misa     = {CSR_MISA};
      bins mie       = {CSR_MIE};     bins mtvec    = {CSR_MTVEC};
      bins mscratch  = {CSR_MSCRATCH};bins mepc     = {CSR_MEPC};
      bins mcause    = {CSR_MCAUSE};  bins mtval    = {CSR_MTVAL};
      bins mip       = {CSR_MIP};
      bins mcycle    = {CSR_MCYCLE};  bins minstret = {CSR_MINSTRET};
      bins mcycleh   = {CSR_MCYCLEH}; bins minstreth= {CSR_MINSTRETH};
      bins cycle_ro  = {CSR_CYCLE};   bins time_ro  = {CSR_TIME};
      bins instret_ro= {CSR_INSTRET};
      bins mcounten  = {CSR_MCOUNTEN};
      bins mvendorid = {CSR_MVENDORID}; bins marchid = {CSR_MARCHID};
      bins mimpid    = {CSR_MIMPID};    bins mhartid = {CSR_MHARTID};
    }
    // ibex-style cross: which registers were written by which opcode class
    x_opcode_rd: cross cp_opcode, cp_rd;
  endgroup

  // exc_cg - exceptions / interrupts, sampled per trap commit
  covergroup exc_cg with function sample(csr_data_t mcause);
    option.per_instance = 1;
    // ec through the named WARL mask (bits [5:4] always 0 on SCR1 - the ec
    // flop is 4 bits - bin hits unchanged)
    cp_ec: coverpoint (mcause & MCAUSE_EC_MASK) {
      bins misaligned_fetch  = {6'd0};
      bins fetch_access      = {6'd1};
      bins illegal_instr     = {6'd2};
      bins breakpoint        = {6'd3};
      bins misaligned_load   = {6'd4};
      bins load_access       = {6'd5};
      bins misaligned_store  = {6'd6};
      bins store_access      = {6'd7};
      bins ecall_u           = {6'd8};
      bins ecall_m           = {6'd11};
    }
    cp_irq: coverpoint (mcause & MCAUSE_IRQ_BIT) {
      bins exception_  = {'0};
      bins interrupt   = {MCAUSE_IRQ_BIT};
    }
    x_irq_ec: cross cp_irq, cp_ec;
  endgroup

  // IRQ line coverage (ext-IRQ trap commits only). The ext trap commit
  // can land AFTER the injected pulse dropped (IPIC edge-latches the
  // lines, drain ~15 cycles/trap), so LIVE lines are not enough:
  // irq_burst accumulates the OR of the lines since the previous ext
  // trap commit - the mask this trap's burst carried. Sampled per ext
  // trap: live count (dropped = 0 bin), burst count (single vs
  // multi-line coincidence), highest-priority line of the mask (lowest
  // set bit - the IPIC search-one SOI order, sim/tests/irq_stress),
  // count x priority cross, per-line presence bins (irq_line_cg).
  logic       ext_irq_commit;
  irq_lines_t irq_burst;   // lines since the last ext trap
  irq_lines_t irq_sample;  // burst + the current live lines

  always_comb begin
    ext_irq_commit = rst_n && commit_valid && commit_trap &&
                     (commit_mcause == MCAUSE_M_EXT_IRQ);
    irq_sample     = irq_burst | irq_lines;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      irq_burst <= '0;
    end else if (ext_irq_commit) begin
      irq_burst <= '0;          // sampled this cycle - restart the burst
    end else begin
      irq_burst <= irq_burst | irq_lines;
    end
  end

  function automatic irq_line_cnt_t count_ones(irq_lines_t v);
    irq_line_cnt_t c;
    c = '0;
    for (int i = 0; i < IRQ_LINES_NUM; i++) begin
      if (v[i]) c = c + irq_line_cnt_t'(1);
    end
    return c;
  endfunction : count_ones

  // lowest set bit index (highest IPIC priority), 0 when v == 0
  function automatic irq_line_idx_t low_bit(irq_lines_t v);
    for (int i = 0; i < IRQ_LINES_NUM; i++) begin
      if (v[i]) return irq_line_idx_t'(i);
    end
    return '0;
  endfunction : low_bit

  covergroup irq_cg with function sample(
      irq_line_cnt_t live_cnt,
      irq_line_cnt_t burst_cnt,
      irq_line_idx_t low_line
  );
    option.per_instance = 1;
    cp_live_cnt: coverpoint live_cnt {
      bins dropped = {0};             // pulse ended before this trap commit
      bins one     = {1};
      bins few     = {[2:3]};
      bins many    = {[4:8]};
      bins storm   = {[9:IRQ_LINES_NUM]};
    }
    cp_burst_cnt: coverpoint burst_cnt {
      bins one     = {1};
      bins few     = {[2:3]};
      bins many    = {[4:8]};
      bins storm   = {[9:IRQ_LINES_NUM]};
    }
    cp_low_line: coverpoint low_line iff (burst_cnt != 0) {
      bins line[] = {[0:IRQ_LINES_NUM-1]};
    }
    x_cnt_low: cross cp_burst_cnt, cp_low_line;
  endgroup

  covergroup irq_line_cg with function sample(irq_line_idx_t idx);
    option.per_instance = 1;
    cp_line: coverpoint idx {
      bins line[] = {[0:IRQ_LINES_NUM-1]};
    }
  endgroup

  uarch_cg    u_uarch     = new();
  insn_cg     u_insn      = new();
  exc_cg      u_exc       = new();
  irq_cg      u_irq       = new();
  irq_line_cg u_irq_line  = new();

  // Sampling
  always @(posedge clk) begin
    if (rst_n && commit_valid) begin
      if (commit_trap) begin
        u_exc.sample(commit_mcause);
        if (commit_mcause == MCAUSE_M_EXT_IRQ) begin
          u_irq.sample(count_ones(irq_lines),
                       count_ones(irq_sample),
                       low_bit(irq_sample));
          for (int i = 0; i < IRQ_LINES_NUM; i++) begin
            if (irq_sample[i]) begin
              u_irq_line.sample(irq_line_idx_t'(i));
            end
          end
        end
      end else begin
        u_insn.sample(smp_op,
                      smp_f3,
                      smp_f7,
                      commit_rd_addr,
                      smp_rs1,
                      smp_csr,
                      smp_is_c,
                      commit_rd_wr,
                      smp_cq);
      end
    end
  end

endinterface : scr1_fcov_if
