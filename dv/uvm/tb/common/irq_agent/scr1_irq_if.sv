// ============================================================
// File    : scr1_irq_if.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Interrupt interface of the SCR1 IRQ agent (donor: ibex irq_if -
// stimulus lines + driver_cb/monitor_cb + wait_clks). TWO legal
// sources OR into the core pins: the agent stimulus (ext_lines/
// soft_irq; ONLY driver = IRQ driver via driver_cb) and the
// device-register mirror (dev_*: scr1_mem_model registers the
// PROGRAM writes over AHB at EXT_IRQ_ADDR/SOFT_IRQ_ADDR; ONLY
// driver = mem agent, assigned in scr1_tb_top). The OR is a
// continuous assign - exactly one procedural driver per signal
// (MULTIDRIVEN rule, DESIGN_VS_IBEX.md §7). The harness absorbs
// the IPIC geometry (non-IPIC builds take bit 0). Clocking:
// scr1_ahb_mem_if house style (driver out #0, monitor #1step).
// NB: NO initial block - every variable has exactly one source.
// ============================================================
interface scr1_irq_if (
  input logic clk,
  input logic rst_n
);

  import scr1_cfg_pkg::*;

  // ---- agent stimulus lines (scr1_irq_driver through driver_cb) ----
  irq_lines_t ext_lines;   // external IPIC lines
  logic       soft_irq;    // software IRQ line

  // ---- device-register mirror (assigned in scr1_tb_top; program-driven) ----
  irq_lines_t dev_ext_lines;
  logic       dev_soft_irq;

  // ---- the pins the core actually sees (single-driver OR) ----
  wire irq_lines_t core_ext_lines;
  wire logic       core_soft_irq;

  assign core_ext_lines = ext_lines | dev_ext_lines;
  assign core_soft_irq  = soft_irq  | dev_soft_irq;

  // ---- driver clocking block: stimulus out, reset in ----
  clocking driver_cb @(posedge clk);
    default input #1step output #0;
    input  rst_n;
    output ext_lines;
    output soft_irq;
  endclocking : driver_cb

  // ---- monitor clocking block: everything sampled race-free ----
  clocking monitor_cb @(posedge clk);
    default input #1step;
    input rst_n;
    input ext_lines;
    input soft_irq;
    input dev_ext_lines;
    input dev_soft_irq;
    input core_ext_lines;
    input core_soft_irq;
  endclocking : monitor_cb

  // ---- modports ----
  modport driver_mp (clocking driver_cb, input clk);
  modport monitor_mp (clocking monitor_cb, input clk);

  // ---- cycle wait helper (ibex irq_if pattern) ----
  task automatic wait_clks(int num);
    repeat (num) @(posedge clk);
  endtask : wait_clks

endinterface : scr1_irq_if
