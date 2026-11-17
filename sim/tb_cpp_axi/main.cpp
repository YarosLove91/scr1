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
#define GETOPTS_ARGS "f:c:h"

static struct option long_options[] =
{
    {"elf",        required_argument, 0, 'f'},
    {"cycles",     required_argument, 0, 'c'},
    {"trace",      required_argument, 0, 't'},
    {"seed",       required_argument, 0, 's'},
    {"vcd_name",   required_argument, 0, 'w'},
    {"state",      required_argument, 0, 'S'},
    {"state_file", required_argument, 0, 'F'},
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
    std::cerr << "Environment:"                                                         << std::endl;
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
    int64_t     max_cycles = DEFAULT_MAX_CYCLES;
    const char *vcd_name   = "sysc_wave.vcd";
    const char *filename   = NULL;

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

    if (trace && tb->waves_enabled())
    {
        s = getenv("WAVES_DELAY_US");
        if (s)
            tb->set_trace_delay_us((uint32_t)strtoul(s, NULL, 0));
        tb->trace_enable(vcd_name);
    }

    // Go!
    int rc = tb->run((uint64_t)max_cycles);

    const char *status = Verilated::gotError() ? "ERROR"
                       : (rc == 0)             ? "PASS"
                       :                         "TIMEOUT";

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

    if (Verilated::gotError())
    {
        log.test_fail("RTL error/assertion at cycle " + std::to_string(tb->cycles()) +
                      " (" + std::to_string(tb->sim_time_ns()) + " ns)");
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
