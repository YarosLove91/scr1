#ifndef DUT_ACCESS_H
#define DUT_ACCESS_H

//--------------------------------------------------------------------
// DUT access configuration for the AXI testbench.
// Included by the shared sources (sim/tb_cpp_common) to reach the
// verilated model type and its flattened internal signals.
//--------------------------------------------------------------------

#include "Vscr1_top_axi.h"
#include "Vscr1_top_axi___024root.h"

typedef Vscr1_top_axi dut_top_t;

// Internal signal of scr1_top_axi.i_core_top.i_pipe_top
// (requires verilation with --public-flat-rw)
#define SCR1_PIPE(top, name) \
    ((top)->rootp->scr1_top_axi__DOT__i_core_top__DOT__i_pipe_top__DOT__##name)

#endif
