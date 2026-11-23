// ============================================================
// File    : scr1_irq_cfg_pkg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ stimulus configuration parameters (scr1_irq_run_vseq /
// scr1_irq_test): sequence defaults - each overridable at runtime
// through its +IRQ_* plusarg - and the random-scenario bounds.
// Single home of the IRQ stimulus tuning; pure constants, no
// package dependencies. Details: dv/uvm/README.md (milestone 6).
// ============================================================
`ifndef SCR1_IRQ_CFG_PKG_SV
`define SCR1_IRQ_CFG_PKG_SV

package scr1_irq_cfg_pkg;

  // Single-pulse stimulus defaults (cycles); +IRQ_EXT_DELAY /
  // +IRQ_EXT_WIDTH / +IRQ_SOFT_DELAY / +IRQ_SOFT_WIDTH override.
  // ext_delay lets the program install its handler + enable MEIE+MIE.
  localparam int unsigned IRQ_EXT_DELAY_DFLT  = 200;
  localparam int unsigned IRQ_EXT_WIDTH_DFLT  = 100;
  localparam int unsigned IRQ_SOFT_DELAY_DFLT = 100;
  localparam int unsigned IRQ_SOFT_WIDTH_DFLT = 40;

  // Random multi-pulse scenario defaults; +IRQ_RANDOM / +IRQ_SEED /
  // +IRQ_MASK_MODE / +IRQ_SOFT_GUAR override. IRQ_RANDOM_DFLT == 0
  // keeps the single ext + soft path bit-exact (irq_ext); >0 = random.
  localparam int unsigned IRQ_RANDOM_DFLT = 0;    // 0 = legacy path
  localparam int unsigned IRQ_SEED_DFLT   = 1;
  localparam string       IRQ_MASK_MODE_DFLT = "fixed9";  // fixed9|random16|all16
  // Guaranteed-service concurrent soft pulse (random mode). MEI > MSI: a
  // SHORT soft pulse overlapping the ext storm legitimately expires
  // unserviced (the soft trap defers until the ext queue drains, ~15
  // cycles/trap). soft_guar widens the forced concurrent pulse to span the
  // EXPECTED first ext-quiescent window (deterministic drain model, pure
  // arithmetic), so MSI is still pending after the ext drain -> >=1 soft
  // trap guaranteed per run; the pulse still STARTS inside ext[0]'s window.
  // The level-sensitive line then yields a bounded soft re-trap series (the
  // handler's device clear cannot drop the OR-merged injection) - far below
  // the watchdog. +IRQ_SOFT_GUAR=0 restores the narrow concurrent pulse.
  localparam bit          IRQ_SOFT_GUAR_DFLT = 1'b1;
  // concurrent_start bookkeeping default (recomputed by the schedule builder)
  localparam int unsigned IRQ_CONCURRENT_START_DFLT = 0;

  // Random scenario bounds (cycles). Widths are capped so the
  // level-sensitive soft line cannot spin an unbounded re-trap storm;
  // gaps keep the ext pulses non-overlapping.
  localparam int unsigned RAND_SETUP_DELAY = 400;  // program enables all srcs
  localparam int unsigned EXT_GAP_MIN      = 20;
  localparam int unsigned EXT_GAP_MAX      = 120;
  localparam int unsigned EXT_W_MIN        = 5;
  localparam int unsigned EXT_W_MAX        = 40;
  localparam int unsigned SOFT_GAP_MIN     = 30;
  localparam int unsigned SOFT_GAP_MAX     = 150;
  localparam int unsigned SOFT_W_MIN       = 5;
  localparam int unsigned SOFT_W_MAX       = 40;
  localparam int unsigned SOFT_MIN_PULSES  = 2;    // >=2 software pulses
  localparam int unsigned SOFT_EXTRA_MAX   = 2;    // + 0..2 extra

  // Guaranteed-service drain model (see IRQ_SOFT_GUAR_DFLT): each
  // injected line costs ~SOFT_GUAR_PER_LINE cycles (IPIC SOI/EOI +
  // trap overhead, ~15 measured + 60%); MARGIN covers latency/slack.
  localparam int unsigned SOFT_GUAR_PER_LINE = 24;
  localparam int unsigned SOFT_GUAR_MARGIN   = 100;

endpackage : scr1_irq_cfg_pkg

`endif // SCR1_IRQ_CFG_PKG_SV
