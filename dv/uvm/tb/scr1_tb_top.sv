// ============================================================
// File    : scr1_tb_top.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Testbench top: clock generation, interface + DUT harness
// instantiation, virtual interface handover via uvm_config_db,
// run_test(). No `include (env rule: includes only through
// packages) - RTL headers live in tb/scr1_dut.sv, widths come
// from scr1_cfg_pkg. DUT: scr1_dut = scr1_top_ahb (CFG=MAX by
// default) + memory model; the harness owns rtc_clk, the AHB
// stall patterns and the observation taps.
// ============================================================
`timescale 1ns/1ps

module scr1_tb_top;

  import uvm_pkg::*;
  import scr1_cfg_pkg::*;
  import scr1_tb_pkg::*;
  import scr1_test_pkg::*;

  // Clock
  logic clk = 1'b0;

  always #(CLK_HALF_PERIOD_NS) clk = ~clk;  // 100 MHz

  // Interface
  scr1_if vif (.clk(clk));

  // Commit observation bus (RVFI-lite, from the bound scr1_commit_probe via
  // the harness): shared by the cosim and CSR agent monitors.
  scr1_commit_if commit_vif (.clk(clk));

`ifdef SCR1_MEM_AGENT
  // Stage B (MEM_AGENT=1): the reactive memory agent's interface. Core AHB
  // buses come from the harness ports, slave responses and device IRQ lines
  // are driven by the agent; rst_n mirrors the main interface reset.
  scr1_ahb_mem_if mem_vif (.clk(clk));
  assign mem_vif.rst_n = vif.rst_n_req;

  // IRQ agent interface (ibex irq_if pattern): agent stimulus lines OR the
  // memory agent's device-register mirror into the core pins (single-driver
  // rule: the mirror is continuously assigned here, the stimulus lines belong
  // to the IRQ agent driver).
  scr1_irq_if irq_vif (.clk(clk), .rst_n(vif.rst_n_req));
  // typed narrowing of the 32-bit device word to the IRQ line vector
  assign irq_vif.dev_ext_lines = irq_lines_t'(mem_vif.irq_lines);
  assign irq_vif.dev_soft_irq = mem_vif.soft_irq;
`endif // SCR1_MEM_AGENT

  // functional coverage is bound into the DUT top (tb/scr1_bind.sv) - no wiring here

  // DUT harness
  scr1_dut i_dut (
    .clk            (clk                ),
    .rst_n          (vif.rst_n_req      ),
    // stage A vector loader handshake (path travels via g_load_path)
    .load_req       (vif.load_req       ),
    .load_done      (vif.load_done      ),
    // memory backdoor (32-bit LE words)
    .peek_req       (vif.peek_req       ),
    .peek_addr      (vif.peek_addr      ),
    .peek_done      (vif.peek_done      ),
    .peek_data      (vif.peek_data      ),
    .poke_req       (vif.poke_req       ),
    .poke_addr      (vif.poke_addr      ),
    .poke_data      (vif.poke_data      ),
    // observation taps (UVM monitor)
    .curr_pc        (vif.curr_pc        ),
    .instret        (vif.instret        ),
    .a0             (vif.a0             ),
    .dmem_haddr     (vif.dmem_haddr     ),
    .dmem_hwrite    (vif.dmem_hwrite    ),
    .dmem_hwdata    (vif.dmem_hwdata    ),
    .dmem_hready    (vif.dmem_hready    ),
    .dmem_htrans    (vif.dmem_htrans    ),
    // commit bus (RVFI-lite, milestone 2; dedicated scr1_commit_if)
    .commit_valid          (commit_vif.commit_valid          ),
    .commit_trap           (commit_vif.commit_trap           ),
    .commit_mcause         (commit_vif.commit_mcause         ),
    .commit_trap_val       (commit_vif.commit_trap_val       ),
    .commit_pc             (commit_vif.commit_pc             ),
    .commit_instr          (commit_vif.commit_instr          ),
    .commit_rd_wr          (commit_vif.commit_rd_wr          ),
    .commit_rd_addr        (commit_vif.commit_rd_addr        ),
    .commit_rd_data        (commit_vif.commit_rd_data        ),
    .commit_mem_we         (commit_vif.commit_mem_we         ),
    .commit_mem_addr_valid (commit_vif.commit_mem_addr_valid ),
    .commit_mem_addr       (commit_vif.commit_mem_addr       ),
    .commit_mem_wdata      (commit_vif.commit_mem_wdata      ),
    // CSR sideband of each commit (milestone 7, live RAL predict)
    .commit_csr_r_req   (commit_vif.commit_csr_r_req   ),
    .commit_csr_w_req   (commit_vif.commit_csr_w_req   ),
    .commit_csr_addr    (commit_vif.commit_csr_addr    ),
    .commit_csr_r_data  (commit_vif.commit_csr_r_data  ),
    .commit_csr_w_data  (commit_vif.commit_csr_w_data  ),
    .commit_csr_rs1     (commit_vif.commit_csr_rs1     ),
    // CSR snapshot (RAL)
    .csr_snap           (vif.csr_snap           )
`ifdef SCR1_MEM_AGENT
    ,
    // stage B: the AHB buses to/from the reactive memory agent
    .imem_htrans_o      (mem_vif.imem_htrans    ),
    .imem_haddr_o       (mem_vif.imem_haddr     ),
    .imem_hsize_o       (mem_vif.imem_hsize     ),
    .imem_hready_i      (mem_vif.imem_hready    ),
    .imem_hrdata_i      (mem_vif.imem_hrdata    ),
    .imem_hresp_i       (mem_vif.imem_hresp     ),
    .dmem_htrans_o      (mem_vif.dmem_htrans    ),
    .dmem_haddr_o       (mem_vif.dmem_haddr     ),
    .dmem_hwrite_o      (mem_vif.dmem_hwrite    ),
    .dmem_hwdata_o      (mem_vif.dmem_hwdata    ),
    .dmem_hsize_o       (mem_vif.dmem_hsize     ),
    .dmem_hready_i      (mem_vif.dmem_hready    ),
    .dmem_hrdata_i      (mem_vif.dmem_hrdata    ),
    .dmem_hresp_i       (mem_vif.dmem_hresp     ),
    // core IRQ pins: OR of the IRQ agent stimulus and the mem agent's device
    // mirror (merged in scr1_irq_if); the cast zero-extends to the port width
    .sim_irq_lines      (ahb_data_t'(irq_vif.core_ext_lines)),
    .sim_soft_irq       (irq_vif.core_soft_irq  )
`endif // SCR1_MEM_AGENT
  );

  // UVM start
  initial begin
`ifdef VM_TRACE
    $dumpfile("logs/waves.vcd");
    $dumpvars(0, scr1_tb_top);
`endif
    uvm_config_db#(scr1_vif)::set(null, "*", "vif", vif);
    uvm_config_db#(scr1_commit_vif)::set(null, "*", "commit_vif", commit_vif);
`ifdef SCR1_MEM_AGENT
    uvm_config_db#(scr1_mem_vif)::set(null, "*", "mem_vif", mem_vif);
    uvm_config_db#(scr1_irq_vif)::set(null, "*", "irq_vif", irq_vif);
`endif // SCR1_MEM_AGENT
    run_test("scr1_smoke_test");
  end

endmodule : scr1_tb_top
