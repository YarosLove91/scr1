#ifndef TESTBENCH_H
#define TESTBENCH_H

#include <cstdint>
#include <memory>
#include <string>

#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#include "Vscr1_top_ahb.h"
#include "options.h"
#include "tb_ahb_mem.h"
#include "trace_logger.h"
#include "spike_ref.h"

struct scr1_state;

//--------------------------------------------------------------------
// Simulation time base: 1 unit = 1 ns, clk period = 10 ns (100 MHz)
//--------------------------------------------------------------------
#define CLK_HALF_PERIOD     5
#define RTC_CLK_DIV         50      // rtc_clk toggle every 50 cycles (1 MHz)
#define RESET_CYCLES        10      // rst_n low duration
#define TRST_CYCLES         90      // trst_n low duration (~900 ns, native TB)

//--------------------------------------------------------------------
// testbench: pure C++ replacement of scr1_top_tb_ahb
//--------------------------------------------------------------------
class testbench
{
public:
    testbench();
    ~testbench();

    bool load_elf(const char *filename);
    // Returns 0 on test exit, 1 on timeout, 2 on verification failure
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

    // Test result code: a0 (x10) at the exit point, per report_results()
    uint32_t result_a0(void) const;

    // Program execution trace log (one line per retired instruction)
    bool trace_log_enable(const char *path);
    bool trace_log_enabled(void) const { return m_trace.is_open(); }

    // Spike reference model verification (OFF/INCREMENTAL/BATCH)
    bool verify_enable(verify_mode mode, const char *elf, const char *isa);
    bool verify_set_log(const char *path)  { return m_verify.set_verbose_file(path); }
    bool     verify_active(void) const     { return m_verify.active(); }
    bool     verify_failed(void) const     { return m_verify.failed(); }
    uint64_t verify_finish(void)           { return m_verify.finish(); }
    uint64_t verify_compared(void) const   { return m_verify.compared(); }
    uint64_t verify_mismatches(void) const { return m_verify.mismatches(); }

private:
    void tick(void);
    void dump(void);
    void update_resets(void);

    std::unique_ptr<Vscr1_top_ahb> m_top;
    tb_ahb_mem                     m_mem;
    trace_logger                   m_trace;
    trace_inputs                   m_trace_in;
    verifier                       m_verify;

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
