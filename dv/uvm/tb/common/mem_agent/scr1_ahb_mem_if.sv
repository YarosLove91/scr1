// ============================================================
// File    : scr1_ahb_mem_if.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// AHB interface of the reactive memory agent (stage B,
// MEM_AGENT=1; donor: ibex_mem_intf). Two independent slave
// channels (imem/dmem) plus the simulation-device IRQ register
// mirror (PROGRAM-driven source; scr1_tb_top feeds it into
// scr1_irq_if, OR-ed with the IRQ agent stimulus). Directions are
// agent-centric; hready is a memory OUTPUT (no hready input from
// the core on this bus). Delays/injection (+AGENT_*) live in the
// driver - the interface carries only the signals the legacy
// scr1_memory_tb_ahb consumed. Clocking: scr1_if style (drv_cb
// inputs #1step / outputs #0, mon_cb all #1step); rst_n assigned
// from scr1_if.rst_n_req in scr1_tb_top.
// ============================================================
interface scr1_ahb_mem_if (
  input logic clk
);

  import scr1_cfg_pkg::*;

  // reset (assigned in scr1_tb_top from vif.rst_n_req)
  logic rst_n;

  // ---- IMEM channel (core -> agent) ----
  ahb_htrans_t          imem_htrans;
  ahb_addr_t            imem_haddr;
  ahb_hsize_t           imem_hsize;
  // ---- IMEM channel (agent -> core) ----
  logic                 imem_hready;
  ahb_data_t            imem_hrdata;
  logic                 imem_hresp;

  // ---- DMEM channel (core -> agent) ----
  ahb_htrans_t          dmem_htrans;
  ahb_addr_t            dmem_haddr;
  logic                 dmem_hwrite;
  ahb_data_t            dmem_hwdata;
  ahb_hsize_t           dmem_hsize;
  // ---- DMEM channel (agent -> core) ----
  logic                 dmem_hready;
  ahb_data_t            dmem_hrdata;
  logic                 dmem_hresp;

  // ---- device IRQ register mirror (OR-ed with agent stimulus in scr1_irq_if) ----
  ahb_data_t            irq_lines;   // device word; scr1_tb_top narrows to irq_lines_t
  logic                 soft_irq;

  // NB: NO initial block - every signal has exactly one driver (the agent
  // driver via drv_cb, rst_n via the assign from scr1_tb_top). An initial
  // write competes with the clocking drive (MULTIDRIVEN merge) and the
  // driven values stop reaching the DUT.

  // ---- driver clocking block: bus in, slave responses out ----
  clocking drv_cb @(posedge clk);
    default input #1step output #0;
    input  rst_n,
           imem_htrans,
           imem_haddr,
           imem_hsize,
           dmem_htrans,
           dmem_haddr,
           dmem_hwrite,
           dmem_hwdata,
           dmem_hsize;
    output imem_hready,
           imem_hrdata,
           imem_hresp,
           dmem_hready,
           dmem_hrdata,
           dmem_hresp,
           irq_lines,
           soft_irq;
  endclocking : drv_cb

  // ---- monitor clocking block: everything sampled race-free ----
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n,
          imem_htrans,
          imem_haddr,
          imem_hsize,
          imem_hready,
          imem_hrdata,
          imem_hresp,
          dmem_htrans,
          dmem_haddr,
          dmem_hwrite,
          dmem_hwdata,
          dmem_hsize,
          dmem_hready,
          dmem_hrdata,
          dmem_hresp,
          irq_lines,
          soft_irq;
  endclocking : mon_cb

  // ---- modports ----
  modport drv_mp (clocking drv_cb, input clk);
  modport mon_mp (clocking mon_cb, input clk);

endinterface : scr1_ahb_mem_if
