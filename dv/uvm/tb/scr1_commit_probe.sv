// ============================================================
// File    : scr1_commit_probe.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Commit probe (RVFI-lite commit channel, milestone 2): one
// commit record per retired instruction / trap event. pc/instr
// are byte-accurate via the {pc,instr} FIFO fed by the IDU issue
// stream (the proven scr1_trace_logger.sv mechanism); rd_* = the
// EXU->MPRF writeback; trap records carry PC=mepc, instr=
// 0xFFFFFFFF marker; mem_* come from a small LSU FIFO popped on
// the retire of a load/store.
// Env-side file (not a DUT copy): bound by tb/scr1_bind.sv (ibex
// fcov_bind pattern); fixed RV32 widths, no RTL-header includes -
// the mepc padding comes from scr1_cfg_pkg::MEPC_PAD.
// ============================================================
`timescale 1ns/1ps

module scr1_commit_probe
  import scr1_cfg_pkg::*;
#(
    parameter int FIFO_DEPTH = 16,
    parameter int LSU_FIFO_DEPTH = 4,
    // mepc padding: 1 with RVC (csr_mepc_next is [31:1]), 2 without
    // ([31:2]) - the probe reassembles the full 32-bit mepc value
    parameter int MEPC_PAD = 1
)(
    input  logic        clk,
    input  logic        rst_n,

    // ---- IDU issue stream (byte-accurate PC) ----
    input  logic        issue_vd_i,
    input  raw_opcode_t issue_instr_i,
    input  logic        redirect_i,
    input  xlen_word_t  redirect_pc_i,

    // ---- EXU retire ----
    input  logic        retire_i,
    input  xlen_word_t  retire_pc_i,
    input  logic        rd_wr_i,
    input  reg_idx_t    rd_addr_i,
    input  xlen_word_t  rd_data_i,

    // ---- CSR trap events ----
    input  logic        exc_i,
    input  logic        irq_i,
    input  logic [XLEN-MEPC_PAD-1:0] mepc_next_i,  // csr_mepc_next (flopped part)
    input  exc_code_t   mcause_ec_i,           // type_scr1_exc_code_e is 4-bit
    input  logic        mcause_irq_i,
    input  xlen_word_t  trap_val_i,            // exu2csr_trap_val (mtval src)

    // ---- CSR sideband (M7): latched at the REQUEST cycle - the EXU may
    // assert the pipe_csr requests one cycle before instret (latch below) ----
    input  logic        csr_r_req_i,   // exu2csr_r_req
    input  logic        csr_w_req_i,   // exu2csr_w_req
    input  csr_addr_t   csr_addr_i,    // exu2csr_rw_addr
    input  csr_data_t   csr_r_data_i,  // csr2exu_r_data (old value)
    input  csr_data_t   csr_w_data_i,  // exu2csr_w_data (EXU operand mux)
    input  csr_data_t   csr_rs1_i,     // mprf2exu_rs1_data (rs1 operand)

    // ---- DMEM requests (LSU) ----
    input  logic        dmem_req_i,
    input  logic        dmem_wr_i,
    input  xlen_word_t  dmem_addr_i,
    input  xlen_word_t  dmem_wdata_i,

    // ---- pipeline stall observation (fcov) ----
    input  logic        imem_stall_i,
    input  logic        dmem_stall_i,

    // ---- commit bus (registered, one-cycle pulses) ----
    output logic        commit_valid_o,
    output logic        commit_trap_o,
    output csr_data_t   commit_mcause_o,
    output xlen_word_t  commit_trap_val_o,  // mtval source of the trap cycle
    output xlen_word_t  commit_pc_o,
    output raw_opcode_t commit_instr_o,
    output raw_opcode_t commit_trap_instr_o,  // real opcode of the trapping insn
                                              // (FIFO match by mepc, fcov trap
                                              // categories); marker if not found
    output logic        commit_rd_wr_o,
    output reg_idx_t    commit_rd_addr_o,
    output xlen_word_t  commit_rd_data_o,
    output logic        commit_mem_we_o,
    output logic        commit_mem_addr_o_valid,
    output xlen_word_t  commit_mem_addr_o,
    output xlen_word_t  commit_mem_wdata_o,
    output logic        commit_stall_imem_o,
    output logic        commit_stall_dmem_o,
    // CSR sideband of the commit (live RAL predict in the scoreboard)
    output logic        commit_csr_r_req_o,
    output logic        commit_csr_w_req_o,
    output csr_addr_t   commit_csr_addr_o,
    output csr_data_t   commit_csr_r_data_o,
    output csr_data_t   commit_csr_w_data_o,
    output csr_data_t   commit_csr_rs1_o
);

  // full mepc reassembled from the flopped part (low MEPC_PAD bits are zero)
  wire xlen_word_t mepc_i = {mepc_next_i, {MEPC_PAD{1'b0}}};

  // byte-accurate PC of the IDU-accepted instruction (scr1_trace_logger logic)
  xlen_word_t pc_ff;
  wire  is_rvc = (rvc_quadrant_t'(issue_instr_i) != RVC_QUAD_32B);

  always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
      pc_ff <= RST_VECTOR;  // SCR1_ARCH_RST_VECTOR
    end else if (redirect_i) begin
      pc_ff <= redirect_pc_i;
    end else if (issue_vd_i) begin
      pc_ff <= pc_ff + (is_rvc ? xlen_word_t'(RVC_INSN_BYTES)
                               : xlen_word_t'(RVI_INSN_BYTES));
    end
  end

  // ---- instruction FIFO {pc, instr} (scr1_trace_logger logic) ----
  localparam int AW = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
  localparam int CW = $clog2(FIFO_DEPTH + 1);

  xlen_word_t  f_pc    [0:FIFO_DEPTH-1];
  raw_opcode_t f_instr [0:FIFO_DEPTH-1];

  logic [AW-1:0] f_head;
  logic [AW-1:0] f_tail;
  logic [CW-1:0] f_count;

  raw_opcode_t ret_instr;
  logic        ret_found;
  opcode_t     ret_opcode;

  always_comb begin
    logic [AW-1:0] idx;
    logic [CW-1:0] k;
    logic          found;
    raw_opcode_t   ins;

    ret_instr = '0;
    ret_found = 1'b0;
    found     = 1'b0;
    ins       = '0;

    for (k = 0; k < FIFO_DEPTH; k = k + 1) begin
      idx = (f_head + k[AW-1:0]) & (FIFO_DEPTH - 1);
      if (!found && (k < f_count) && (f_pc[idx] == retire_pc_i)) begin
        found = 1'b1;
        ins   = f_instr[idx];
      end
    end

    ret_found  = found;
    ret_instr  = ins;
    ret_opcode = opcode_t'(ins);
  end

  always_ff @(negedge rst_n, posedge clk) begin : fifo_update
    logic [AW-1:0] n_head;
    logic [AW-1:0] n_tail;
    logic [CW-1:0] n_count;
    integer        m;
    logic          hit;

    if (~rst_n) begin
      f_head  <= '0;
      f_tail  <= '0;
      f_count <= '0;
    end else begin
      n_head  = f_head;
      n_tail  = f_tail;
      n_count = f_count;

      if (retire_i && ret_found) begin
        hit = 1'b0;
        for (m = 0; m < FIFO_DEPTH; m = m + 1) begin
          if (!hit && (m < f_count) &&
              (f_pc[(f_head + m[AW-1:0]) & (FIFO_DEPTH - 1)] == retire_pc_i)) begin
            hit     = 1'b1;
            n_head  = (f_head + m[AW-1:0] + 1'b1) & (FIFO_DEPTH - 1);
            n_count = f_count - m[CW-1:0] - 1'b1;
          end
        end
      end

      if (issue_vd_i && (n_count < FIFO_DEPTH)) begin
        f_pc[n_tail]    <= pc_ff;
        f_instr[n_tail] <= issue_instr_i;
        n_tail          = (n_tail + 1'b1) & (FIFO_DEPTH - 1);
        n_count         = n_count + 1'b1;
      end

      f_head  <= n_head;
      f_tail  <= n_tail;
      f_count <= n_count;
    end
  end

  // Trapping-instruction lookup: the FIFO still holds the trapping instruction
  // (never retired/popped) - match by mepc for the fcov trap-category
  // coverpoint (ecall/ebreak never appear on the retire stream)
  raw_opcode_t mepc_instr;
  logic        mepc_found;

  always_comb begin
    logic [AW-1:0] midx;
    logic [CW-1:0] mk;
    mepc_found = 1'b0;
    mepc_instr = TRAP_INSTR_MARKER;
    for (mk = 0; mk < FIFO_DEPTH; mk = mk + 1) begin
      midx = (f_head + mk[AW-1:0]) & (FIFO_DEPTH - 1);
      if (!mepc_found && (mk < f_count) && (f_pc[midx] == mepc_i)) begin
        mepc_found = 1'b1;
        mepc_instr = f_instr[midx];
      end
    end
  end

  // LSU transaction FIFO (load/store requests -> retire attachment); pointer/
  // count widths derived from LSU_FIFO_DEPTH (the AW/CW pattern above)
  localparam int LAW = (LSU_FIFO_DEPTH > 1) ? $clog2(LSU_FIFO_DEPTH) : 1;
  localparam int LCW = $clog2(LSU_FIFO_DEPTH + 1);

  logic        l_we    [0:LSU_FIFO_DEPTH-1];
  xlen_word_t  l_addr  [0:LSU_FIFO_DEPTH-1];
  xlen_word_t  l_wdata [0:LSU_FIFO_DEPTH-1];
  logic [LAW-1:0] l_head, l_tail;
  logic [LCW-1:0] l_count;

  // retiring load/store? (OPCODE_LOAD / OPCODE_STORE)
  wire ret_is_mem = ret_found &&
      ((ret_opcode == OPCODE_LOAD) || (ret_opcode == OPCODE_STORE));

  always_ff @(negedge rst_n, posedge clk) begin : lsu_fifo
    if (~rst_n) begin
      l_head  <= '0;
      l_tail  <= '0;
      l_count <= '0;
    end else begin
      // push on DMEM request
      if (dmem_req_i && (l_count < LSU_FIFO_DEPTH)) begin
        l_we[l_tail]    <= dmem_wr_i;
        l_addr[l_tail]  <= dmem_addr_i;
        l_wdata[l_tail] <= dmem_wdata_i;
        l_tail          <= (l_tail + LAW'(1)) % LSU_FIFO_DEPTH;
        l_count         <= l_count - (ret_is_mem && retire_i && (l_count > 0) ? LCW'(1) : LCW'(0));
      end else if (ret_is_mem && retire_i && (l_count > 0)) begin
        // pop on the retire of a load/store
        l_head  <= (l_head + LAW'(1)) % LSU_FIFO_DEPTH;
        l_count <= l_count - LCW'(1);
      end
    end
  end

  wire        lsu_head_we    = l_we[l_head];
  wire xlen_word_t lsu_head_addr  = l_addr[l_head];
  wire xlen_word_t lsu_head_wdata = l_wdata[l_head];
  wire        lsu_head_valid = (l_count != 0);

  // per-instruction sticky stall flags (ibex fcov pattern): accumulated
  // between retires, latched into the commit record
  logic stall_imem_ff, stall_dmem_ff;

  always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
      stall_imem_ff <= 1'b0;
      stall_dmem_ff  <= 1'b0;
    end else if (retire_i || exc_i || irq_i) begin
      stall_imem_ff <= imem_stall_i;
      stall_dmem_ff  <= dmem_stall_i;
    end else begin
      if (imem_stall_i) stall_imem_ff <= 1'b1;
      if (dmem_stall_i) stall_dmem_ff  <= 1'b1;
    end
  end

  // CSR access latch (M7): the EXU->pipe_csr request fires 0..1 cycles BEFORE
  // instret - an access updating mstatus.MIE/mie stalls the EXU CSR FSM one
  // cycle (SCR1_CSR_INIT -> RDY, scr1_pipe_exu.sv), so at retire w_req is
  // already deasserted and csr2exu_r_data holds the POST-write value. The
  // latch captures the FIRST request cycle (r_data = true old value) and is
  // consumed by its retire - unambiguous: the EXU holds one instruction until
  // retire. Trap commits discard the latch (illegal access traps WITHOUT the
  // write; trap-entry updates bypass the exu2csr bus).
  logic        csr_acc_v;
  logic        csr_acc_r;
  logic        csr_acc_w;
  csr_addr_t   csr_acc_addr;
  csr_data_t   csr_acc_rdata;
  csr_data_t   csr_acc_wdata;
  csr_data_t   csr_acc_rs1;

  always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
      csr_acc_v <= 1'b0;
    end else if (retire_i || exc_i || irq_i) begin
      csr_acc_v <= 1'b0;  // consumed by this commit (live mux below)
    end else if ((csr_r_req_i || csr_w_req_i) && !csr_acc_v) begin
      csr_acc_v     <= 1'b1;
      csr_acc_r     <= csr_r_req_i;
      csr_acc_w     <= csr_w_req_i;
      csr_acc_addr  <= csr_addr_i;
      csr_acc_rdata <= csr_r_data_i;  // first request cycle = pre-write value
      csr_acc_wdata <= csr_w_data_i;
      csr_acc_rs1   <= csr_rs1_i;
    end
  end

  // emitted sideband: the latch when valid (stalled access), else the live
  // request signals (request and retire in the same cycle)
  wire csr_em_r     = csr_acc_v ? csr_acc_r : csr_r_req_i;
  wire csr_em_w     = csr_acc_v ? (csr_acc_w | csr_w_req_i) : csr_w_req_i;
  wire csr_addr_t  csr_em_addr  = csr_acc_v ? csr_acc_addr  : csr_addr_i;
  wire csr_data_t  csr_em_rdata = csr_acc_v ? csr_acc_rdata : csr_r_data_i;
  wire csr_data_t  csr_em_wdata = csr_acc_v ? csr_acc_wdata : csr_w_data_i;
  wire csr_data_t  csr_em_rs1   = csr_acc_v ? csr_acc_rs1   : csr_rs1_i;

  // Deferred trap record: an IRQ taken on a retire boundary (irq_i && retire_i
  // same cycle - the instruction HAS completed, its retire record incl. the
  // CSR sideband must reach the scoreboard; SCR1 asserts exu2pipe_instret and
  // exu2csr_take_irq together there). The retire record goes out immediately,
  // the trap event one cycle later from this register - the trap pipeline
  // flush guarantees no retire is lost in between. Exceptions take precedence
  // over a SAME-cycle retire (trap record only, the golden trap-step
  // convention).
  logic        trap_pend;
  csr_data_t   trap_pend_mcause;
  xlen_word_t  trap_pend_val;
  xlen_word_t  trap_pend_pc;
  raw_opcode_t trap_pend_tinstr;
  logic        trap_pend_si;
  logic        trap_pend_sd;

  wire irq_at_retire = irq_i && retire_i && !exc_i;

  // Commit register
  csr_data_t mcause_val;
  // structural mcause: {irq, zeros, ec[3:0]} - widths from XLEN/$bits(exc_code_t)
  assign mcause_val = {mcause_irq_i, {(XLEN-1){1'b0}}} |
                      {{(XLEN-$bits(exc_code_t)){1'b0}}, mcause_ec_i};

  always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
      commit_valid_o          <= 1'b0;
      commit_trap_o           <= 1'b0;
      commit_mcause_o         <= '0;
      commit_trap_val_o       <= '0;
      commit_pc_o             <= '0;
      commit_instr_o          <= '0;
      commit_trap_instr_o     <= '0;
      commit_rd_wr_o          <= 1'b0;
      commit_rd_addr_o        <= '0;
      commit_rd_data_o        <= '0;
      commit_mem_we_o         <= 1'b0;
      commit_mem_addr_o_valid <= 1'b0;
      commit_mem_addr_o       <= '0;
      commit_mem_wdata_o      <= '0;
      commit_stall_imem_o     <= 1'b0;
      commit_stall_dmem_o     <= 1'b0;
      commit_csr_r_req_o      <= 1'b0;
      commit_csr_w_req_o      <= 1'b0;
      commit_csr_addr_o       <= '0;
      commit_csr_r_data_o     <= '0;
      commit_csr_w_data_o     <= '0;
      commit_csr_rs1_o        <= '0;
      trap_pend               <= 1'b0;
    end else begin
      commit_valid_o <= 1'b0;
      if ((exc_i || irq_i) && !irq_at_retire) begin
        // trap event: PC = mepc, instr = marker (logger convention),
        // trap_instr = the real opcode found in the FIFO by mepc
        commit_valid_o  <= 1'b1;
        commit_trap_o   <= 1'b1;
        commit_mcause_o <= mcause_val;
        commit_trap_val_o <= trap_val_i;
        commit_pc_o     <= mepc_i;
        commit_instr_o  <= TRAP_INSTR_MARKER;
        commit_trap_instr_o <= mepc_found ? mepc_instr : TRAP_INSTR_MARKER;
        commit_rd_wr_o  <= 1'b0;
        commit_mem_we_o <= 1'b0;
        commit_mem_addr_o_valid <= 1'b0;
        commit_stall_imem_o <= stall_imem_ff;
        commit_stall_dmem_o <= stall_dmem_ff;
        // no CSR sideband on trap records: an illegal CSR access traps
        // WITHOUT the write; the scoreboard re-syncs its RAL mirror from
        // the trap record itself
        commit_csr_r_req_o <= 1'b0;
        commit_csr_w_req_o <= 1'b0;
        trap_pend <= 1'b0;
      end else if (trap_pend) begin
        // deferred trap record (IRQ on a retire boundary): retire went out
        // last cycle, the trap event follows now
        commit_valid_o  <= 1'b1;
        commit_trap_o   <= 1'b1;
        commit_mcause_o <= trap_pend_mcause;
        commit_trap_val_o <= trap_pend_val;
        commit_pc_o     <= trap_pend_pc;
        commit_instr_o  <= TRAP_INSTR_MARKER;
        commit_trap_instr_o <= trap_pend_tinstr;
        commit_rd_wr_o  <= 1'b0;
        commit_mem_we_o <= 1'b0;
        commit_mem_addr_o_valid <= 1'b0;
        commit_stall_imem_o <= trap_pend_si;
        commit_stall_dmem_o <= trap_pend_sd;
        commit_csr_r_req_o <= 1'b0;
        commit_csr_w_req_o <= 1'b0;
        trap_pend <= 1'b0;
      end else if (retire_i) begin
        commit_valid_o  <= 1'b1;
        commit_trap_o   <= 1'b0;
        commit_mcause_o <= '0;
        commit_pc_o     <= retire_pc_i;
        commit_instr_o  <= ret_instr;
        commit_trap_instr_o <= TRAP_INSTR_MARKER;
        commit_rd_wr_o  <= rd_wr_i && (rd_addr_i != '0);
        commit_rd_addr_o<= rd_addr_i;
        commit_rd_data_o<= rd_data_i;
        commit_mem_we_o <= ret_is_mem && lsu_head_valid && lsu_head_we;
        commit_mem_addr_o_valid <= ret_is_mem && lsu_head_valid;
        commit_mem_addr_o       <= lsu_head_addr;
        commit_mem_wdata_o      <= lsu_head_wdata;
        commit_stall_imem_o <= stall_imem_ff;
        commit_stall_dmem_o <= stall_dmem_ff;
        // CSR sideband: latched at the request cycle, merged at retire
        commit_csr_r_req_o  <= csr_em_r;
        commit_csr_w_req_o  <= csr_em_w;
        commit_csr_addr_o   <= csr_em_addr;
        commit_csr_r_data_o <= csr_em_rdata;
        commit_csr_w_data_o <= csr_em_wdata;
        commit_csr_rs1_o    <= csr_em_rs1;
      end
      // IRQ on this retire boundary: retire record now, trap record next cycle
      if (irq_at_retire) begin
        trap_pend        <= 1'b1;
        trap_pend_mcause <= mcause_val;
        trap_pend_val    <= trap_val_i;
        trap_pend_pc     <= mepc_i;
        trap_pend_tinstr <= mepc_found ? mepc_instr : TRAP_INSTR_MARKER;
        trap_pend_si     <= stall_imem_ff;
        trap_pend_sd     <= stall_dmem_ff;
      end
    end
  end

endmodule : scr1_commit_probe
