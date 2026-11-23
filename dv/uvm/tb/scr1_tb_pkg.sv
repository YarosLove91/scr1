// ============================================================
// File    : scr1_tb_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Common testbench package: virtual interface types, shared
// decoders and the global verdict counters (SCR1_RESULT). All
// compile-time configuration lives in scr1_cfg_pkg; UVM classes
// live in the local packages (scr1_seq_pkg / scr1_agent_pkg /
// scr1_env_pkg / scr1_test_pkg). Transaction flow: sequence
// passes the vector path -> driver loads + releases reset ->
// monitor observes (console MMIO + exit PC + a0) -> scoreboard.
// Details: dv/uvm/README.md.
// ============================================================
`ifndef SCR1_TB_PKG_SV
`define SCR1_TB_PKG_SV

package scr1_tb_pkg;

  import uvm_pkg::*;
  import scr1_cfg_pkg::*;
  // memory + device model class via the package chain (compiled right before)
  import scr1_mem_model_pkg::*;

  `include "uvm_macros.svh"

  // Virtual interface type (instantiated in scr1_tb_top)
  typedef virtual scr1_if scr1_vif;

  // Commit observation bus (RVFI-lite) - shared by the cosim and CSR monitors
  typedef virtual scr1_commit_if scr1_commit_vif;

  // Stage B (MEM_AGENT=1): the agent publishes the memory-model
  // singleton in the package global below; the DUT harness consumes
  // it on the load/peek/poke handshakes (class handle via package
  // global - the g_load_path transport pattern; a string/handle
  // cannot cross the vif boundary). Compiled BEFORE scr1_dut.sv.

  // Virtual interface of the memory agent (scr1_ahb_mem_if)
  typedef virtual scr1_ahb_mem_if scr1_mem_vif;

  // Virtual interface of the IRQ agent (scr1_irq_if)
  typedef virtual scr1_irq_if scr1_irq_vif;

  // shared memory-model handle (null until the agent builds it)
  scr1_mem_model g_mem_model = null;

  // Commit record (RVFI-lite, milestone 2): one per retired
  // instruction / trap event; the DUT side fills it from the
  // scr1_commit_probe bus, the reference side (CSV / Spike DPI)
  // produces the same layout. Types come from scr1_cfg_pkg.
  typedef struct packed {
    bit          valid;
    bit          trap;             // exception/IRQ entry event
    csr_data_t   mcause;           // valid when trap
    xlen_word_t  trap_val;         // exu2csr_trap_val of the trap cycle
                                   // (mtval <- trap_val on exceptions, <- 0
                                   //  on IRQs - scr1_pipe_csr.sv)
    xlen_word_t  pc;               // retire PC (trap: mepc)
    raw_opcode_t instr;            // raw opcode (trap: 0xFFFFFFFF marker)
    bit          rd_wr;            // GPR writeback (rd != x0)
    reg_idx_t    rd_addr;
    xlen_word_t  rd_data;
    bit          mem_we;           // DMEM write of a retiring store
    bit          mem_valid;        // mem_addr/mem_wdata are meaningful
    xlen_word_t  mem_addr;
    xlen_word_t  mem_wdata;
    // CSR side of the retiring instruction (M7 live RAL predict), captured
    // in the retire cycle (EXU asserts the request bus with instret)
    bit          csr_r_req;        // exu2csr_r_req (CSR read performed)
    bit          csr_w_req;        // exu2csr_w_req (CSR write strobe)
    csr_addr_t   csr_addr;         // exu2csr_rw_addr
    csr_data_t   csr_r_data;       // csr2exu_r_data (old value read)
    csr_data_t   csr_w_data;       // exu2csr_w_data (EXU CSR ALU result)
    csr_data_t   csr_rs1;          // mprf2exu_rs1_data (rs1 operand)
  } scr1_commit_s;

  // CSR transaction type (M7): the CSR access decoded into an
  // abstract READ / WRITE / ATOMIC_RW operation, derived from the
  // retiring instruction (NOT carried on the probe bus). Gating
  // follows the RISC-V spec and scr1_pipe_exu.sv: CSRRW/I always
  // writes, reads iff rd != x0; CSRRS/C(I) writes iff the rs1/uimm
  // FIELD != 0 (register number, NOT the rs1 value), always reads.
  typedef enum bit [1:0] {
    CSR_TXN_NONE      = 2'b00,  // not a CSR access (or invalid)
    CSR_TXN_READ      = 2'b01,
    CSR_TXN_WRITE     = 2'b10,
    CSR_TXN_ATOMIC_RW = 2'b11
  } scr1_csr_txn_e;

  // decode the CSR transaction type; CSR_TXN_NONE for non-CSR instructions
  function automatic scr1_csr_txn_e scr1_csr_txn_of(raw_opcode_t instr);
    opcode_t  opcode;
    funct3_t  funct3;
    reg_idx_t rd_field, rs1_field;
    bit       is_rw, writes, reads;
    opcode = opcode_t'(instr);
    if (opcode != OPCODE_SYSTEM) return CSR_TXN_NONE;   // SYSTEM opcode only
    funct3 = funct3_t'(instr >> 12);
    if (funct3 == '0) return CSR_TXN_NONE;  // non-CSR (ecall/mret/...)
    rd_field  = reg_idx_t'(instr >> 7);
    rs1_field = reg_idx_t'(instr >> 15);                 // rs1 number OR uimm
    is_rw     = (funct3 == FUNCT3_CSRRW) || (funct3 == FUNCT3_CSRRWI);
    writes    = is_rw || (rs1_field != '0);
    reads     = (!is_rw) || (rd_field != '0);
    if (writes && reads)  return CSR_TXN_ATOMIC_RW;
    if (writes)           return CSR_TXN_WRITE;
    if (reads)            return CSR_TXN_READ;
    return CSR_TXN_NONE;
  endfunction : scr1_csr_txn_of

  function automatic string scr1_csr_txn_name(scr1_csr_txn_e t);
    case (t)
      CSR_TXN_READ      : return "READ";
      CSR_TXN_WRITE     : return "WRITE";
      CSR_TXN_ATOMIC_RW : return "ATOMIC_RW";
      default           : return "NONE";
    endcase
  endfunction : scr1_csr_txn_name

  // CSR instruction decode (M7): one entry point for everything the
  // scoreboard needs from the retiring SYSTEM instruction - no
  // scattered field slicing. Reuses scr1_csr_txn_e (NO duplicate
  // enum; csr_access_e of scr1_csr_ral_pkg is the RAL adapter API).
  typedef struct packed {
    bit            valid;      // SYSTEM opcode with a CSR funct3
    csr_addr_t     addr;       // CSR index (instr[31:20])
    scr1_csr_txn_e txn;        // READ / WRITE / ATOMIC_RW / NONE
    bit            is_imm;     // immediate form (csrrwi/si/ci)
    bit            op_set;     // SET family   (csrrs/csrrsi)
    bit            op_clear;   // CLEAR family (csrrc/csrrci)
    funct3_t       funct3;
    reg_idx_t      rd;         // instr[11:7]
    reg_idx_t      rs1;        // instr[19:15] - rs1 number OR uimm
  } scr1_csr_dec_s;

  function automatic scr1_csr_dec_s scr1_csr_dec(raw_opcode_t instr);
    scr1_csr_dec_s d;
    opcode_t       opcode;
    d        = '0;
    opcode   = opcode_t'(instr);
    d.funct3 = funct3_t'(instr >> 12);
    d.addr   = csr_addr_t'(instr >> 20);
    d.rd     = reg_idx_t'(instr >> 7);
    d.rs1    = reg_idx_t'(instr >> 15);
    d.is_imm = d.funct3[2];
    d.op_set    = (d.funct3 == FUNCT3_CSRRS) || (d.funct3 == FUNCT3_CSRRSI);
    d.op_clear  = (d.funct3 == FUNCT3_CSRRC) || (d.funct3 == FUNCT3_CSRRCI);
    d.valid  = (opcode == OPCODE_SYSTEM) && (d.funct3 != '0);
    d.txn    = d.valid ? scr1_csr_txn_of(instr) : CSR_TXN_NONE;
    return d;
  endfunction : scr1_csr_dec

  // Global verdict counters (milestone-1 simplification; feeds
  // the SCR1_RESULT line of scr1_base_test)
  int unsigned g_item_id       = 0;
  int unsigned g_runs_checked  = 0;
  int unsigned g_runs_passed   = 0;
  int unsigned g_runs_failed   = 0;
  int unsigned g_console_chars = 0;
  // commit-stream differential counters (milestone 2)
  int unsigned g_diff_checked    = 0;
  int unsigned g_diff_matched    = 0;
  int unsigned g_diff_mismatches = 0;
  int unsigned g_diff_skipped    = 0;  // filtered (IRQ traps/timing CSRs/MMIO)
  int unsigned g_diff_traps      = 0;  // precise-exception traps compared
  // CSR RAL mirror counters (milestone 3)
  int unsigned g_csr_checked     = 0;
  int unsigned g_csr_mismatches  = 0;
  int unsigned g_csr_live        = 0;  // live CSR events golden-checked (m7)
  // cross-model CSR diff counters (2B: DUT vs the live Spike golden state)
  int unsigned g_csr_diff_checked    = 0;
  int unsigned g_csr_diff_mismatches = 0;

endpackage : scr1_tb_pkg

`endif // SCR1_TB_PKG_SV
