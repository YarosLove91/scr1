// ============================================================
// File    : scr1_commit_if.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Commit observation interface (RVFI-lite): the retire channel of
// the bound scr1_commit_probe, exported through the scr1_dut
// harness and wired here in scr1_tb_top. Shared by TWO checker
// agents (ibex rvfi_if analogue), hence the neutral tb/common/
// root: scr1_cosim_monitor samples EVERY retire, scr1_csr_monitor
// the CSR-relevant subset. Both get it as "commit_vif" via
// config_db and only READ it through mon_cb (#1step, race-free;
// the single driver is the harness port connection). Signal
// semantics: scr1_commit_probe.
// ============================================================
interface scr1_commit_if (
  input logic clk
);

  import scr1_cfg_pkg::*;

  // ---- commit bus (RVFI-lite, from scr1_commit_probe) ----
  logic                    commit_valid;
  logic                    commit_trap;
  csr_data_t               commit_mcause;
  xlen_word_t              commit_trap_val;
  xlen_word_t              commit_pc;
  raw_opcode_t             commit_instr;
  logic                    commit_rd_wr;
  reg_idx_t                commit_rd_addr;
  xlen_word_t              commit_rd_data;
  logic                    commit_mem_we;
  logic                    commit_mem_addr_valid;
  xlen_word_t              commit_mem_addr;
  xlen_word_t              commit_mem_wdata;
  // CSR sideband of each commit (milestone 7, live RAL predict)
  logic                    commit_csr_r_req;
  logic                    commit_csr_w_req;
  csr_addr_t               commit_csr_addr;
  csr_data_t               commit_csr_r_data;
  csr_data_t               commit_csr_w_data;
  csr_data_t               commit_csr_rs1;

  // ---- monitor clocking block: everything sampled race-free ----
  clocking mon_cb @(posedge clk);
    default input #1step;
    input commit_valid,
          commit_trap,
          commit_mcause,
          commit_trap_val,
          commit_pc,
          commit_instr,
          commit_rd_wr,
          commit_rd_addr,
          commit_rd_data,
          commit_mem_we,
          commit_mem_addr_valid,
          commit_mem_addr,
          commit_mem_wdata,
          commit_csr_r_req,
          commit_csr_w_req,
          commit_csr_addr,
          commit_csr_r_data,
          commit_csr_w_data,
          commit_csr_rs1;
  endclocking : mon_cb

  modport mon_mp (clocking mon_cb, input clk);

endinterface : scr1_commit_if
