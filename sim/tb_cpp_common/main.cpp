#include <cstdlib>
#include <csignal>
#include <cstdio>
#include <memory>
#include <string>

#include "logger.h"
#include "options.h"
#include "state_dump.h"
#include "testbench.h"

//--------------------------------------------------------------------
// Locals
//--------------------------------------------------------------------
static testbench *g_tb = NULL;

//--------------------------------------------------------------------
// exit_override: flush traces on any exit path
//--------------------------------------------------------------------
static void exit_override(void)
{
    if (g_tb)
        g_tb->abort();
}

//--------------------------------------------------------------------
// sigint_handler
//--------------------------------------------------------------------
static void sigint_handler(int s)
{
    exit_override();
    logger::inst().test_fail("Signal: " + std::to_string(s));
    exit(EXIT_FAILURE);
}

//--------------------------------------------------------------------
// report_verify: verification status lines
//--------------------------------------------------------------------
static void report_verify(const options &opt, uint64_t compared,
                          uint64_t mismatches)
{
    logger &log = logger::inst();

    if (mismatches == 0)
        log.info("Verification OK: " + std::to_string(compared) +
                 " instructions compared against Spike, no mismatches");
    else
        log.error("Verification MISMATCH: " + std::to_string(mismatches) +
                  " deviations out of " + std::to_string(compared) +
                  " compared instructions");

    if (opt.verify_log != NULL)
        log.info("Verification log saved to " + std::string(opt.verify_log));
}

//--------------------------------------------------------------------
// main
//--------------------------------------------------------------------
int main(int argc, char *argv[])
{
    // Configuration: environment first, command line overrides
    options opt;
    opt.apply_env();
    opt.parse(argc, argv);

    Verilated::commandArgs(argc, argv);
    // Handle $stop/$fatal from RTL assertions gracefully: return to the
    // main loop instead of aborting, so the traces can be flushed
    Verilated::fatalOnError(false);

    srand(opt.seed);
    atexit(exit_override);
    signal(SIGINT, sigint_handler);

    logger &log = logger::inst();

    // Testbench and test image
    std::unique_ptr<testbench> tb = std::make_unique<testbench>();
    g_tb = tb.get();

    log.test_start(opt.elf);
    if (!tb->load_elf(opt.elf))
    {
        log.error(std::string("Could not load ") + opt.elf);
        exit(EXIT_FAILURE);
    }

    // Optional facilities
    if (opt.trace_log != NULL)
    {
        if (!tb->trace_log_enable(opt.trace_log))
            exit(EXIT_FAILURE);
        log.info(std::string("Trace log: ") + opt.trace_log);
    }

    if ((opt.verify < 0) || (opt.verify > 2))
    {
        log.error("--verify accepts 0 (off), 1 (incremental) or 2 (batch)");
        exit(EXIT_FAILURE);
    }
    if (opt.verify != 0)
    {
        if ((opt.verify_log != NULL) && !tb->verify_set_log(opt.verify_log))
            exit(EXIT_FAILURE);
        if (!tb->verify_enable((verify_mode)opt.verify, opt.elf, opt.isa))
            exit(EXIT_FAILURE);
    }

    if (opt.trace && tb->waves_enabled())
    {
        if (opt.waves_delay_us >= 0)
            tb->set_trace_delay_us((uint32_t)opt.waves_delay_us);
        tb->trace_enable(opt.vcd_name);
    }

    // Go!
    int rc = tb->run((uint64_t)opt.max_cycles);

    // Reference model results (BATCH compares here; any mode releases Spike)
    uint64_t compared   = 0;
    uint64_t mismatches = 0;
    bool     verified   = false;
    if (tb->verify_active())
    {
        tb->verify_finish();
        compared   = tb->verify_compared();
        mismatches = tb->verify_mismatches();
        verified   = true;
    }

    // Test result at the exit point. Three conventions coexist:
    //   - C tests (hello/mcycle/...): crt sets gp = __global_pointer$
    //     (nonzero); report_results puts the code into a0, 0 = pass
    //   - riscv-tests (riscv_isa): TESTNUM = gp; pass = 1,
    //     fail = small odd value (2n+1 or |1337)
    //   - riscv_arch / riscv_compliance / isr_sample: gp and a0 are
    //     clobbered by test data; pass/fail is defined by the offline
    //     signature, so registers give no reliable verdict
    uint32_t    result      = 0;
    bool        a0_bad      = false;
    bool        ambiguous   = false;
    const char *result_reg  = "a0";
    if ((rc == 0) && opt.check_a0)
    {
        uint32_t gp     = tb->result_gp();
        uint32_t a0     = tb->result_a0();
        uint32_t gp_sym = tb->gp_symbol();

        if ((gp_sym != 0u) && (gp == gp_sym))
        {
            // C test: a0 is the result code
            if (a0 != 0u)
            {
                a0_bad = true;
                result = a0;
            }
        }
        else if (gp == 1u)
        {
            // riscv-tests PASS
        }
        else if ((gp & 1u) && (gp <= 0xFFFFu))
        {
            // riscv-tests FAIL encoding (small odd TESTNUM)
            a0_bad     = true;
            result     = gp;
            result_reg = "gp/TESTNUM";
        }
        else if (a0 != 0u)
        {
            // arch/compliance family: registers carry test data
            ambiguous = true;
            result    = a0;
        }
    }

    const char *status = Verilated::gotError()       ? "ERROR"
                       : (rc == 2 || mismatches > 0) ? "VERIFY"
                       : a0_bad                      ? "FAIL"
                       : (rc == 0)                   ? "PASS"
                       :                               "TIMEOUT";

    // Architectural state dump (GPRs + CSRs)
    if (opt.state_log || opt.state_file)
    {
        scr1_state st;
        tb->capture_state(st);
        if (opt.state_log)
            state_dump::to_log(st, status, tb->sim_time_ns());
        if (opt.state_file)
            state_dump::to_file(opt.state_file, st, status, tb->sim_time_ns());
    }

    if (verified)
        report_verify(opt, compared, mismatches);

    if (ambiguous)
    {
        char buf[96];
        snprintf(buf, sizeof(buf), "a0=0x%08x at exit is test data, not a verdict "
                 "(arch/compliance family: pass/fail is defined by the signature; "
                 "use --verify for runtime checking)", result);
        log.warning(buf);
    }

    // Verdict
    if (Verilated::gotError())
    {
        log.test_fail("RTL error/assertion at cycle " + std::to_string(tb->cycles()) +
                      " (" + std::to_string(tb->sim_time_ns()) + " ns)");
        tb->abort();
        exit(EXIT_FAILURE);
    }

    if (rc == 2 || mismatches > 0)
    {
        log.test_fail("Verification mismatch after " + std::to_string(compared) +
                      " compared instructions (cycle " + std::to_string(tb->cycles()) + ")");
        tb->abort();
        exit(EXIT_FAILURE);
    }

    if (a0_bad)
    {
        char buf[96];
        snprintf(buf, sizeof(buf), "Test returned failure code %s=0x%08x",
                 result_reg, result);
        log.test_fail(buf);
        tb->abort();
        exit(EXIT_FAILURE);
    }

    if (rc == 0)
    {
        log.test_pass(tb->cycles(), tb->sim_time_ns(), tb->print_count());
        tb->abort();
        exit(EXIT_SUCCESS);
    }

    log.test_fail("Timeout after " + std::to_string(tb->cycles()) + " cycles");
    tb->abort();
    exit(EXIT_FAILURE);
}
