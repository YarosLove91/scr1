#ifndef OPTIONS_H
#define OPTIONS_H

#include <cstdint>

//--------------------------------------------------------------------
// Default watchdog: native TIMEOUT = 20 ms @ 100 MHz
//--------------------------------------------------------------------
#define DEFAULT_MAX_CYCLES 2000000

//--------------------------------------------------------------------
// options: command line / environment configuration of a run
//--------------------------------------------------------------------
struct options
{
    // Test image (required)
    const char *elf            = NULL;                    // -f, --elf

    // Simulation control
    int64_t     max_cycles     = DEFAULT_MAX_CYCLES;      // -c, --cycles
    int         seed           = 1;                       // -s, --seed / env SEED

    // Waveform tracing
    int         trace          = 1;                       // -t, --trace / env ENABLE_WAVES
    const char *vcd_name       = "sysc_wave.vcd";         // -w, --vcd_name
    int64_t     waves_delay_us = -1;                      // env WAVES_DELAY_US (-1 = unset)

    // Architectural state dump
    int         state_log      = 0;                       // -S, --state
    const char *state_file     = NULL;                    // -F, --state_file

    // Program execution trace
    const char *trace_log      = NULL;                    // -L, --trace_log

    // Spike reference model verification
    int         verify         = 0;                       // -V, --verify 0|1|2
    const char *verify_log     = NULL;                    // -v, --verbose FILE
    const char *isa            = "rv32imc_zicsr_zifencei";// -I, --isa

    // Environment overrides (applied before CLI parsing)
    void apply_env(void);
    // Parse the command line; prints usage and exits on error or -h
    void parse(int argc, char *argv[]);
    // Usage text (does not return)
    static void usage(void);
};

#endif
