#include <cstdlib>
#include <cstring>
#include <getopt.h>
#include <iostream>

#include "options.h"

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
    {"isa",        required_argument, 0, 'I'},
    {"help",       no_argument,       0, 'h'},
    {0, 0, 0, 0}
};

//--------------------------------------------------------------------
// usage
//--------------------------------------------------------------------
void options::usage(void)
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
    std::cerr << "  --verbose     | -v FILE       Write every verification iteration to FILE" << std::endl;
    std::cerr << "                                (console shows mismatches only)" << std::endl;
    std::cerr << "  --isa         | -I STR        Spike ISA string (default rv32imc_zicsr_zifencei)" << std::endl;
    std::cerr << "Environment:"                                                         << std::endl;
    std::cerr << "  ENABLE_WAVES=no               Disable tracing"                       << std::endl;
    std::cerr << "  WAVES_DELAY_US=N              Delay trace start"                     << std::endl;
    std::cerr << "  SEED=N                        Random seed"                           << std::endl;
    std::cerr << "  NO_COLOR=1                    Disable colored output"                << std::endl;
    std::cerr << "  SPIKE_MEM_MAP=b:size[,...]    Reference model RAM map"               << std::endl;
    std::cerr << "                                (default 0x0:0x1000000,0xf0000000:0x1000)" << std::endl;
    exit(-1);
}

//--------------------------------------------------------------------
// apply_env: environment overrides (CLI wins, call before parse)
//--------------------------------------------------------------------
void options::apply_env(void)
{
    char *s = getenv("SEED");
    if (s && s[0])
        seed = (int)strtol(s, NULL, 0);

    s = getenv("ENABLE_WAVES");
    if (s && !strcmp(s, "no"))
        trace = 0;

    s = getenv("WAVES_DELAY_US");
    if (s && s[0])
        waves_delay_us = (int64_t)strtoll(s, NULL, 0);
}

//--------------------------------------------------------------------
// parse: command line
//--------------------------------------------------------------------
void options::parse(int argc, char *argv[])
{
    int c;
    int option_index = 0;
    while ((c = getopt_long(argc, argv, GETOPTS_ARGS, long_options, &option_index)) != -1)
    {
        switch (c)
        {
            case 'f':
                elf = optarg;
                break;
            case 'c':
                max_cycles = (int64_t)strtoull(optarg, NULL, 0);
                break;
            case 't':
                trace = (int)strtol(optarg, NULL, 0);
                break;
            case 's':
                seed = (int)strtol(optarg, NULL, 0);
                break;
            case 'w':
                vcd_name = optarg;
                break;
            case 'S':
                state_log = (int)strtol(optarg, NULL, 0);
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
            case 'v':
                verify_log = optarg;
                break;
            case 'I':
                isa = optarg;
                break;
            case 'h':
            case '?':
            default:
                usage();
                break;
        }
    }

    if (elf == NULL)
        usage();
}
