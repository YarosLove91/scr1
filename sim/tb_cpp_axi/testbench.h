#ifndef TESTBENCH_H
#define TESTBENCH_H

#include <cstdint>
#include <memory>
#include <string>

#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include "Vscr1_top_axi.h"
#include "tb_axi_mem.h"

struct scr1_state;

//--------------------------------------------------------------------
// Simulation time base: 1 unit = 1 ns, clk period = 10 ns (100 MHz)
//--------------------------------------------------------------------
#define CLK_HALF_PERIOD     5
#define RTC_CLK_DIV         50      // rtc_clk toggle every 50 cycles (1 MHz)
#define RESET_CYCLES        10      // rst_n low duration
#define TRST_CYCLES         90      // trst_n low duration (~900 ns, native TB)
#define DEFAULT_MAX_CYCLES  2000000 // native TIMEOUT = 20 ms @ 100 MHz

//--------------------------------------------------------------------
// testbench: pure C++ replacement of scr1_top_tb_axi
//--------------------------------------------------------------------
class testbench
{
public:
    testbench();
    ~testbench();

    bool load_elf(const char *filename);
    int  run(uint64_t max_cycles = DEFAULT_MAX_CYCLES);
    void abort(void);

    void trace_enable(const char *vcd_name);
    void set_trace_delay_us(uint32_t us);

    bool     waves_enabled(void);
    uint64_t cycles(void) const      { return m_cycle; }
    uint64_t sim_time_ns(void) const { return m_time; }
    uint32_t entry_point(void) const { return m_entry_point; }
    uint64_t print_count(void) const { return m_mem.print_count(); }

    // Capture the architectural state (GPRs + CSRs) of the DUT
    void capture_state(scr1_state &st) const;

private:
    void tick(void);
    void dump(void);
    void update_resets(void);
    void sample_bus(void);
    void drive_bus(void);

    std::unique_ptr<Vscr1_top_axi> m_top;
    tb_axi_mem                     m_mem;

    uint64_t m_time;            // ns
    uint64_t m_cycle;
    uint32_t m_entry_point;

#if VM_TRACE
    std::unique_ptr<VerilatedVcdC> m_tfp;
    uint64_t                       m_trace_start;
    bool                           m_trace_on;
#endif
};

#endif
