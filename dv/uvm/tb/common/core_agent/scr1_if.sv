// ============================================================
// File    : scr1_if.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Core agent interface (DUT: scr1_dut harness; lives with the
// core agent, ibex layout). The commit observation bus is the
// shared tb/common/scr1_commit_if.sv. No `include: the geometry
// comes from scr1_cfg_pkg (import).
// Stimuli: rst_n_req (active LOW); load_req/done vector-load
// handshake - the driver passes the path via scr1_cfg_pkg::
// g_load_path (a string cannot cross the vif boundary in the host
// simulator), the harness $readmemh's while rst_n is LOW;
// peek/poke 32-bit LE memory backdoor.
// Observation: curr_pc (exit marker 0xF8), instret/a0 (the SCR1 tb
// pass/fail convention), dmem_* console MMIO bus.
// Two posedge clocking blocks: drv_cb (stimuli out + run-status
// in), mon_cb (everything input #1step, race-free).
// ============================================================
interface scr1_if (
  input logic clk
);

  import scr1_cfg_pkg::*;

  // ---- stimuli (driver -> harness -> DUT) ----
  logic                    rst_n_req;

  // ---- vector load handshake: path travels via scr1_cfg_pkg::g_load_path
  // (no length limit; a string cannot cross the vif boundary), the harness
  // zeroes the array and $readmemh's the vector while the reset is low ----
  logic                    load_req;
  logic                    load_done;

  // ---- memory backdoor (LE 32-bit words; handshake on posedge clk) ----
  logic                    peek_req;
  xlen_word_t              peek_addr;
  logic                    peek_done;
  xlen_word_t              peek_data;
  logic                    poke_req;
  xlen_word_t              poke_addr;
  xlen_word_t              poke_data;

  // ---- core observation ----
  xlen_word_t              curr_pc;
  logic                    instret;
  xlen_word_t              a0;

  // ---- data AHB bus observation (console MMIO) ----
  ahb_addr_t               dmem_haddr;
  logic                    dmem_hwrite;
  ahb_data_t               dmem_hwdata;
  logic                    dmem_hready;
  ahb_htrans_t             dmem_htrans;

  // ---- CSR snapshot bus (run-end state for scr1_transaction, consumed by
  // the core monitor; per-commit CSR sideband lives on scr1_commit_if) ----
  scr1_csr_snap_s          csr_snap;

  initial begin
    rst_n_req = 1'b0;
    load_req  = 1'b0;
    peek_req  = 1'b0;
    peek_addr = '0;
    poke_req  = 1'b0;
    poke_addr = '0;
    poke_data = '0;
  end

  // ---- driver clocking block: stimuli out + run status in ----
  clocking drv_cb @(posedge clk);
    default input #1step output #0;
    output rst_n_req,
           load_req,
           peek_req,
           peek_addr,
           poke_req,
           poke_addr,
           poke_data;
    input  load_done,
           peek_done,
           peek_data,
           curr_pc;
  endclocking : drv_cb

  // ---- monitor clocking block: everything sampled race-free ----
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n_req,
          curr_pc,
          instret,
          a0,
          dmem_haddr,
          dmem_hwrite,
          dmem_hwdata,
          dmem_hready,
          dmem_htrans,
          csr_snap;
  endclocking : mon_cb

  // ---- modports ----
  modport drv_mp (clocking drv_cb, input clk);
  modport mon_mp (clocking mon_cb, input clk);

endinterface : scr1_if
