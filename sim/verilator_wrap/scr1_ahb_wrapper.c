
#include <stdio.h>
#include <verilated.h>
#include "Vscr1_top_tb_ahb.h"
#include "Vscr1_top_tb_ahb__Syms.h"
#ifdef VCD_TRACE
#include "verilated_vcd_c.h"
#endif // #ifdef VCD_TRACE

#define SCR1_STATE_TOP      scr1_top_tb_ahb
#define SCR1_STATE_MODEL    Vscr1_top_tb_ahb
#include "scr1_state_dump.h"
#ifdef VCD_TRACE
#include "scr1_vcd_per_test.h"
#endif

Vscr1_top_tb_ahb *top;

vluint64_t main_time = 0;

int main(int argc, char** argv) {
    int state_rc;

    Verilated::commandArgs(argc, argv);
    scr1_state_dump_init(argc, argv);

    top = new Vscr1_top_tb_ahb;

#ifdef VCD_TRACE
    scr1_vcd_split_t vcd_split;
    scr1_vcd_split_init(&vcd_split, top, argc, argv);
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
        scr1_vcd_split_tick(&vcd_split, top, main_time);
#endif // #ifdef VCD_TRACE
    }
    top->final();
#ifdef VCD_TRACE
    scr1_vcd_split_finish(&vcd_split, main_time);
#endif // #ifdef VCD_TRACE
    state_rc = scr1_state_dump_finish(top, main_time);
    delete top;
    return state_rc;
}

