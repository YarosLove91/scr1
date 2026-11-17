#ifndef STATE_DUMP_H
#define STATE_DUMP_H

#include <cstdint>
#include <string>

#include "dut_access.h"

//--------------------------------------------------------------------
// scr1_state: architectural state snapshot (GPRs + M-mode CSRs).
// Layout matches scr1_state_snapshot_t of the native mechanism
// (feat/state-dump branch, sim/verilator_wrap/scr1_state_dump.h).
//--------------------------------------------------------------------
struct scr1_state
{
    uint32_t gpr[32];
    uint32_t mstatus;
    uint32_t misa;
    uint32_t mie;
    uint32_t mtvec;
    uint32_t mscratch;
    uint32_t mepc;
    uint32_t mcause;
    uint32_t mtval;
    uint32_t mip;
    uint32_t mhartid;
    uint64_t mcycle;
    uint64_t minstret;
    uint32_t pc;
};

//--------------------------------------------------------------------
// state_dump: capture and report the architectural state via the
// verilated model internals (requires --public-flat-rw verilation,
// i.e. STATE_DUMP=1 at the generate stage).
//--------------------------------------------------------------------
class state_dump
{
public:
    // Capture the snapshot from the model
    static void capture(dut_top_t *top, scr1_state &st);

    // Read a single GPR (ABI index 0..31) from the model; returns 0
    // for x0 and for builds without public internals
    static uint32_t read_gpr(dut_top_t *top, unsigned idx);

    // Native scr1_final_state.txt-compatible text
    static std::string to_string(const scr1_state &st, const char *status, uint64_t time_ns);

    // Print the snapshot to the log
    static void to_log(const scr1_state &st, const char *status, uint64_t time_ns);

    // Write the snapshot to a file, returns false on error
    static bool to_file(const char *path, const scr1_state &st,
                        const char *status, uint64_t time_ns);
};

#endif
