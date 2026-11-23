// ============================================================
// File    : scr1_test_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Test package: base test and the test library. Dependency
// chain: scr1_env_pkg -> scr1_test_pkg (imported by
// scr1_tb_top).
// ============================================================
`ifndef SCR1_TEST_PKG_SV
`define SCR1_TEST_PKG_SV

package scr1_test_pkg;

    import uvm_pkg::*;
    import scr1_cfg_pkg::*;
    import scr1_mem_model_pkg::*;
    import scr1_tb_pkg::*;
    import scr1_csr_ral_pkg::*;
    import scr1_seq_pkg::*;
    import scr1_agent_pkg::*;
    import scr1_env_pkg::*;

    `include "uvm_macros.svh"

    // the base test must be included first
    `include "scr1_base_test.sv"
    `include "scr1_start_reset.sv"
    `include "scr1_smoke_test.sv"
    `include "scr1_csr_test.sv"
    `include "scr1_irq_test.sv"
    `include "scr1_seq_inject_test.sv"
    `include "scr1_seq_delay_test.sv"

endpackage : scr1_test_pkg

`endif // SCR1_TEST_PKG_SV
