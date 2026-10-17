/// Copyright by Syntacore LLC (c) 2016-2024. See LICENSE for details
/// @file       <scr1_trace_disasm.sv>
/// @brief      Simulation instruction trace / disassembler (waveform / VCD)
///
/// Analogous to biRISC-V biriscv_trace_sim.v: decodes a fetched instruction into
/// mnemonic and operand fields. The fields are packed vectors (not SV string)
/// so they are dumped into the waveform (VCD) by the Verilator waveform build
/// (run_verilator_wf) and can be viewed in a wave viewer (e.g. GTKWave) as ASCII.
///
/// Bound to the IFU->IDU stage; enabled by SCR1_TRACE_DISASM_EN
/// (sim makefile: TRACE_DISASM=1).
///
/// The whole decode lives inside the automatic function `disasm`, so its
/// internal variables (inst/opcode/funct3/rs1/rd/imm_*) are NOT separate
/// signals. The only trace signals are the synchronous dbg_inst_* record:
/// on every clock edge where the instruction is accepted by the IDU, all
/// fields are captured together (same edge, no flicker) and always describe
/// the same instruction; dbg_inst_pc is byte-accurate (RVC aware).
///

`include "scr1_arch_description.svh"

`ifdef SCR1_TRGT_SIMULATION

module scr1_trace_disasm (
    input   logic                                 rst_n,         // Reset
    input   logic                                 clk,           // Clock
    input   logic                                 valid_i,       // Instruction accepted by IDU
    input   logic                                 new_pc_req_i,  // Fetch redirect (jump/trap/init)
    input   logic [`SCR1_XLEN-1:0]                new_pc_i,      // Redirect target / reset vector
    input   logic [`SCR1_IMEM_DWIDTH-1:0]         instr_i        // Instruction
);

//------------------------------------------------------------------------------
// ABI register names (packed so they appear in the VCD)
//------------------------------------------------------------------------------
import scr1_trace_decoder_pkg::*;

//------------------------------------------------------------------------------
// Exact instruction PC: advanced by instruction length (2 for RVC, 4 for RVI)
// and resynced on fetch redirects (jump/trap/reset). Byte-accurate for RVC.
//------------------------------------------------------------------------------
logic [`SCR1_XLEN-1:0] pc_ff;
wire  is_rvc = ~(&instr_i[1:0]);   // 16-bit compressed instruction

always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
        pc_ff <= SCR1_ARCH_RST_VECTOR;
    end else if (new_pc_req_i) begin
        pc_ff <= new_pc_i;
    end else if (valid_i) begin
        pc_ff <= pc_ff + (is_rvc ? 32'd2 : 32'd4);
    end
end

// Combinational decode result: {unk[352], str[351:272], ra[271:192], rb[191:112], rd[111:32], imm[31:0]}
wire [352:0] dec = disasm(instr_i, pc_ff);

// Human-readable one-line disassembly (packed ASCII), e.g. "addi 0x23, t0, sp"
wire [383:0] txt = fmt_txt(dec[351:272], dec[271:192], dec[191:112], dec[111:32], dec[31:0]);

//------------------------------------------------------------------------------
// Synchronous trace record: everything captured on one clock edge when the
// instruction is accepted by the IDU. All dbg_inst_* switch together.
//------------------------------------------------------------------------------
logic [79:0] dbg_inst_str;                                   // Mnemonic
logic [79:0] dbg_inst_ra;                                    // rs1 name
logic [79:0] dbg_inst_rb;                                    // rs2 name
logic [79:0] dbg_inst_rd;                                    // rd name
logic [31:0] dbg_inst_imm;                                   // Immediate / target / csr
logic [31:0] dbg_inst_pc;                                    // Instruction PC (byte-accurate)
logic [31:0] dbg_inst_instr;                                 // Raw instruction
logic [6:0]  dbg_inst_opcode;                                // instr[6:0]
logic [5:0]  dbg_inst_rs1_idx;                               // rs1 index (3F = none)
logic [5:0]  dbg_inst_rs2_idx;                               // rs2 index (3F = none)
logic [5:0]  dbg_inst_rd_idx;                                // rd index  (3F = none)
logic [4:0]  dbg_inst_rs1_raw;                               // raw instr[19:15]
logic [4:0]  dbg_inst_rs2_raw;                               // raw instr[24:20]
logic [4:0]  dbg_inst_rd_raw;                                // raw instr[11:7]
logic [2:0]  dbg_inst_funct3;                                // raw instr[14:12]
logic [6:0]  dbg_inst_funct7;                                // raw instr[31:25]
logic [383:0] dbg_inst_txt;                                  // one-line disassembly (ASCII)
logic        dbg_inst_unknown;                               // 1 = encoder not decoded (coverage)
logic        dbg_inst_valid;                                 // Record valid

always_ff @(negedge rst_n, posedge clk) begin
    if (~rst_n) begin
        dbg_inst_str     <= "-";
        dbg_inst_ra      <= "-";
        dbg_inst_rb      <= "-";
        dbg_inst_rd      <= "-";
        dbg_inst_imm     <= '0;
        dbg_inst_pc      <= '0;
        dbg_inst_instr   <= '0;
        dbg_inst_opcode  <= '0;
        dbg_inst_rs1_idx <= 6'h3F;
        dbg_inst_rs2_idx <= 6'h3F;
        dbg_inst_rd_idx  <= 6'h3F;
        dbg_inst_rs1_raw <= '0;
        dbg_inst_rs2_raw <= '0;
        dbg_inst_rd_raw  <= '0;
        dbg_inst_funct3  <= '0;
        dbg_inst_funct7  <= '0;
        dbg_inst_txt     <= '0;
        dbg_inst_unknown <= 1'b0;
        dbg_inst_valid   <= 1'b0;
    end else if (valid_i) begin
        dbg_inst_str     <= dec[351:272];
        dbg_inst_ra      <= dec[271:192];
        dbg_inst_rb      <= dec[191:112];
        dbg_inst_rd      <= dec[111:32];
        dbg_inst_imm     <= dec[31:0];
        dbg_inst_pc      <= pc_ff;
        dbg_inst_instr   <= instr_i;
        dbg_inst_opcode  <= instr_i[6:0];
        dbg_inst_rs1_idx <= regname_to_idx(dec[271:192]);
        dbg_inst_rs2_idx <= regname_to_idx(dec[191:112]);
        dbg_inst_rd_idx  <= regname_to_idx(dec[111:32]);
        dbg_inst_rs1_raw <= instr_i[19:15];
        dbg_inst_rs2_raw <= instr_i[24:20];
        dbg_inst_rd_raw  <= instr_i[11:7];
        dbg_inst_funct3  <= instr_i[14:12];
        dbg_inst_funct7  <= instr_i[31:25];
        dbg_inst_txt     <= txt;
        dbg_inst_unknown <= dec[352];
        dbg_inst_valid   <= 1'b1;
    end
end

endmodule : scr1_trace_disasm

`endif // SCR1_TRGT_SIMULATION
