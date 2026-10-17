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
function [79:0] get_regname_str;
    input [4:0] regnum;
begin
    case (regnum)
        5'd0 : get_regname_str = "zero";
        5'd1 : get_regname_str = "ra";
        5'd2 : get_regname_str = "sp";
        5'd3 : get_regname_str = "gp";
        5'd4 : get_regname_str = "tp";
        5'd5 : get_regname_str = "t0";
        5'd6 : get_regname_str = "t1";
        5'd7 : get_regname_str = "t2";
        5'd8 : get_regname_str = "s0";
        5'd9 : get_regname_str = "s1";
        5'd10: get_regname_str = "a0";
        5'd11: get_regname_str = "a1";
        5'd12: get_regname_str = "a2";
        5'd13: get_regname_str = "a3";
        5'd14: get_regname_str = "a4";
        5'd15: get_regname_str = "a5";
        5'd16: get_regname_str = "a6";
        5'd17: get_regname_str = "a7";
        5'd18: get_regname_str = "s2";
        5'd19: get_regname_str = "s3";
        5'd20: get_regname_str = "s4";
        5'd21: get_regname_str = "s5";
        5'd22: get_regname_str = "s6";
        5'd23: get_regname_str = "s7";
        5'd24: get_regname_str = "s8";
        5'd25: get_regname_str = "s9";
        5'd26: get_regname_str = "s10";
        5'd27: get_regname_str = "s11";
        5'd28: get_regname_str = "t3";
        5'd29: get_regname_str = "t4";
        5'd30: get_regname_str = "t5";
        5'd31: get_regname_str = "t6";
        default: get_regname_str = "?";
    endcase
end
endfunction

// Compressed register prime (x8 + idx)
function [79:0] get_regname_str_p;
    input [2:0] regnum;
begin
    get_regname_str_p = get_regname_str(5'(5'd8 + {2'b00, regnum}));
end
endfunction

// Reverse map: ABI name -> register index (x0..x31); 6'h3F means "no register".
function [5:0] regname_to_idx;
    input [79:0] nm;
    integer i;
begin
    regname_to_idx = 6'h3F;
    for (i = 0; i < 32; i = i + 1) begin
        if (nm == get_regname_str(i[4:0])) regname_to_idx = i[5:0];
    end
end
endfunction

// ASCII char for a hex nibble ('0'..'9', 'a'..'f')
function automatic [7:0] hexchar (input [3:0] n);
begin
    hexchar = (n < 4'd10) ? (8'h30 + {4'b0, n}) : (8'h57 + {4'b0, n});
end
endfunction

// Build a human-readable one-line disassembly, packed ASCII (48 bytes, left
// justified, zero padded), e.g. "addi 0x23, t0, sp". Fields that are unused
// (shown as "-") are skipped. Order: <mnemonic> 0x<imm8hex>, <rd>, <rs1>, <rs2>.
function automatic [383:0] fmt_txt (
    input [79:0] nm_str,
    input [79:0] nm_ra,
    input [79:0] nm_rb,
    input [79:0] nm_rd,
    input [31:0] imm
);
    logic [383:0] obuf;
    integer p;
    integer i;
    logic [7:0] ch;
begin
    obuf = '0;
    p   = 0;

    // mnemonic
    for (i = 0; i < 10; i = i + 1) begin
        ch = nm_str[79 - 8*i -: 8];
        if ((ch != 8'h00) && (p < 48)) begin obuf[383 - 8*p -: 8] = ch; p = p + 1; end
    end
    // " 0x"
    if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h20; p = p + 1; end
    if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h30; p = p + 1; end
    if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h78; p = p + 1; end
    // 8 hex digits of the immediate
    for (i = 7; i >= 0; i = i - 1) begin
        if (p < 48) begin obuf[383 - 8*p -: 8] = hexchar(imm[i*4 +: 4]); p = p + 1; end
    end

    // ", " + rd (if used)
    if (nm_rd != "-") begin
        if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h2c; p = p + 1; end
        if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h20; p = p + 1; end
        for (i = 0; i < 10; i = i + 1) begin
            ch = nm_rd[79 - 8*i -: 8];
            if ((ch != 8'h00) && (p < 48)) begin obuf[383 - 8*p -: 8] = ch; p = p + 1; end
        end
    end
    // ", " + rs1 (if used)
    if (nm_ra != "-") begin
        if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h2c; p = p + 1; end
        if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h20; p = p + 1; end
        for (i = 0; i < 10; i = i + 1) begin
            ch = nm_ra[79 - 8*i -: 8];
            if ((ch != 8'h00) && (p < 48)) begin obuf[383 - 8*p -: 8] = ch; p = p + 1; end
        end
    end
    // ", " + rs2 (if used)
    if (nm_rb != "-") begin
        if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h2c; p = p + 1; end
        if (p < 48) begin obuf[383 - 8*p -: 8] = 8'h20; p = p + 1; end
        for (i = 0; i < 10; i = i + 1) begin
            ch = nm_rb[79 - 8*i -: 8];
            if ((ch != 8'h00) && (p < 48)) begin obuf[383 - 8*p -: 8] = ch; p = p + 1; end
        end
    end

    fmt_txt = obuf;
end
endfunction

//------------------------------------------------------------------------------
// Disassembler: returns packed {str, ra, rb, rd, imm} (352 bits).
// All decoding variables are automatic function locals -> no extra signals.
//------------------------------------------------------------------------------
function automatic [352:0] disasm (
    input [31:0] ins,
    input [31:0] pc
);
    logic [31:0] inst;
    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;
    logic [4:0]  rs1, rs2, rd;
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    logic [79:0] o_str, o_ra, o_rb, o_rd;
    logic [31:0] o_imm;
    logic        unk;   // set when the encoding is not decoded (coverage flag)
begin
    inst   = ins;
    opcode = inst[6:0];
    funct3 = inst[14:12];
    funct7 = inst[31:25];
    rs1    = inst[19:15];
    rs2    = inst[24:20];
    rd     = inst[11:7];

    imm_i = {{20{inst[31]}}, inst[31:20]};
    imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    imm_u = {inst[31:12], 12'b0};
    imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:25], inst[24:21], 1'b0};

    o_str = "-";
    o_ra  = "-";
    o_rb  = "-";
    o_rd  = "-";
    o_imm = 32'b0;
    unk   = 1'b0;

    if (inst[1:0] == 2'b11) begin
        //----------------------------------------------------------------------
        // 32-bit encodings
        //----------------------------------------------------------------------
        case (opcode)
            7'b0110111 : begin // LUI
                o_str = "lui";
                o_rd  = get_regname_str(rd);
                o_imm = imm_u;
            end

            7'b0010111 : begin // AUIPC
                o_str = "auipc";
                o_rd  = get_regname_str(rd);
                o_imm = pc + imm_u;
            end

            7'b1101111 : begin // JAL
                o_str = "jal";
                o_rd  = get_regname_str(rd);
                o_imm = pc + imm_j;
                if (rd == 5'd1) o_str = "call";
            end

            7'b1100111 : begin // JALR
                o_str = "jalr";
                o_rd  = get_regname_str(rd);
                o_ra  = get_regname_str(rs1);
                o_imm = imm_i;
                if ((rs1 == 5'd1) && (imm_i == 32'b0))
                    o_str = "ret";
                else if (rd == 5'd1)
                    o_str = "call";
            end

            7'b1100011 : begin // BRANCH
                o_ra  = get_regname_str(rs1);
                o_rb  = get_regname_str(rs2);
                o_imm = pc + imm_b;
                case (funct3)
                    3'b000 : o_str = "beq";
                    3'b001 : o_str = "bne";
                    3'b100 : o_str = "blt";
                    3'b101 : o_str = "bge";
                    3'b110 : o_str = "bltu";
                    3'b111 : o_str = "bgeu";
                    default: begin o_str = "branch?"; unk = 1'b1; end
                endcase
            end

            7'b0000011 : begin // LOAD
                o_rd  = get_regname_str(rd);
                o_ra  = get_regname_str(rs1);
                o_imm = imm_i;
                case (funct3)
                    3'b000 : o_str = "lb";
                    3'b001 : o_str = "lh";
                    3'b010 : o_str = "lw";
                    3'b100 : o_str = "lbu";
                    3'b101 : o_str = "lhu";
                    default: begin o_str = "load?"; unk = 1'b1; end
                endcase
            end

            7'b0100011 : begin // STORE
                o_ra  = get_regname_str(rs1);
                o_rb  = get_regname_str(rs2);
                o_imm = imm_s;
                case (funct3)
                    3'b000 : o_str = "sb";
                    3'b001 : o_str = "sh";
                    3'b010 : o_str = "sw";
                    default: begin o_str = "store?"; unk = 1'b1; end
                endcase
            end

            7'b0010011 : begin // OP-IMM
                o_rd = get_regname_str(rd);
                o_ra = get_regname_str(rs1);
                case (funct3)
                    3'b000 : begin o_str = "addi";  o_imm = imm_i; end
                    3'b010 : begin o_str = "slti";  o_imm = imm_i; end
                    3'b011 : begin o_str = "sltiu"; o_imm = imm_i; end
                    3'b100 : begin o_str = "xori";  o_imm = imm_i; end
                    3'b110 : begin o_str = "ori";   o_imm = imm_i; end
                    3'b111 : begin o_str = "andi";  o_imm = imm_i; end
                    3'b001 : begin o_str = "slli";  o_imm = {27'b0, inst[24:20]}; end
                    3'b101 : begin
                        o_imm = {27'b0, inst[24:20]};
                        o_str = inst[30] ? "srai" : "srli";
                    end
                    default: begin o_str = "op-imm?"; unk = 1'b1; end
                endcase
            end

            7'b0110011 : begin // OP (+M)
                o_rd = get_regname_str(rd);
                o_ra = get_regname_str(rs1);
                o_rb = get_regname_str(rs2);
                if (funct7 == 7'b0000001) begin
                    case (funct3)
                        3'b000 : o_str = "mul";
                        3'b001 : o_str = "mulh";
                        3'b010 : o_str = "mulhsu";
                        3'b011 : o_str = "mulhu";
                        3'b100 : o_str = "div";
                        3'b101 : o_str = "divu";
                        3'b110 : o_str = "rem";
                        3'b111 : o_str = "remu";
                    endcase
                end
                else begin
                    case ({funct7[5], funct3})
                        4'b0_000 : o_str = "add";
                        4'b1_000 : o_str = "sub";
                        4'b0_001 : o_str = "sll";
                        4'b0_010 : o_str = "slt";
                        4'b0_011 : o_str = "sltu";
                        4'b0_100 : o_str = "xor";
                        4'b0_101 : o_str = "srl";
                        4'b1_101 : o_str = "sra";
                        4'b0_110 : o_str = "or";
                        4'b0_111 : o_str = "and";
                        default  : begin o_str = "op?"; unk = 1'b1; end
                    endcase
                end
            end

            7'b0001111 : begin // MISC-MEM
                o_imm = {20'b0, inst[31:25], inst[11:7]};
                o_str = funct3[0] ? "fence.i" : "fence";
            end

            7'b1110011 : begin // SYSTEM
                if (funct3 == 3'b000) begin
                    case (inst)
                        32'h00000073 : o_str = "ecall";
                        32'h00100073 : o_str = "ebreak";
                        32'h30200073 : o_str = "mret";
                        32'h10500073 : o_str = "wfi";
                        default      : begin o_str = "sys?"; unk = 1'b1; end
                    endcase
                end
                else begin
                    o_rd  = get_regname_str(rd);
                    o_ra  = get_regname_str(rs1);
                    o_imm = {20'b0, inst[31:20]}; // CSR address
                    case (funct3)
                        3'b001 : o_str = "csrrw";
                        3'b010 : o_str = "csrrs";
                        3'b011 : o_str = "csrrc";
                        3'b101 : o_str = "csrrwi";
                        3'b110 : o_str = "csrrsi";
                        3'b111 : o_str = "csrrci";
                        default: begin o_str = "csr?"; unk = 1'b1; end
                    endcase
                end
            end

            default : o_str = "illegal"; // unknown opcode: legitimately illegal
        endcase
    end
`ifdef SCR1_RVC_EXT
    else begin
        //----------------------------------------------------------------------
        // 16-bit compressed encodings (RV32C subset)
        //----------------------------------------------------------------------
        case (inst[1:0])
                2'b00 : begin // Quadrant 0
                    case (inst[15:13])
                    3'b000 : begin // c.addi4spn
                        o_str = "c.addi4spn";
                        o_rd  = get_regname_str_p(inst[4:2]);
                        o_imm = {22'b0, inst[10:7], inst[12:11], inst[5], inst[6], 2'b00};
                    end
                    3'b010 : begin // c.lw
                        o_str = "c.lw";
                        o_rd  = get_regname_str_p(inst[4:2]);
                        o_ra  = get_regname_str_p(inst[9:7]);
                        o_imm = {25'b0, inst[5], inst[12:10], inst[6], 2'b00};
                    end
                    3'b110 : begin // c.sw
                        o_str = "c.sw";
                        o_ra  = get_regname_str_p(inst[9:7]);
                        o_rb  = get_regname_str_p(inst[4:2]);
                        o_imm = {25'b0, inst[5], inst[12:10], inst[6], 2'b00};
                    end
                    default : begin o_str = "c.q0?"; unk = 1'b1; end
                endcase
            end

                2'b01 : begin // Quadrant 1
                    case (inst[15:13])
                    3'b000 : begin // c.nop / c.addi
                        o_str = (rd == 5'd0) ? "c.nop" : "c.addi";
                        o_rd  = get_regname_str(rd);
                        o_imm = {{27{inst[12]}}, inst[6:2]};
                    end
                    3'b001 : begin // c.jal (RV32)
                        o_str = "c.jal";
                        o_rd  = "ra";
                        o_imm = pc + {{20{inst[12]}}, inst[12], inst[8], inst[10:9], inst[6], inst[7], inst[2], inst[11], inst[5:3], 1'b0};
                    end
                    3'b010 : begin // c.li
                        o_str = "c.li";
                        o_rd  = get_regname_str(rd);
                        o_imm = {{27{inst[12]}}, inst[6:2]};
                    end
                    3'b011 : begin // c.addi16sp / c.lui
                        if (rd == 5'd2) begin
                            o_str = "c.addi16sp";
                            o_imm = {{22{inst[12]}}, inst[12], inst[4:3], inst[5], inst[2], inst[6], 4'b0};
                        end
                        else begin
                            o_str = "c.lui";
                            o_rd  = get_regname_str(rd);
                            o_imm = {{15{inst[12]}}, inst[6:2], 12'b0};
                        end
                    end
                    3'b100 : begin // MISC-ALU
                        o_rd = get_regname_str_p(inst[9:7]);
                        case (inst[11:10])
                            2'b00 : begin o_str = "c.srli"; o_imm = {27'b0, inst[6:2]}; end
                            2'b01 : begin o_str = "c.srai"; o_imm = {27'b0, inst[6:2]}; end
                            2'b10 : begin o_str = "c.andi"; o_imm = {{27{inst[12]}}, inst[6:2]}; end
                            2'b11 : begin
                                o_ra = get_regname_str_p(inst[9:7]);
                                o_rb = get_regname_str_p(inst[4:2]);
                                case ({inst[12], inst[6:5]})
                                    3'b000 : o_str = "c.sub";
                                    3'b001 : o_str = "c.xor";
                                    3'b010 : o_str = "c.or";
                                    3'b011 : o_str = "c.and";
                                    default: begin o_str = "c.alu?"; unk = 1'b1; end
                                endcase
                            end
                        endcase
                    end
                    3'b101 : begin // c.j
                        o_str = "c.j";
                        o_imm = pc + {{20{inst[12]}}, inst[12], inst[8], inst[10:9], inst[6], inst[7], inst[2], inst[11], inst[5:3], 1'b0};
                    end
                    3'b110 : begin // c.beqz
                        o_str = "c.beqz";
                        o_ra  = get_regname_str_p(inst[9:7]);
                        o_imm = pc + {{23{inst[12]}}, inst[12], inst[6:5], inst[2], inst[11:10], inst[4:3], 1'b0};
                    end
                    3'b111 : begin // c.bnez
                        o_str = "c.bnez";
                        o_ra  = get_regname_str_p(inst[9:7]);
                        o_imm = pc + {{23{inst[12]}}, inst[12], inst[6:5], inst[2], inst[11:10], inst[4:3], 1'b0};
                    end
                endcase
            end

                2'b10 : begin // Quadrant 2
                    case (inst[15:13])
                    3'b000 : begin // c.slli
                        o_str = "c.slli";
                        o_rd  = get_regname_str(rd);
                        o_imm = {27'b0, inst[6:2]};
                    end
                    3'b010 : begin // c.lwsp
                        o_str = "c.lwsp";
                        o_rd  = get_regname_str(rd);
                        o_imm = {24'b0, inst[3:2], inst[12], inst[6:4], 2'b00};
                    end
                    3'b100 : begin
                        if (inst[12] == 1'b0) begin
                            if (rs2 == 5'd0) begin
                                if (rd == 5'd0) begin
                                    o_str = "c.ebreak";
                                end
                                else begin
                                    o_str = "c.jr";
                                    o_ra  = get_regname_str(rd);
                                end
                            end
                            else begin
                                o_str = "c.mv";
                                o_rd  = get_regname_str(rd);
                                o_rb  = get_regname_str(rs2);
                            end
                        end
                        else begin
                            if (rs2 == 5'd0) begin
                                o_str = "c.jalr";
                                o_ra  = get_regname_str(rd);
                            end
                            else begin
                                o_str = "c.add";
                                o_rd  = get_regname_str(rd);
                                o_rb  = get_regname_str(rs2);
                            end
                        end
                    end
                    3'b110 : begin // c.swsp
                        o_str = "c.swsp";
                        o_rb  = get_regname_str(rs2);
                        o_imm = {24'b0, inst[8:7], inst[12:9], 2'b00};
                    end
                    default : begin o_str = "c.q2?"; unk = 1'b1; end
                endcase
            end

            default : begin o_str = "c?"; unk = 1'b1; end
        endcase
    end
`endif // SCR1_RVC_EXT

    disasm = {unk, o_str, o_ra, o_rb, o_rd, o_imm};
end
endfunction

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
