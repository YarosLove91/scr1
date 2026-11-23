// ============================================================
// File    : scr1_dut.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// DUT harness: scr1_top_ahb + the native scr1_memory_tb_ahb
// memory/IRQ/console model (the legacy pair minus the batch test
// runner - run control belongs to the UVM driver). NO DUT copies:
// the RTL is referenced through the `dut -> ../../src` symlink;
// on a port-list change this harness is the single compile
// failure point to resync.
// The ONLY env file that includes the SCR1 RTL headers: it
// absorbs the file-local config macros/parameters and presents
// clean fixed-width ports; all UVM-side files are include-free
// (geometry from scr1_cfg_pkg).
// Glue: stage-A loader (ZEROES the array + $readmemh's
// scr1_cfg_pkg::g_load_path - a string cannot cross the vif
// boundary - while rst_n is LOW); peek/poke backdoor (the only
// allowed XMR: i_memory_tb.memory); commit/fcov/CSR probes BOUND
// via tb/scr1_bind.sv (ibex core_ibex_fcov_bind pattern) and
// re-exported here; rtc_clk + AHB stall patterns (+imem_pattern/
// +dmem_pattern, default FFFFFFFF = no delay) generated locally.
// ============================================================
`timescale 1ns/1ps

`include "scr1_arch_description.svh"
`include "scr1_ahb.svh"
`include "scr1_memif.svh"
`include "scr1_csr.svh"
`ifdef SCR1_IPIC_EN
`include "scr1_ipic.svh"
`endif

module scr1_dut (
    input  logic        clk,
    input  logic        rst_n,

    // ---- vector load handshake (path arrives via scr1_cfg_pkg::g_load_path;
    //      the memory tb test_file_init legacy path is NOT used) ----
    input  logic        load_req,
    output logic        load_done,

    // ---- memory backdoor (32-bit LE words over the memory tb array) ----
    input  logic        peek_req,
    input  xlen_word_t  peek_addr,
    output logic        peek_done,
    output xlen_word_t  peek_data,
    input  logic        poke_req,
    input  xlen_word_t  poke_addr,
    input  xlen_word_t  poke_data,

    // ---- observation taps (to the UVM monitor) ----
    output xlen_word_t  curr_pc,
    output logic        instret,
    output xlen_word_t  a0,
    output ahb_addr_t   dmem_haddr,
    output logic        dmem_hwrite,
    output ahb_data_t   dmem_hwdata,
    output logic        dmem_hready,
    output ahb_htrans_t dmem_htrans,

    // ---- commit bus (RVFI-lite, milestone 2) ----
    output logic        commit_valid,
    output logic        commit_trap,
    output csr_data_t   commit_mcause,
    output xlen_word_t  commit_trap_val,
    output xlen_word_t  commit_pc,
    output raw_opcode_t commit_instr,
    output logic        commit_rd_wr,
    output reg_idx_t    commit_rd_addr,
    output xlen_word_t  commit_rd_data,
    output logic        commit_mem_we,
    output logic        commit_mem_addr_valid,
    output xlen_word_t  commit_mem_addr,
    output xlen_word_t  commit_mem_wdata,

    // ---- CSR sideband of each commit (milestone 7, live RAL predict) ----
    output logic        commit_csr_r_req,
    output logic        commit_csr_w_req,
    output csr_addr_t   commit_csr_addr,
    output csr_data_t   commit_csr_r_data,
    output csr_data_t   commit_csr_w_data,
    output csr_data_t   commit_csr_rs1,

    // ---- CSR snapshot (RAL, milestone 3) ----
    output scr1_csr_snap_s csr_snap
`ifdef SCR1_MEM_AGENT
    ,
    // ---- stage B (MEM_AGENT=1): the AHB buses leave the harness for the
    //      reactive memory agent; the legacy scr1_memory_tb_ahb is NOT
    //      instantiated. Fixed-width ports (IPIC slicing absorbed inside) ----
    output ahb_htrans_t imem_htrans_o,
    output ahb_addr_t   imem_haddr_o,
    output ahb_hsize_t  imem_hsize_o,
    input  logic        imem_hready_i,
    input  ahb_data_t   imem_hrdata_i,
    input  logic        imem_hresp_i,
    output ahb_htrans_t dmem_htrans_o,
    output ahb_addr_t   dmem_haddr_o,
    output logic        dmem_hwrite_o,
    output ahb_data_t   dmem_hwdata_o,
    output ahb_hsize_t  dmem_hsize_o,
    input  logic        dmem_hready_i,
    input  ahb_data_t   dmem_hrdata_i,
    input  logic        dmem_hresp_i,
    // ---- simulation devices driven by the memory agent ----
    input  ahb_data_t   sim_irq_lines,
    input  logic        sim_soft_irq
`endif // SCR1_MEM_AGENT
);

  import scr1_cfg_pkg::*;
`ifdef SCR1_MEM_AGENT
  // stage B: the load/peek/poke handshakes reach the agent's model through
  // the package global (class-handle transport, the g_load_path precedent)
  import scr1_mem_model_pkg::*;
  import scr1_tb_pkg::*;
`endif // SCR1_MEM_AGENT

  // memory image size: scr1_cfg_pkg::MEM_BYTES (single source)

  // Local clocks / patterns
  // rtc_clk rate: RTC_HALF_PERIOD=5 (default) reproduces the native sim flow
  // (no --timing: mtime grows ~+1 per clk); 500 = the real 1 MHz rtc
  logic rtc_clk = 1'b0;
  always #(RTC_HALF_PERIOD) rtc_clk = ~rtc_clk;

  integer imem_req_ack_stall;
  integer dmem_req_ack_stall;

  initial begin
    if (!$value$plusargs("imem_pattern=%h", imem_req_ack_stall))
      imem_req_ack_stall = STALL_PATTERN_NONE;  // no delay
    if (!$value$plusargs("dmem_pattern=%h", dmem_req_ack_stall))
      dmem_req_ack_stall = STALL_PATTERN_NONE;  // no delay
  end

  // DUT-side signals
`ifdef SCR1_IPIC_EN
  logic [SCR1_IRQ_LINES_NUM-1:0]  irq_lines;  // RTL geometry (absorbed here)
`else // SCR1_IPIC_EN
  logic                           ext_irq;
`endif // SCR1_IPIC_EN
  logic                           soft_irq;
  xlen_word_t                     fuse_mhartid = '0;

`ifdef SCR1_DBG_EN
  logic                           trst_n = 1'b0;
  logic                           tck    = 1'b0;
  logic                           tms    = 1'b0;
  logic                           tdi    = 1'b0;
  logic                           tdo;
  logic                           tdo_en;
`endif // SCR1_DBG_EN

  // Instruction Memory Interface (widths: cfg_pkg mirrors of the RTL fields)
  ahb_hprot_t                     imem_hprot;
  ahb_hburst_t                    imem_hburst;
  ahb_hsize_t                     imem_hsize;
  ahb_htrans_t                    imem_htrans_i;
  ahb_addr_t                      imem_haddr;
  logic                           imem_hready;
  ahb_data_t                      imem_hrdata;
  logic                           imem_hresp;

  // Data Memory Interface
  ahb_hprot_t                     dmem_hprot;
  ahb_hburst_t                    dmem_hburst;
  ahb_hsize_t                     dmem_hsize;
  ahb_htrans_t                    dmem_htrans_i;
  ahb_addr_t                      dmem_haddr_i;
  logic                           dmem_hwrite_i;
  ahb_data_t                      dmem_hwdata_i;
`ifndef SCR1_MEM_AGENT
  // agent mode: dmem_hready_i is the harness input port; legacy: internal net
  logic                           dmem_hready_i;
`endif // SCR1_MEM_AGENT
  ahb_data_t                      dmem_hrdata;
  logic                           dmem_hresp;

  // Vector loader (UVM driver handshake -> memory array). On load_req: zero
  // the WHOLE array first ($readmemh overwrites only present addresses -
  // stale bytes would survive), then $readmemh the string path, pulse
  // load_done one clock; load_busy guards re-entry while load_req is high.
  logic load_busy = 1'b0;

`ifdef SCR1_MEM_AGENT
  // Stage B: the vector goes into the agent's model (g_mem_model, published
  // in its build_phase); load_verilog_hex clears the image and parses with
  // $readmemh semantics. Stage-A handshake protocol unchanged.
  always @(posedge clk) begin
    load_done <= 1'b0;
    if (load_req && !load_busy) begin
      load_busy <= 1'b1;
      if (g_mem_model == null) begin
        $fatal(1, "scr1_dut: scr1_tb_pkg::g_mem_model is NULL - the memory agent did not publish it (build_phase order?)");
      end
      g_mem_model.load_verilog_hex(g_load_path);
      load_done <= 1'b1;
    end else if (!load_req) begin
      load_busy <= 1'b0;
    end
  end
`else // SCR1_MEM_AGENT
  always @(posedge clk) begin
    load_done <= 1'b0;
    if (load_req && !load_busy) begin
      load_busy <= 1'b1;
      for (int unsigned i = 0; i < MEM_BYTES; i++) begin
        i_memory_tb.memory[i] = '0;
      end
      $readmemh(g_load_path, i_memory_tb.memory);
      load_done <= 1'b1;
    end else if (!load_req) begin
      load_busy <= 1'b0;
    end
  end
`endif // SCR1_MEM_AGENT

  // Memory backdoor (32-bit LE words): peek pulses done with the assembled
  // word, poke writes four bytes in the same clock. Blocking writes: NBA into
  // a cross-module array is not accepted here.
`ifdef SCR1_MEM_AGENT
  // Stage B backdoor: peek/poke are model methods (32-bit LE words)
  always @(posedge clk) begin
    peek_done <= 1'b0;
    if (peek_req) begin
      peek_data <= g_mem_model.peek32(peek_addr);
      peek_done <= 1'b1;
    end
    if (poke_req) begin
      g_mem_model.poke32(poke_addr, poke_data);
    end
  end
`else // SCR1_MEM_AGENT
  always @(posedge clk) begin
    peek_done <= 1'b0;
    if (peek_req) begin
      peek_data <= { i_memory_tb.memory[peek_addr + 3],
                     i_memory_tb.memory[peek_addr + 2],
                     i_memory_tb.memory[peek_addr + 1],
                     i_memory_tb.memory[peek_addr + 0] };
      peek_done <= 1'b1;
    end
    if (poke_req) begin
      i_memory_tb.memory[poke_addr + 0] = poke_data[7:0];
      i_memory_tb.memory[poke_addr + 1] = poke_data[15:8];
      i_memory_tb.memory[poke_addr + 2] = poke_data[23:16];
      i_memory_tb.memory[poke_addr + 3] = poke_data[31:24];
    end
  end
`endif // SCR1_MEM_AGENT

  // Observation re-exports: all probes are BOUND into the DUT top
  // (tb/scr1_bind.sv) - no XMR chains into the core hierarchy here. The fcov
  // interface is self-contained inside the DUT (coverage.dat at $finish).
  assign curr_pc = i_top.i_state_probe.curr_pc_o;
  assign instret = i_top.i_state_probe.instret_o;
  // a0 (x10) of the MPRF - the pass/fail convention of the legacy tb
  assign a0      = i_top.i_state_probe.a0_o;

  assign dmem_haddr  = dmem_haddr_i;
  assign dmem_hwrite = dmem_hwrite_i;
  assign dmem_hwdata = dmem_hwdata_i;
  assign dmem_hready = dmem_hready_i;
  assign dmem_htrans = dmem_htrans_i;

  // Commit bus (RVFI-lite, milestone 2) - the bound probe outputs
  assign commit_valid          = i_top.i_commit_probe.commit_valid_o;
  assign commit_trap           = i_top.i_commit_probe.commit_trap_o;
  assign commit_mcause         = i_top.i_commit_probe.commit_mcause_o;
  assign commit_trap_val       = i_top.i_commit_probe.commit_trap_val_o;
  assign commit_pc             = i_top.i_commit_probe.commit_pc_o;
  assign commit_instr          = i_top.i_commit_probe.commit_instr_o;
  assign commit_rd_wr          = i_top.i_commit_probe.commit_rd_wr_o;
  assign commit_rd_addr        = i_top.i_commit_probe.commit_rd_addr_o;
  assign commit_rd_data        = i_top.i_commit_probe.commit_rd_data_o;
  assign commit_mem_we         = i_top.i_commit_probe.commit_mem_we_o;
  assign commit_mem_addr_valid = i_top.i_commit_probe.commit_mem_addr_o_valid;
  assign commit_mem_addr       = i_top.i_commit_probe.commit_mem_addr_o;
  assign commit_mem_wdata      = i_top.i_commit_probe.commit_mem_wdata_o;

  // CSR sideband (milestone 7): per-commit CSR read/write event
  assign commit_csr_r_req  = i_top.i_commit_probe.commit_csr_r_req_o;
  assign commit_csr_w_req  = i_top.i_commit_probe.commit_csr_w_req_o;
  assign commit_csr_addr   = i_top.i_commit_probe.commit_csr_addr_o;
  assign commit_csr_r_data = i_top.i_commit_probe.commit_csr_r_data_o;
  assign commit_csr_w_data = i_top.i_commit_probe.commit_csr_w_data_o;
  assign commit_csr_rs1    = i_top.i_commit_probe.commit_csr_rs1_o;

  // CSR snapshot (RAL, milestone 3) - assembled in the bound state probe
  assign csr_snap = i_top.i_state_probe.snap_o;

  // Core instance
  scr1_top_ahb i_top (
    // Reset
    .pwrup_rst_n            (rst_n                  ),
    .rst_n                  (rst_n                  ),
    .cpu_rst_n              (rst_n                  ),
`ifdef SCR1_DBG_EN
    .sys_rst_n_o            (                       ),
    .sys_rdc_qlfy_o         (                       ),
`endif // SCR1_DBG_EN

    // Clock
    .clk                    (clk                    ),
    .rtc_clk                (rtc_clk                ),

    // Fuses
    .fuse_mhartid           (fuse_mhartid           ),
`ifdef SCR1_DBG_EN
    .fuse_idcode            (`SCR1_TAP_IDCODE       ),
`endif // SCR1_DBG_EN

    // IRQ
`ifdef SCR1_IPIC_EN
    .irq_lines              (irq_lines              ),
`else // SCR1_IPIC_EN
    .ext_irq                (ext_irq                ),
`endif // SCR1_IPIC_EN
    .soft_irq               (soft_irq               ),

    // DFT
    .test_mode              (1'b0                   ),
    .test_rst_n             (1'b1                   ),

`ifdef SCR1_DBG_EN
    // JTAG
    .trst_n                 (trst_n                 ),
    .tck                    (tck                    ),
    .tms                    (tms                    ),
    .tdi                    (tdi                    ),
    .tdo                    (tdo                    ),
    .tdo_en                 (tdo_en                 ),
`endif // SCR1_DBG_EN

    // Instruction Memory Interface
    .imem_hprot             (imem_hprot             ),
    .imem_hburst            (imem_hburst            ),
    .imem_hsize             (imem_hsize             ),
    .imem_htrans            (imem_htrans_i          ),
    .imem_hmastlock         (                       ),
    .imem_haddr             (imem_haddr             ),
    .imem_hready            (imem_hready            ),
    .imem_hrdata            (imem_hrdata            ),
    .imem_hresp             (imem_hresp             ),

    // Data Memory Interface
    .dmem_hprot             (dmem_hprot             ),
    .dmem_hburst            (dmem_hburst            ),
    .dmem_hsize             (dmem_hsize             ),
    .dmem_htrans            (dmem_htrans_i          ),
    .dmem_hmastlock         (                       ),
    .dmem_haddr             (dmem_haddr_i           ),
    .dmem_hwrite            (dmem_hwrite_i          ),
    .dmem_hwdata            (dmem_hwdata_i          ),
    .dmem_hready            (dmem_hready_i          ),
    .dmem_hrdata            (dmem_hrdata            ),
    .dmem_hresp             (dmem_hresp             )
  );

  // Memory: stage B (MEM_AGENT=1) - the legacy memory tb is NOT instantiated;
  // the AHB buses leave the harness to scr1_ahb_mem_if (the reactive agent
  // drives responses and device IRQ lines back). Without the define - the
  // native scr1_memory_tb_ahb instance, unchanged.
`ifdef SCR1_MEM_AGENT
  // core -> agent (bus outputs)
  assign imem_htrans_o = imem_htrans_i;
  assign imem_haddr_o  = imem_haddr;
  assign imem_hsize_o  = imem_hsize;
  assign dmem_htrans_o = dmem_htrans_i;
  assign dmem_haddr_o  = dmem_haddr_i;
  assign dmem_hwrite_o = dmem_hwrite_i;
  assign dmem_hwdata_o = dmem_hwdata_i;
  assign dmem_hsize_o  = dmem_hsize;
  // agent -> core (responses)
  assign imem_hready   = imem_hready_i;
  assign imem_hrdata   = imem_hrdata_i;
  assign imem_hresp    = imem_hresp_i;
  // dmem_hready_i IS the harness port in agent mode (legacy net `ifdef'ed out)
  assign dmem_hrdata   = dmem_hrdata_i;
  assign dmem_hresp    = dmem_hresp_i;
  // agent -> core (simulation devices; harness absorbs the IPIC geometry)
`ifdef SCR1_IPIC_EN
  assign irq_lines     = sim_irq_lines[SCR1_IRQ_LINES_NUM-1:0];
`else // SCR1_IPIC_EN
  assign ext_irq       = sim_irq_lines[0];
`endif // SCR1_IPIC_EN
  assign soft_irq      = sim_soft_irq;
`else // SCR1_MEM_AGENT
  scr1_memory_tb_ahb #(
    .SCR1_MEM_POWER_SIZE    ($clog2(MEM_BYTES))
  ) i_memory_tb (
    // Control
    .rst_n                  (rst_n                  ),
    .clk                    (clk                    ),
`ifdef SCR1_IPIC_EN
    .irq_lines              (irq_lines              ),
`else // SCR1_IPIC_EN
    .ext_irq                (ext_irq                ),
`endif // SCR1_IPIC_EN
    .soft_irq               (soft_irq               ),
    .imem_req_ack_stall_in  (imem_req_ack_stall     ),
    .dmem_req_ack_stall_in  (dmem_req_ack_stall     ),

    // Instruction Memory Interface
    .imem_hsize             (imem_hsize             ),
    .imem_htrans            (imem_htrans_i          ),
    .imem_haddr             (imem_haddr             ),
    .imem_hready            (imem_hready            ),
    .imem_hrdata            (imem_hrdata            ),
    .imem_hresp             (imem_hresp             ),

    // Data Memory Interface
    .dmem_hsize             (dmem_hsize             ),
    .dmem_htrans            (dmem_htrans_i          ),
    .dmem_haddr             (dmem_haddr_i           ),
    .dmem_hwrite            (dmem_hwrite_i          ),
    .dmem_hwdata            (dmem_hwdata_i          ),
    .dmem_hready            (dmem_hready_i          ),
    .dmem_hrdata            (dmem_hrdata            ),
    .dmem_hresp             (dmem_hresp             )
  );
`endif // SCR1_MEM_AGENT

endmodule : scr1_dut
