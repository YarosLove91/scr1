#include <cstdlib>
#include <cstring>
#include <csignal>
#include <getopt.h>
#include <iostream>
#include <memory>
#include <string>

#include "logger.h"
#include "state_dump.h"
#include "testbench.h"

//--------------------------------------------------------------------
// Locals
//--------------------------------------------------------------------
static testbench *g_tb = NULL;

//--------------------------------------------------------------------
// exit_override
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
// Command line options
//--------------------------------------------------------------------
#define GETOPTS_ARGS "f:c:v:h"

static struct option long_options[] =
{
    {"elf",        required_argument, 0, 'f'},
    {"cycles",     required_argument, 0, 'c'},
    {"trace",      required_argument, 0, 't'},
    {"seed",       required_argument, 0, 's'},
    {"vcd_name",   required_argument, 0, 'w'},
    {"state",      required_argument, 0, 'S'},
    {"state_file", required_argument, 0, 'F'},
    {"trace_log",  required_argument, 0, 'L'},
    {"verify",     required_argument, 0, 'V'},
    {"verbose",    required_argument, 0, 'v'},
    {"spike",      required_argument, 0, 'P'},
    {"isa",        required_argument, 0, 'I'},
    {"help",       no_argument,       0, 'h'},
    {0, 0, 0, 0}
};

static void help_options(void)
{
    std::cerr << "Usage:"                                                               << std::endl;
    std::cerr << "  --elf         | -f FILE       ELF file to load"                      << std::endl;
    std::cerr << "  --cycles      | -c NUM        Max cycles to execute (default "
              << DEFAULT_MAX_CYCLES << ")"                                               << std::endl;
    std::cerr << "  --trace       | -t 0|1        Enable VCD trace (default 1)"          << std::endl;
    std::cerr << "  --seed        | -s NUM        Random seed"                           << std::endl;
    std::cerr << "  --vcd_name    | -w FILE       VCD file name (default sysc_wave.vcd)" << std::endl;
    std::cerr << "  --state       | -S 0|1        Dump GPR/CSR state to the log at the end" << std::endl;
    std::cerr << "  --state_file  | -F FILE       Write GPR/CSR state to FILE (native scr1_final_state.txt format)" << std::endl;
    std::cerr << "  --trace_log   | -L FILE       Program execution trace: one line per retired instruction" << std::endl;
    std::cerr << "  --verify      | -V 0|1|2      Spike verification: 0=off, 1=incremental (per instruction)," << std::endl;
    std::cerr << "                                2=batch (compare at the end)" << std::endl;
    std::cerr << "  --spike       | -P PATH       Spike binary (default: $SPIKE or 'spike' from PATH)" << std::endl;
    std::cerr << "  --isa         | -I STR        Spike ISA string (default rv32imc_zicsr_zifencei)" << std::endl;
    std::cerr << "  --verbose     | -v FILE       Write every verification iteration to FILE" << std::endl;
    std::cerr << "                                (console shows mismatches only)" << std::endl;
    std::cerr << "Environment:"                                                         << std::endl;
    std::cerr << "  SPIKE=/path/to/spike          Spike binary path"                       << std::endl;
    std::cerr << "  SPIKE_MEM_MAP=base:size       Spike RAM mapping (default 0x0:0x1000000)" << std::endl;
    std::cerr << "  ENABLE_WAVES=no               Disable tracing"                       << std::endl;
    std::cerr << "  WAVES_DELAY_US=N              Delay trace start"                     << std::endl;
    std::cerr << "  SEED=N                        Random seed"                           << std::endl;
    std::cerr << "  NO_COLOR=1                    Disable colored output"                << std::endl;
    exit(-1);
}

//--------------------------------------------------------------------
// main
//--------------------------------------------------------------------
int main(int argc, char *argv[])
{
    int         trace      = 1;
    int         seed       = 1;
    int         state_log  = 0;
    const char *state_file = NULL;
    const char *trace_log  = NULL;
    int         verify      = 0;
    const char *verify_log  = NULL;
    const char *isa        = "rv32imc_zicsr_zifencei";
    int64_t     max_cycles = DEFAULT_MAX_CYCLES;
    const char *vcd_name   = "sysc_wave.vcd";
    const char *filename   = NULL;

    // Spike binary: --spike option, then $SPIKE, then PATH
    const char *spike_path = getenv("SPIKE");
    if ((spike_path == NULL) || (spike_path[0] == '\0'))
        spike_path = "spike";

    Verilated::commandArgs(argc, argv);
    // Handle $stop/$fatal from RTL assertions gracefully: return to the
    // main loop instead of aborting, so the VCD can be flushed
    Verilated::fatalOnError(false);

    // Env variable seed override
    char *s = getenv("SEED");
    if (s && strcmp(s, ""))
        seed = strtol(s, NULL, 0);

    // Env variable waves override
    s = getenv("ENABLE_WAVES");
    if (s && !strcmp(s, "no"))
        trace = 0;

    int c;
    int option_index = 0;
    while ((c = getopt_long(argc, argv, GETOPTS_ARGS, long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'f':
                filename = optarg;
                break;
            case 'c':
                max_cycles = (int64_t)strtoull(optarg, NULL, 0);
                break;
            case 't':
                trace = strtol(optarg, NULL, 0);
                break;
            case 's':
                seed = strtol(optarg, NULL, 0);
                break;
            case 'w':
                vcd_name = optarg;
                break;
            case 'S':
                state_log = strtol(optarg, NULL, 0);
                break;
            case 'F':
                state_file = optarg;
                break;
            case 'L':
                trace_log = optarg;
                break;
            case 'V':
                verify = (int)strtol(optarg, NULL, 0);
                break;
            case 'P':
                spike_path = optarg;
                break;
            case 'I':
                isa = optarg;
                break;
            case 'v':
                verify_log = optarg;
                break;
            case 'h':
            case '?':
            default:
                help_options();
                break;
        }
    }

    if (filename == NULL)
        help_options();

    srand(seed);

    // Capture exit / SIGINT to flush the VCD
    atexit(exit_override);
    signal(SIGINT, sigint_handler);

    logger &log = logger::inst();

    std::unique_ptr<testbench> tb = std::make_unique<testbench>();
    g_tb = tb.get();

    log.test_start(filename);
    if (!tb->load_elf(filename))
    {
        log.error(std::string("Could not load ") + filename);
        exit(EXIT_FAILURE);
    }

    if (trace_log != NULL)
    {
        if (!tb->trace_log_enable(trace_log))
            exit(EXIT_FAILURE);
        log.info(std::string("Trace log: ") + trace_log);
    }

    if ((verify < 0) || (verify > 2))
    {
        log.error("--verify accepts 0 (off), 1 (incremental) or 2 (batch)");
        exit(EXIT_FAILURE);
    }
    if (verify != 0)
    {
        if ((verify_log != NULL) && !tb->verify_set_log(verify_log))
            exit(EXIT_FAILURE);
        if (!tb->verify_enable((verify_mode)verify, filename, isa, spike_path))
            exit(EXIT_FAILURE);
        if (verify_log != NULL)
            log.info(std::string("Verify log: ") + verify_log);
    }

    if (trace && tb->waves_enabled())
    {
        s = getenv("WAVES_DELAY_US");
        if (s)
            tb->set_trace_delay_us((uint32_t)strtoul(s, NULL, 0));
        tb->trace_enable(vcd_name);
    }

    // Go!
    int rc = tb->run((uint64_t)max_cycles);

    // Reference model verification results
    uint64_t compared   = 0;
    uint64_t mismatches = 0;
    bool     verified   = false;
    if (tb->verify_active())
    {
        tb->verify_finish();          // BATCH: compare; always: stop Spike
        compared   = tb->verify_compared();
        mismatches = tb->verify_mismatches();
        verified   = true;
    }

    const char *status = Verilated::gotError()        ? "ERROR"
                       : (rc == 2 || mismatches > 0)  ? "VERIFY"
                       : (rc == 0)                    ? "PASS"
                       :                                "TIMEOUT";

    // Architectural state dump (GPRs + CSRs)
    if (state_log || state_file)
    {
        scr1_state st;
        tb->capture_state(st);
        if (state_log)
            state_dump::to_log(st, status, tb->sim_time_ns());
        if (state_file)
            state_dump::to_file(state_file, st, status, tb->sim_time_ns());
    }

    if (verified)
    {
        if (mismatches == 0)
            log.info("Verification OK: " + std::to_string(compared) +
                     " instructions compared against Spike, no mismatches");
        else
            log.error("Verification MISMATCH: " + std::to_string(mismatches) +
                      " deviations out of " + std::to_string(compared) +
                      " compared instructions");
        if (verify_log != NULL)
            log.info("Verification log saved to " + std::string(verify_log));
    }

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
