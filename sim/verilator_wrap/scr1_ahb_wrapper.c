
#include <stdio.h>
#include <verilated.h>
#include "Vscr1_top_tb_ahb.h"
#include "Vscr1_top_tb_ahb__Syms.h"
#ifdef VCD_TRACE
#include "verilated_vcd_c.h"
#endif // #ifdef VCD_TRACE

#define STRINGIFY(s) _STRINGIFY(s)
#define _STRINGIFY(s) #s

#define SCR1_STATE_TOP      scr1_top_tb_ahb
#define SCR1_STATE_MODEL    Vscr1_top_tb_ahb
#include "scr1_state_dump.h"

Vscr1_top_tb_ahb *top;

vluint64_t main_time = 0;

int main(int argc, char** argv) {
    int state_rc;

    Verilated::commandArgs(argc, argv);
    scr1_state_dump_init(argc, argv);

    top = new Vscr1_top_tb_ahb;

#ifdef VCD_TRACE
    Verilated::traceEverOn(true);
    VerilatedVcdC* tfp = new VerilatedVcdC;
#ifdef TRACE_LVLV
    top->trace(tfp, TRACE_LVLV);
#else
    top->trace(tfp, 99);  // Trace 99 levels of hierarchy by default
#endif // #ifdef TRACE_LVLV

#ifdef VCD_FNAME
    tfp->open(STRINGIFY(VCD_FNAME));
#else
    tfp->open("./simx.vcd");
#endif // #ifdef VCD_FNAME
#endif // #ifdef VCD_TRACE

    while (!Verilated::gotFinish() && !scr1_state_dump_should_stop()) {
        if ((main_time % 10) == 1) {
            top->clk = 1;
        }
        if ((main_time % 10) == 6) {
            top->clk = 0;
        }
        top->eval();
        scr1_state_dump_poll(top, main_time);
        main_time++;
#ifdef VCD_TRACE
        tfp->dump(main_time);
#endif // #ifdef VCD_TRACE
    }
    top->final();
#ifdef VCD_TRACE
    tfp->close();
#endif // #ifdef VCD_TRACE
    state_rc = scr1_state_dump_finish(top, main_time);
    delete top;
    return state_rc;
}

