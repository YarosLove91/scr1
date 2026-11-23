// ============================================================
// File    : scr1_cfg_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Compile-time configuration package (head of the dependency
// chain). Each knob has TWO channels: the default literal in the
// `else branch below, or a Makefile override
// (+define+SCR1_CFG_<NAME>=<value>, passed only for knobs
// explicitly set on the command line). DUT geometry comes from
// scr1_arch_description.svh; addresses follow the SCR1 tb
// convention (EXIT_PC = program termination marker, PRINT_ADDR =
// console MMIO, one char per store). Single source of the env
// types/constants: dv/uvm/README.md ("Типизация представления").
// ============================================================
`ifndef SCR1_CFG_PKG_SV
`define SCR1_CFG_PKG_SV

package scr1_cfg_pkg;

  // DUT geometry (mirror of the SCR1 RTL header constants for the
  // RV32 AHB configurations; env files take widths from here, the
  // harness tb/scr1_dut.sv keeps the actual header wiring)
  localparam int XLEN      = 32;  // SCR1_XLEN (RV32)
  localparam int AHB_WIDTH = 32;  // SCR1_AHB_WIDTH

  // Word and instruction-field types (single source of truth -
  // interfaces, tb package, RAL and the bound probes import them)
  typedef logic [XLEN-1:0] xlen_word_t;   // XLEN-wide word: PC, addresses,
                                          // GPR / bus data
  typedef logic [31:0]     raw_opcode_t;  // raw 32-bit instruction word
  typedef logic [6:0]      opcode_t;      // major opcode field (instr[6:0])
  typedef logic [6:0]      funct7_t;      // funct7 field (instr[31:25])
  typedef logic [2:0]      funct3_t;      // funct3 field (instr[14:12];
                                          // RVC funct3: instr[15:13])
  typedef logic [1:0]      rvc_quadrant_t;// RVC quadrant field (instr[1:0])
  typedef logic [4:0]      reg_idx_t;     // GPR index field (instr[11:7] rd,
                                          // instr[19:15] rs1, instr[24:20] rs2)
  typedef logic [3:0]      exc_code_t;    // mcause exception code ec[3:0]
                                          // (WARL; RTL type_scr1_exc_code_e)
  typedef logic [11:0]     csr_addr_t;    // 12-bit CSR address (instr[31:20])
  typedef logic [31:0]     csr_data_t;    // RV32 CSR data

  // Fixed DUT constants (SCR1 tb convention)
  localparam xlen_word_t EXIT_PC    = 32'h0000_00F8;
  localparam xlen_word_t PRINT_ADDR = 32'hF000_0000;
  localparam xlen_word_t RST_VECTOR = 32'h0000_0200;  // SCR1_ARCH_RST_VECTOR

  // simulation devices of the SCR1 tb convention (mirrored by the stage-B
  // memory agent); full 32-bit address equality, as in the legacy decode
  localparam xlen_word_t EXT_IRQ_ADDR  = 32'hF000_0100;  // SCR1_SIM_EXT_IRQ_ADDR
  localparam xlen_word_t SOFT_IRQ_ADDR = 32'hF000_0200;  // SCR1_SIM_SOFT_IRQ_ADDR
  localparam int unsigned IRQ_LINES_NUM = 16;             // SCR1_IRQ_LINES_NUM

  // agent-model image geometry (legacy tb array: 2**SCR1_MEM_POWER_SIZE = 1 MB)
  localparam int unsigned MEM_BYTES     = 1024 * 1024;
  localparam int unsigned MEM_ADDR_MASK = MEM_BYTES - 1;

  // Representation types (typedef sweep): vector widths derived
  // from the DUT-geometry localparams - no raw [N:0] at use sites

  // byte granularity of the memory model / AHB byte lanes
  localparam int unsigned MEM_BYTE_BITS = 8;
  typedef logic [MEM_BYTE_BITS-1:0]            mem_byte_t;

  // IRQ vectors from IRQ_LINES_NUM: line vector / live-line count / index
  typedef logic [IRQ_LINES_NUM-1:0]            irq_lines_t;
  localparam int unsigned IRQ_LINE_CNT_W = $clog2(IRQ_LINES_NUM + 1);
  localparam int unsigned IRQ_LINE_IDX_W = $clog2(IRQ_LINES_NUM);
  typedef logic [IRQ_LINE_CNT_W-1:0]           irq_line_cnt_t;
  typedef logic [IRQ_LINE_IDX_W-1:0]           irq_line_idx_t;

  // AHB domain from AHB_WIDTH: address/data words + protocol fields (widths
  // fixed by the AMBA spec), byte enables (one bit per lane), byte offset
  localparam int unsigned AHB_BYTES       = AHB_WIDTH / MEM_BYTE_BITS;
  localparam int unsigned AHB_BYTE_OFFS_W = $clog2(AHB_BYTES);
  typedef logic [AHB_WIDTH-1:0]                ahb_addr_t;
  typedef logic [AHB_WIDTH-1:0]                ahb_data_t;
  typedef logic [1:0]                          ahb_htrans_t;
  typedef logic [2:0]                          ahb_hsize_t;
  typedef logic [2:0]                          ahb_hburst_t;
  typedef logic [3:0]                          ahb_hprot_t;
  typedef logic [AHB_BYTES-1:0]                ahb_be_t;
  typedef logic [AHB_BYTE_OFFS_W-1:0]          ahb_byte_offs_t;
  // AHB channels of the memory agent (imem + dmem)
  localparam int unsigned AHB_CH_NUM = 2;
  // word-alignment mask (named replacement of {addr[31:2], 2'b00} slices)
  localparam ahb_addr_t AHB_WORD_MASK =
      ~(ahb_addr_t'(AHB_BYTES) - ahb_addr_t'(1));
  // byte-enable patterns of the scr1_be_form mirror table
  localparam ahb_be_t AHB_BE_NONE = '0;
  localparam ahb_be_t AHB_BE_BYTE = ahb_be_t'(1);
  localparam ahb_be_t AHB_BE_HALF =
      (ahb_be_t'(1) << (AHB_BYTES / 2)) - ahb_be_t'(1);
  localparam ahb_be_t AHB_BE_WORD = '1;

  // 64-bit body of the RV32 counters (mcycle/minstret {hi, lo} CSR pairs)
  typedef logic [2*XLEN-1:0]                   counter_word_t;

  // MTVEC: BASE is 64B-granular (bits [5:2]=0, bit1 ignored; mirrors
  // SCR1_CSR_MTVEC_BASE_ZERO_BITS of scr1_arch_types.svh)
  localparam int unsigned MTVEC_ALIGN_BYTES = 64;
  localparam int unsigned MTVEC_BASE_LSB    = $clog2(MTVEC_ALIGN_BYTES);
  localparam int unsigned MTVEC_MODE_BITS   = 2;  // arch MODE field width
  typedef logic [XLEN-MTVEC_BASE_LSB-1:0]      mtvec_base_t;

  // MMIO device windows are page-granular: region matches compare through
  // this mask instead of raw [31:12] slices
  localparam int unsigned MMIO_REGION_BYTES = 4096;
  localparam xlen_word_t  MMIO_REGION_MASK  =
      ~(xlen_word_t'(MMIO_REGION_BYTES) - xlen_word_t'(1));

  // instruction sizes: compressed halfword / standard word
  localparam int unsigned RVC_INSN_BYTES = 2;
  localparam int unsigned RVI_INSN_BYTES = 4;
  typedef logic [RVC_INSN_BYTES*MEM_BYTE_BITS-1:0] rvc_insn_t;
  localparam rvc_insn_t     RVC_C_EBREAK = 16'h9002;  // c.ebreak encoding
  localparam rvc_quadrant_t RVC_QUAD_32B = '1;        // quadrant 2'b11: 32-bit instr
  // trap-commit marker: instr field of trap records (probe + ref-model convention)
  localparam raw_opcode_t   TRAP_INSTR_MARKER = '1;

  // delay-window channel selector of the memory agent (scr1_mem_txn.delay_ch)
  typedef logic [1:0]                          mem_delay_ch_t;
  localparam mem_delay_ch_t DELAY_CH_DMEM = 2'd0;
  localparam mem_delay_ch_t DELAY_CH_IMEM = 2'd1;
  localparam mem_delay_ch_t DELAY_CH_BOTH = 2'd2;

  // mcounten (SCR1 custom): CY(bit0) | IR(bit2)
  localparam int unsigned MCOUNTEN_CY_BIT = 0;
  localparam int unsigned MCOUNTEN_IR_BIT = 2;
  localparam csr_data_t MCOUNTEN_MASK = (csr_data_t'(1) << MCOUNTEN_CY_BIT) |
                                        (csr_data_t'(1) << MCOUNTEN_IR_BIT);

  // AHB encodings (mirror of scr1_ahb.svh for env-side files; RTL
  // includes only in packages/harness)
  localparam ahb_htrans_t HTRANS_IDLE   = 2'b00;
  localparam ahb_htrans_t HTRANS_BUSY   = 2'b01;
  localparam ahb_htrans_t HTRANS_NONSEQ = 2'b10;
  localparam ahb_htrans_t HTRANS_SEQ    = 2'b11;
  localparam ahb_hsize_t  HSIZE_8B      = 3'b000;
  localparam ahb_hsize_t  HSIZE_16B     = 3'b001;
  localparam ahb_hsize_t  HSIZE_32B     = 3'b010;
  localparam logic        HRESP_OKAY    = 1'b0;
  localparam logic        HRESP_ERROR   = 1'b1;

  // ISA string for the in-process Spike (2B); matches the scr1-spike-verif flow
  localparam string SPIKE_ISA = "rv32imc_zicsr_zifencei";

  // MMIO regions for the diff filters: loads from these ranges are
  // timing/device dependent and skipped (stores stay compared)
  localparam xlen_word_t MMIO_SIM_BASE   = 32'hF000_0000;  // console/IRQ
  localparam xlen_word_t MMIO_TIMER_BASE = 32'h0049_0000;  // mtime/mtimecmp

  // CSR reset constants (mirror of scr1_csr.svh / arch values,
  // per build CFG) - used by the RAL model and its checks
`ifdef SCR1_CFG_RV32IMC_MAX
  localparam csr_data_t MISA_RST_VAL = 32'h4000_1104;  // MXL32|I|M|C
`else ifdef SCR1_CFG_RV32IC_BASE
  localparam csr_data_t MISA_RST_VAL = 32'h4000_0104;  // MXL32|I|C
`else ifdef SCR1_CFG_RV32EC_MIN
  localparam csr_data_t MISA_RST_VAL = 32'h4000_0014;  // MXL32|E|C
`else
  localparam csr_data_t MISA_RST_VAL = 32'h4000_1104;
`endif
  localparam csr_data_t MVENDORID_RST_VAL = 32'h0000_0000;  // SCR1_MVENDORID
  localparam csr_data_t MARCHID_RST_VAL   = 32'h0000_0008;  // SCR1_CSR_MARCHID
  localparam csr_data_t MIMPID_RST_VAL    = 32'h2201_1200;  // SCR1_MIMPID
  localparam csr_data_t MHARTID_RST_VAL   = 32'h0000_0000;  // fuse_mhartid tie
  localparam csr_data_t MTVEC_RST_VAL     = 32'h0000_01C0;  // default trap vec
  localparam csr_data_t MCOUNTEN_RST_VAL  = MCOUNTEN_MASK;  // CY|IR enabled
  // mstatus reset (mirror of SCR1_CSR_MSTATUS_*_RST_VAL): MPP=11|MPIE=1|MIE=0;
  // Spike resets MPIE=0 - the 2B golden state is calibrated to this value
  localparam csr_data_t MSTATUS_RST_VAL   = 32'h0000_1880;

  // CSR addresses (single source for the RAL map, scoreboard class
  // map / legalizers and the diff-scoreboard filter lists)
  localparam csr_addr_t CSR_MSTATUS   = 12'h300;
  localparam csr_addr_t CSR_MISA      = 12'h301;
  localparam csr_addr_t CSR_MIE       = 12'h304;
  localparam csr_addr_t CSR_MTVEC     = 12'h305;
  localparam csr_addr_t CSR_MSCRATCH  = 12'h340;
  localparam csr_addr_t CSR_MEPC      = 12'h341;
  localparam csr_addr_t CSR_MCAUSE    = 12'h342;
  localparam csr_addr_t CSR_MTVAL     = 12'h343;
  localparam csr_addr_t CSR_MIP       = 12'h344;
  localparam csr_addr_t CSR_MCOUNTEN  = 12'h7E0;  // SCR1 custom
  localparam csr_addr_t CSR_MCYCLE    = 12'hB00;
  localparam csr_addr_t CSR_MINSTRET  = 12'hB02;
  localparam csr_addr_t CSR_MCYCLEH   = 12'hB80;
  localparam csr_addr_t CSR_MINSTRETH = 12'hB82;
  localparam csr_addr_t CSR_MVENDORID = 12'hF11;
  localparam csr_addr_t CSR_MARCHID   = 12'hF12;
  localparam csr_addr_t CSR_MIMPID    = 12'hF13;
  localparam csr_addr_t CSR_MHARTID   = 12'hF14;
  // read-only unprivileged counter shadows (diff-scoreboard timing filter)
  localparam csr_addr_t CSR_CYCLE     = 12'hC00;
  localparam csr_addr_t CSR_TIME      = 12'hC01;
  localparam csr_addr_t CSR_INSTRET   = 12'hC02;
  localparam csr_addr_t CSR_CYCLEH    = 12'hC80;
  localparam csr_addr_t CSR_TIMEH     = 12'hC81;
  localparam csr_addr_t CSR_INSTRETH  = 12'hC82;

  // RVI base major opcodes / fields (single source for the tb_pkg decoders,
  // commit probe, cosim scoreboard and the fcov decode table)
  localparam opcode_t OPCODE_LOAD       = 7'h03;
  localparam opcode_t OPCODE_MISC_MEM = 7'h0F;
  localparam opcode_t OPCODE_OP_IMM     = 7'h13;
  localparam opcode_t OPCODE_AUIPC      = 7'h17;
  localparam opcode_t OPCODE_STORE      = 7'h23;
  localparam opcode_t OPCODE_OP         = 7'h33;
  localparam opcode_t OPCODE_LUI        = 7'h37;
  localparam opcode_t OPCODE_BRANCH     = 7'h63;
  localparam opcode_t OPCODE_JALR       = 7'h67;
  localparam opcode_t OPCODE_JAL        = 7'h6F;
  localparam opcode_t OPCODE_SYSTEM     = 7'h73;
  localparam funct7_t FUNCT7_MULDIV     = 7'h01;  // M extension funct7
  localparam funct3_t FUNCT3_FENCE_I    = 3'h1;   // fence.i (FENCE funct3)
  // funct12 (instr[31:20], csr_addr_t field) of the SYSTEM encodings
  localparam csr_addr_t FUNCT12_ECALL   = 12'h000;
  localparam csr_addr_t FUNCT12_EBREAK  = 12'h001;
  localparam csr_addr_t FUNCT12_MRET    = 12'h302;
  localparam csr_addr_t FUNCT12_WFI     = 12'h105;
  // CSR-instruction funct3 (immediate forms = register forms with bit2 set)
  localparam funct3_t FUNCT3_CSRRW  = 3'h1;
  localparam funct3_t FUNCT3_CSRRS  = 3'h2;
  localparam funct3_t FUNCT3_CSRRC  = 3'h3;
  localparam funct3_t FUNCT3_CSRRWI = 3'h5;
  localparam funct3_t FUNCT3_CSRRSI = 3'h6;
  localparam funct3_t FUNCT3_CSRRCI = 3'h7;

  // MRET full-word encoding (the CSR scoreboard re-syncs mstatus on it -
  // mret bypasses the exu2csr_w_req bus)
  localparam raw_opcode_t OPCODE_MRET = {FUNCT12_MRET, 13'b0, OPCODE_SYSTEM};

  // Encodings mirrored for the include-free probe files
  // (scr1_bind.sv, scr1_state_probe.sv): MEPC_PAD - mepc alignment
  // padding (RVC: bit0 hardwired, else [1:0]; from the MISA C flag)
  // and MEM_CMD_WR (type_scr1_mem_cmd_e write encoding)
  localparam int   RVC_EN     = int'(MISA_RST_VAL[2]);
  localparam int   MEPC_PAD   = RVC_EN ? 1 : 2;
  localparam logic MEM_CMD_WR = 1'b1;  // SCR1_MEM_CMD_WR

  // CSR bit/mask constants - the SCR1 WARL truth (scr1_pipe_csr.sv)
  // and the cross-model compare scope; single source for the CSR
  // and diff scoreboards (no magic numbers at the use sites)
  // mstatus (M-only core: MPP hardwired 2'b11); masks derived from the
  // arch bit positions (legalizers / trap-MRET resync / RAL field map)
  localparam int unsigned MSTATUS_MIE_BIT  = 3;   // arch position of MIE
  localparam int unsigned MSTATUS_MPIE_BIT = 7;   // arch position of MPIE
  localparam int unsigned MSTATUS_MPP_LSB  = 11;  // MPP field bits [12:11]
  // MIE<->MPIE shift of the trap/MRET resync (MPIE<=MIE / MIE<=MPIE)
  localparam int unsigned MSTATUS_IE_SHIFT = MSTATUS_MPIE_BIT - MSTATUS_MIE_BIT;
  localparam csr_data_t MSTATUS_MIE  = csr_data_t'(1) << MSTATUS_MIE_BIT;
  localparam csr_data_t MSTATUS_MPIE = csr_data_t'(1) << MSTATUS_MPIE_BIT;
  localparam csr_data_t MSTATUS_MPP  = csr_data_t'(2'b11) << MSTATUS_MPP_LSB;
  // mstatus writable bits (MIE|MPIE) + compare scope (writable + MPP; the
  // Spike S/U-mode bits SCR1 lacks are excluded)
  localparam csr_data_t MSTATUS_WR_MASK  = MSTATUS_MIE | MSTATUS_MPIE;
  localparam csr_data_t MSTATUS_CMP_MASK = MSTATUS_WR_MASK | MSTATUS_MPP;
  // mie: MSIE(3)|MTIE(7)|MEIE(11) - writable bits = compare scope
  localparam int unsigned MIE_MSIE_BIT = 3;   // machine software
  localparam int unsigned MIE_MTIE_BIT = 7;   // machine timer
  localparam int unsigned MIE_MEIE_BIT = 11;  // machine external
  localparam csr_data_t MIE_MASK = (csr_data_t'(1) << MIE_MSIE_BIT) |
                                   (csr_data_t'(1) << MIE_MTIE_BIT) |
                                   (csr_data_t'(1) << MIE_MEIE_BIT);
  // mcause: stored {i(bit31), 25'b0, ec[3:0]} - ec is the 4-bit
  // type_scr1_exc_code_e, a legal WARL truncation of bits [5:4] (found by
  // the CSR-fuzz injection, seed 1519025353); masks derived from XLEN/$bits
  localparam csr_data_t MCAUSE_IRQ_BIT = csr_data_t'(1) << (XLEN - 1);
  localparam csr_data_t MCAUSE_EC_MASK =
      (csr_data_t'(1) << $bits(exc_code_t)) - csr_data_t'(1);
  localparam csr_data_t MCAUSE_MASK    = MCAUSE_IRQ_BIT | MCAUSE_EC_MASK;
  // mcause word of the machine external IRQ ({irq, ec=11}); fcov cross-check
  localparam int unsigned IRQ_EC_M_EXT     = 11;  // arch ec code
  localparam csr_data_t   MCAUSE_M_EXT_IRQ = MCAUSE_IRQ_BIT | csr_data_t'(IRQ_EC_M_EXT);
  // mepc: low MEPC_PAD alignment bits hardwired 0 in BOTH models
  localparam csr_data_t MEPC_MASK =
      ~((csr_data_t'(1) << MEPC_PAD) - csr_data_t'(1));
  // mtvec compare scope: BASE[31:6] + MODE bit0 (SCR1 BASE 64B-granular vs
  // Spike 4B, MODE 1 bit - bits [5:1] excluded)
  localparam csr_data_t MTVEC_LOW_BITS =
      (csr_data_t'(1) << MTVEC_BASE_LSB) - csr_data_t'(1);
  localparam csr_data_t MTVEC_CMP_MASK = ~(MTVEC_LOW_BITS & ~csr_data_t'(1));
  // full compare (mscratch: complete RW on both sides)
  localparam csr_data_t CSR_MASK_FULL = '1;

  // IPIC presence + the ext IRQ line the UVM IRQ agent drives
  // (matches sim/tests/irq_ext): IPIC builds route line 9, non-IPIC
  // use the common line 0. Mirrors SCR1_IPIC_EN (not visible to the
  // include-free env, re-derived here)
`ifdef SCR1_CFG_RV32EC_MIN
  localparam int IPIC_EN      = 0;
`else
  localparam int IPIC_EN      = 1;
`endif
  localparam int EXT_IRQ_LINE = IPIC_EN ? 9 : 0;

  // CSR snapshot (harness XMR -> interface -> monitor):
  // aggregated pipe_csr values sampled at the run exit
  typedef struct packed {
    csr_data_t mstatus;
    csr_data_t misa;
    csr_data_t mie;
    csr_data_t mtvec;
    csr_data_t mscratch;
    csr_data_t mepc;
    csr_data_t mcause;
    csr_data_t mtval;
    csr_data_t mip;
    csr_data_t mcounten;
    csr_data_t mcycle;
    csr_data_t mcycleh;
    csr_data_t minstret;
    csr_data_t minstreth;
    csr_data_t mhartid;
    csr_data_t mvendorid;
    csr_data_t marchid;
    csr_data_t mimpid;
  } scr1_csr_snap_s;

  // Numeric knobs
`ifdef SCR1_CFG_RST_CYCLES
  localparam int unsigned RST_CYCLES = `SCR1_CFG_RST_CYCLES;
`else
  localparam int unsigned RST_CYCLES = 4;  // reset low duration, clocks
`endif

`ifdef SCR1_CFG_TIMEOUT_CYCLES
  localparam int unsigned TIMEOUT_CYCLES = `SCR1_CFG_TIMEOUT_CYCLES;
`else
  localparam int unsigned TIMEOUT_CYCLES = 2_000_000;  // per-run watchdog
`endif

`ifdef SCR1_CFG_NUM_RUNS
  localparam int unsigned NUM_RUNS = `SCR1_CFG_NUM_RUNS;
`else
  localparam int unsigned NUM_RUNS = 1;  // program runs in the smoke test
`endif

`ifdef SCR1_CFG_SCB_MAX_LOG
  localparam int unsigned SCB_MAX_LOG = `SCR1_CFG_SCB_MAX_LOG;
`else
  localparam int unsigned SCB_MAX_LOG = 20;  // detailed mismatch log cap
`endif

  // rtc_clk half period, ns (harness-generated). Default 5 = the NATIVE flow
  // equivalent: the legacy flow builds without --timing, the tb's "#500" is
  // dropped and rtc_clk toggles every eval - mtime grows ~+1 per clk
  // (isr_sample timer IRQ at ~297). 500 = "real" 1 MHz rtc (~100x cycles).
`ifdef SCR1_CFG_RTC_HALF_PERIOD
  localparam int unsigned RTC_HALF_PERIOD = `SCR1_CFG_RTC_HALF_PERIOD;
`else
  localparam int unsigned RTC_HALF_PERIOD = 5;
`endif

  // core clock half period, ns (100 MHz clk in scr1_tb_top / scr1_if)
  localparam int unsigned CLK_HALF_PERIOD_NS = 5;
  // post-run pipeline drain before the objection drop, ns (run-end txn path)
  localparam int unsigned DRAIN_TIME_NS = 200;

  // legacy memory tb (MEM_AGENT=0) constants mirrored by the harness:
  // all-ones stall pattern = never insert wait states; imem read latency
  localparam xlen_word_t  STALL_PATTERN_NONE = '1;
  localparam int unsigned IMEM_FETCH_DELAY   = 2;

  // default test vector (relative to dv/uvm; +SCR1_TEST_HEX=<path> overrides)
`ifdef SCR1_CFG_DEFAULT_TEST_HEX
  localparam string DEFAULT_TEST_HEX = `SCR1_CFG_DEFAULT_TEST_HEX;
`else
  localparam string DEFAULT_TEST_HEX = "sw/build/hello.hex";
`endif

  // Stage A loader path transport (runtime state, NOT a knob): an SV
  // string cannot be selected through a virtual interface ("virtual
  // interface trigger on 'string'"), so the driver publishes the full
  // path (no length limit) in this global and the harness consumes it
  // on the load_req/load_done handshake, right before $readmemh.
  string g_load_path = "";

endpackage : scr1_cfg_pkg

`endif // SCR1_CFG_PKG_SV
