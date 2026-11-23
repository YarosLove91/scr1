// ============================================================
// File    : scr1_bind.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Probe binding (ibex core_ibex_fcov_bind.sv pattern): the
// observation modules are bound into the DUT top instead of long
// XMR chains in the harness; scr1_dut.sv only re-exports the
// bound outputs. Bind target = scr1_top_ahb (NOT scr1_pipe_top):
// the fcov stall bins are defined on the AHB bus level and the
// AHB ports are only visible at the top - the lowest scope seeing
// both buses and the core hierarchy (ibex analogue: ibex_core).
// Env-side file: no RTL-header includes (env policy); the tap
// encodings (HTRANS_IDLE, MEM_CMD_WR, MEPC_PAD) are mirrored in
// scr1_cfg_pkg. Details: dv/uvm/README.md (bind section).
// ============================================================
`timescale 1ns/1ps

module scr1_bind;

  // Commit probe (RVFI-lite): taps follow the proven scr1_trace_logger
  // instantiation in scr1_pipe_top.sv
  bind scr1_top_ahb scr1_commit_probe #(
    .MEPC_PAD               (scr1_cfg_pkg::MEPC_PAD)
  ) i_commit_probe (
    .clk                    (clk                    ),
    .rst_n                  (rst_n                  ),
    // IDU issue stream
    .issue_vd_i             (i_core_top.i_pipe_top.ifu2idu_vd &
                             i_core_top.i_pipe_top.idu2ifu_rdy),
    .issue_instr_i          (i_core_top.i_pipe_top.ifu2idu_instr),
    .redirect_i             (i_core_top.i_pipe_top.new_pc_req),
    .redirect_pc_i          (i_core_top.i_pipe_top.new_pc     ),
    // EXU retire
    .retire_i               (i_core_top.i_pipe_top.instret    ),
    .retire_pc_i            (i_core_top.i_pipe_top.curr_pc    ),
    .rd_wr_i                (i_core_top.i_pipe_top.exu2mprf_w_req   ),
    .rd_addr_i              (i_core_top.i_pipe_top.exu2mprf_rd_addr ),
    .rd_data_i              (i_core_top.i_pipe_top.exu2mprf_rd_data ),
    // CSR trap events
    .exc_i                  (i_core_top.i_pipe_top.i_pipe_csr.e_exc),
    .irq_i                  (i_core_top.i_pipe_top.i_pipe_csr.e_irq),
    .mepc_next_i            (i_core_top.i_pipe_top.i_pipe_csr.csr_mepc_next),
    .mcause_ec_i            (i_core_top.i_pipe_top.i_pipe_csr.csr_mcause_ec_next),
    .mcause_irq_i           (i_core_top.i_pipe_top.i_pipe_csr.csr_mcause_i_next ),
    .trap_val_i             (i_core_top.i_pipe_top.exu2csr_trap_val),
    // CSR sideband (M7 live RAL predict): the EXU drives the pipe_csr
    // request bus in the same cycle it asserts instret
    .csr_r_req_i            (i_core_top.i_pipe_top.exu2csr_r_req     ),
    .csr_w_req_i            (i_core_top.i_pipe_top.exu2csr_w_req     ),
    .csr_addr_i             (i_core_top.i_pipe_top.exu2csr_rw_addr   ),
    .csr_r_data_i           (i_core_top.i_pipe_top.csr2exu_r_data    ),
    .csr_w_data_i           (i_core_top.i_pipe_top.exu2csr_w_data    ),
    .csr_rs1_i              (i_core_top.i_pipe_top.mprf2exu_rs1_data ),
    // DMEM requests (LSU)
    .dmem_req_i             (i_core_top.i_pipe_top.pipe2dmem_req_o  ),
    .dmem_wr_i              (i_core_top.i_pipe_top.pipe2dmem_cmd_o == scr1_cfg_pkg::MEM_CMD_WR),
    .dmem_addr_i            (i_core_top.i_pipe_top.pipe2dmem_addr_o ),
    .dmem_wdata_i           (i_core_top.i_pipe_top.pipe2dmem_wdata_o),
    // live AHB stalls (bus level, the DUT top ports)
    .imem_stall_i           ((imem_htrans != scr1_cfg_pkg::HTRANS_IDLE) && !imem_hready),
    .dmem_stall_i           ((dmem_htrans != scr1_cfg_pkg::HTRANS_IDLE) && !dmem_hready)
  );

  // Functional coverage (ibex fcov_if pattern): self-contained RTL-side
  // sampling fed by the bound commit probe + live bus/pipeline taps;
  // coverage.dat is written at $finish (no UVM-side wiring).
  bind scr1_top_ahb scr1_fcov_if i_fcov (
    .clk                (clk                               ),
    .rst_n              (rst_n                             ),
    .commit_valid       (i_commit_probe.commit_valid_o     ),
    .commit_trap        (i_commit_probe.commit_trap_o      ),
    .commit_mcause      (i_commit_probe.commit_mcause_o    ),
    .commit_instr       (i_commit_probe.commit_instr_o     ),
    .commit_rd_wr       (i_commit_probe.commit_rd_wr_o     ),
    .commit_rd_addr     (i_commit_probe.commit_rd_addr_o   ),
    .commit_stall_imem  (i_commit_probe.commit_stall_imem_o),
    .commit_stall_dmem  (i_commit_probe.commit_stall_dmem_o),
    .commit_trap_instr  (i_commit_probe.commit_trap_instr_o),
    .imem_stall         ((imem_htrans != scr1_cfg_pkg::HTRANS_IDLE) && !imem_hready),
    .dmem_stall         ((dmem_htrans != scr1_cfg_pkg::HTRANS_IDLE) && !dmem_hready),
    .redirect           (i_core_top.i_pipe_top.new_pc_req  ),
    // live external IRQ lines (scr1_top_ahb input - the same lines the IPIC sees)
    .irq_lines          (irq_lines                         )
  );

  // CSR snapshot (RAL) + legacy observation taps (curr_pc/instret/a0)
  bind scr1_top_ahb scr1_state_probe #(
    .MEPC_PAD               (scr1_cfg_pkg::MEPC_PAD)
  ) i_state_probe (
    // observation taps
    .curr_pc_i            (i_core_top.i_pipe_top.curr_pc),
    .instret_i            (i_core_top.i_pipe_top.instret),
    .a0_i                 (i_core_top.i_pipe_top.i_pipe_mprf.mprf_int[10]),
    // pipe_csr taps (the same names the proven STATE_DUMP reads)
    .mstatus_i            (i_core_top.i_pipe_top.i_pipe_csr.csr_mstatus),
    .mie_i                (i_core_top.i_pipe_top.i_pipe_csr.csr_mie),
    .mtvec_base_i         (i_core_top.i_pipe_top.i_pipe_csr.csr_mtvec_base),
    .mtvec_mode_i         (i_core_top.i_pipe_top.i_pipe_csr.csr_mtvec_mode),
    .mscratch_i           (i_core_top.i_pipe_top.i_pipe_csr.csr_mscratch_ff),
    .mepc_i               (i_core_top.i_pipe_top.i_pipe_csr.csr_mepc_ff),
    .mcause_irq_i         (i_core_top.i_pipe_top.i_pipe_csr.csr_mcause_i_ff),
    .mcause_ec_i          (i_core_top.i_pipe_top.i_pipe_csr.csr_mcause_ec_ff),
    .mtval_i              (i_core_top.i_pipe_top.i_pipe_csr.csr_mtval_ff),
    .mip_i                (i_core_top.i_pipe_top.i_pipe_csr.csr_mip),
    .mcounten_i           (i_core_top.i_pipe_top.i_pipe_csr.csr_mcounten),
    .mcycle_i             (i_core_top.i_pipe_top.i_pipe_csr.csr_mcycle),
    .minstret_i           (i_core_top.i_pipe_top.i_pipe_csr.csr_minstret),
    .mhartid_i            (i_core_top.i_pipe_top.i_pipe_csr.soc2csr_fuse_mhartid_i)
  );

endmodule : scr1_bind
