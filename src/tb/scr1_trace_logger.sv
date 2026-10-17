/// Copyright by Syntacore LLC (c) 2016-2024. See LICENSE for details
/// @file       <scr1_trace_logger.sv>
/// @brief      Program execution text trace logger (simulation only)
///
/// One text line per retired instruction (AI_logger_promt.md):
///   <Cycle> <PC> <Opcode> <RD write> <Status>
/// - Opcode is the raw instruction word; trap events (IRQ/EXC) print 0x--------.
/// - RD write is "x<N> = 0x<VALUE>", empty for no write or rd = x0.
/// - Status is IRQ/EXC/MRET/SRET, empty for a normal instruction.
///
/// The raw instruction is not available in the EXU, so the logger keeps a small
/// FIFO of {pc, instr} pushed on every instruction accepted by the IDU (with a
/// byte-accurate PC) and matches the retiring PC, skipping flushed entries.
///
/// Enabled by SCR1_TRACE_LOGGER_EN (sim makefile: TRACE_LOGGER=1).
///

`include "scr1_arch_description.svh"

`ifndef SCR1_TRACE_LOG_FILE
`define SCR1_TRACE_LOG_FILE "scr1_trace.log"
`endif

`ifdef SCR1_TRACE_LOGGER_DISASM_EN
`define SCR1_TRACE_LOGGER_DISASM_DFLT 1'b1
`else
`define SCR1_TRACE_LOGGER_DISASM_DFLT 1'b0
`endif

`ifdef SCR1_TRACE_LOGGER_TRAP_DETAIL_EN
`define SCR1_TRACE_LOGGER_TRAP_DETAIL_DFLT 1'b1
`else
`define SCR1_TRACE_LOGGER_TRAP_DETAIL_DFLT 1'b0
`endif

`ifdef SCR1_TRGT_SIMULATION

module scr1_trace_logger #(
    parameter string LOG_FILE          = `SCR1_TRACE_LOG_FILE,
    parameter bit    TRACE_TRAP_DETAIL = `SCR1_TRACE_LOGGER_TRAP_DETAIL_DFLT, // trap details
    parameter bit    TIME_MODE         = 1'b0, // 1 = $time, 0 = internal cycle counter
    parameter bit    DISASM_EN         = `SCR1_TRACE_LOGGER_DISASM_DFLT, // append mnemonic/operands
    parameter int    FIFO_DEPTH        = 16
)(
    input   logic                                 rst_n,
    input   logic                                 clk,
    // Issue (instruction accepted by IDU)
    input   logic                                 issue_vd_i,
    input   logic [`SCR1_IMEM_DWIDTH-1:0]         issue_instr_i,
    input   logic                                 redirect_i,
    input   logic [`SCR1_XLEN-1:0]                redirect_pc_i,
    // Retirement (EXU)
    input   logic                                 retire_i,
    input   logic [`SCR1_XLEN-1:0]                retire_pc_i,
    input   logic                                 rd_wr_i,
    input   logic [4:0]                           rd_addr_i,
    input   logic [`SCR1_XLEN-1:0]                rd_data_i,
    // Trap / return events (CSR)
    input   logic                                 exc_i,
    input   logic                                 irq_i,
    input   logic [`SCR1_XLEN-1:0]                mepc_i,
    input   logic [5:0]                           mcause_ec_i,
    input   logic                                 mcause_irq_i,
    input   logic [`SCR1_XLEN-1:0]                mtvec_i,
    input   logic [`SCR1_XLEN-1:0]                mtval_i
);

import scr1_trace_decoder_pkg::*;

//------------------------------------------------------------------------------
// File handle
//------------------------------------------------------------------------------
integer trace_fd;

// Free-running cycle counter (Verilator $time is not advanced by this tb)
logic [63:0] time_cnt;

always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) time_cnt <= '0;
    else        time_cnt <= time_cnt + 1'b1;
end

string log_file;

initial begin
    $timeformat(-9, 0, " ns", 12);
    if (!$value$plusargs("TRACE_LOG=%s", log_file))
        log_file = LOG_FILE;
    trace_fd = $fopen(log_file, "w");
    if (trace_fd == 0) begin
        $display("SCR1_TRACE_LOGGER: cannot open %s", log_file);
    end else begin
        $fdisplay(trace_fd, "# SCR1 program execution trace");
        $fdisplay(trace_fd, "%s", rtrim($sformatf("%10s %-10s %-10s %-20s %-8s",
                  "Cycle", "PC", "Opcode", "RD write", "Status")));
    end
end

//------------------------------------------------------------------------------
// Trim trailing whitespace (TZ: no trailing spaces in a line)
//------------------------------------------------------------------------------
function automatic string rtrim (input string s);
    int  i;
    byte b;
begin
    i = s.len() - 1;
    while (i >= 0) begin
        b = s[i];
        if ((b != 8'h20) && (b != 8'h09)) break;
        i = i - 1;
    end
    rtrim = (i >= 0) ? s.substr(0, i) : "";
end
endfunction

//------------------------------------------------------------------------------
// Byte-accurate PC of the instruction accepted by the IDU
//------------------------------------------------------------------------------
logic [`SCR1_XLEN-1:0] pc_ff;
wire  is_rvc = ~(&issue_instr_i[1:0]);

always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
        pc_ff <= SCR1_ARCH_RST_VECTOR;
    end else if (redirect_i) begin
        pc_ff <= redirect_pc_i;
    end else if (issue_vd_i) begin
        pc_ff <= pc_ff + (is_rvc ? 32'd2 : 32'd4);
    end
end

//------------------------------------------------------------------------------
// Instruction FIFO {pc, instr}
//------------------------------------------------------------------------------
localparam int AW = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
localparam int CW = $clog2(FIFO_DEPTH + 1);

logic [`SCR1_XLEN-1:0] f_pc    [0:FIFO_DEPTH-1];
logic [31:0]           f_instr [0:FIFO_DEPTH-1];

logic [AW-1:0] f_head;
logic [AW-1:0] f_tail;
logic [CW-1:0] f_count;

logic [31:0] ret_instr;
logic        ret_found;

// Optional mnemonic/operands (DISASM_EN=1)
wire [352:0] dec_ret = disasm(ret_instr, retire_pc_i);
wire [383:0] dis_ret_str = fmt_txt(dec_ret[351:272], dec_ret[271:192], dec_ret[191:112],
                               dec_ret[111:32], dec_ret[31:0]);

// Trap instruction decode (uses mepc as PC) - for trap details
wire [352:0] dec_trap = disasm(ret_instr, mepc_i);
wire [383:0] dis_trap_str = fmt_txt(dec_trap[351:272], dec_trap[271:192], dec_trap[191:112],
                                dec_trap[111:32], dec_trap[31:0]);

always_comb begin
    logic [AW-1:0] idx;
    logic [CW-1:0] k;
    logic          found;
    logic [31:0]   ins;

    ret_instr = 32'h00000000;
    ret_found = 1'b0;
    found     = 1'b0;
    ins       = 32'h00000000;

    for (k = 0; k < FIFO_DEPTH; k = k + 1) begin
        idx = (f_head + k[AW-1:0]) & (FIFO_DEPTH - 1);
        if (!found && (k < f_count) && (f_pc[idx] == retire_pc_i)) begin
            found = 1'b1;
            ins   = f_instr[idx];
        end
    end

    ret_found = found;
    ret_instr = ins;
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

//------------------------------------------------------------------------------
// Logging
//------------------------------------------------------------------------------
logic [31:0] mcause_val;
assign mcause_val = {mcause_irq_i, 31'b0} | {26'b0, mcause_ec_i};

string line;
string pc_str;
string op_str;
string rd_str;
string st_str;

always_ff @(negedge rst_n, posedge clk) begin
    if (rst_n && (trace_fd != 0)) begin
        // Trap events: IRQ/EXC (priority EXC > IRQ), opcode = 0x--------, PC = mepc
        if (exc_i || irq_i) begin
            pc_str = $sformatf("0x%08h", mepc_i);
            op_str = "0x--------";
            rd_str = "";
            st_str = exc_i ? "EXC" : "IRQ";
            if (TIME_MODE)
                line = $sformatf("%10t %-10s %-10s %-20s %-8s", $time, pc_str, op_str, rd_str, st_str);
            else
                line = $sformatf("%10d %-10s %-10s %-20s %-8s", time_cnt, pc_str, op_str, rd_str, st_str);
            if (TRACE_TRAP_DETAIL) begin
                line = {line, $sformatf(" | mcause=0x%08h mepc=0x%08h mtval=0x%08h mtvec=0x%08h instr=0x%08h",
                                        mcause_val, mepc_i, mtval_i, mtvec_i, ret_instr)};
                if (DISASM_EN && ret_found)
                    line = {line, $sformatf(" (%s)", dis_trap_str)};
            end
            $fdisplay(trace_fd, "%s", rtrim(line));
        end

        // Retired instruction (suppressed for the faulting instruction, which
        // is represented by the EXC trap line above)
        if (retire_i && !exc_i) begin
            pc_str = $sformatf("0x%08h", retire_pc_i);
            op_str = $sformatf("0x%08h", ret_instr);
            rd_str = (rd_wr_i && (rd_addr_i != 5'd0))
                   ? $sformatf("x%0d = 0x%08h", rd_addr_i, rd_data_i) : "";
            if (ret_instr == 32'h30200073)      st_str = "MRET";
            else if (ret_instr == 32'h10200073) st_str = "SRET";
            else                                st_str = "";
            if (TIME_MODE)
                line = $sformatf("%10t %-10s %-10s %-20s %-8s", $time, pc_str, op_str, rd_str, st_str);
            else
                line = $sformatf("%10d %-10s %-10s %-20s %-8s", time_cnt, pc_str, op_str, rd_str, st_str);
            if (DISASM_EN)
                line = {line, " | ", $sformatf("%s", dis_ret_str)};
            $fdisplay(trace_fd, "%s", rtrim(line));
        end
    end
end

endmodule : scr1_trace_logger

`endif // SCR1_TRGT_SIMULATION
