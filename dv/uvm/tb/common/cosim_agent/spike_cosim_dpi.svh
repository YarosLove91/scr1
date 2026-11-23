// ============================================================
// File    : spike_cosim_dpi.svh
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// DPI-C boundary of the in-process Spike reference (pattern 2B),
// co-located with spike_cosim_dpi.cc (ibex pattern); included at
// scr1_cosim_agent_pkg scope under SCR1_SPIKE_COSIM.
// ============================================================
`ifndef SCR1_SPIKE_COSIM_DPI_SVH
`define SCR1_SPIKE_COSIM_DPI_SVH

import "DPI-C" function int scr1_spike_init(string hex_path, string isa,
                                            int unsigned start_pc,
                                            int unsigned mtvec_reset,
                                            int unsigned mstatus_reset);
import "DPI-C" function int scr1_spike_step(output int pc, output int instr,
                                            output int wr, output int rd,
                                            output int rd_data, output int trap,
                                            output int mcause, output int mepc,
                                            output int csr_w_valid,
                                            output int csr_w_addr,
                                            output int csr_w_value);
import "DPI-C" function int scr1_spike_get_csr(int addr, output int val);
import "DPI-C" function void scr1_spike_fini();

`endif // SCR1_SPIKE_COSIM_DPI_SVH
