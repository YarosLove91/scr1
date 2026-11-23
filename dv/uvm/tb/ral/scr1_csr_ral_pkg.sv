// ============================================================
// File    : scr1_csr_ral_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// CSR RAL package (milestone 3): uvm_reg model of the SCR1 M-mode
// CSR subset (rv_csr_uvm_ral_unloader style, RV32; map per
// src/includes/scr1_csr.svh): Sm 300/301/304/305/340..344/7E0/
// F11..F14 + counters B00/B02/B80/B82.
// Access model (RAL-1 + M7): LIVE frontdoor-style predict -
// scr1_csr_scoreboard decodes every retiring CSR access, computes
// the golden value (RISC-V csrrw/s/c semantics + SCR1 WARL
// legalizers) and predicts it into the mirror; the exit snapshot
// is then COMPARED against the live-built mirror. Trap/mret
// hardware updates bypass the instruction stream - the mirror
// re-syncs from trap commit records. A bus-style adapter is not
// applicable (a core's "front door" is its instruction stream).
// Details: dv/uvm/README.md (milestones 3, 7).
// ============================================================
`ifndef SCR1_CSR_RAL_PKG_SV
`define SCR1_CSR_RAL_PKG_SV

package scr1_csr_ral_pkg;

  import uvm_pkg::*;
  import scr1_cfg_pkg::*;

  `include "uvm_macros.svh"

  // RAL types (RV32 data width); csr_addr_t / csr_data_t come from
  // scr1_cfg_pkg (single source)
  typedef csr_data_t   csr_shadow_t [csr_addr_t];

  typedef enum bit {
    CSR_WRITE = 1'b0,
    CSR_READ  = 1'b1
  } csr_access_e;

  `include "scr1_csr_regs.svh"
  `include "scr1_csr_blocks.svh"

endpackage : scr1_csr_ral_pkg

`endif // SCR1_CSR_RAL_PKG_SV
