#ifndef SPIKE_REF_H
#define SPIKE_REF_H

#include <cstdint>
#include <string>
#include <vector>

#include "mem_api.h"
#include "trace_logger.h"

//--------------------------------------------------------------------
// Verification modes against the Spike reference model
//--------------------------------------------------------------------
enum class verify_mode
{
    OFF         = 0,    // no verification
    INCREMENTAL = 1,    // compare on every retired instruction (fail fast)
    BATCH       = 2     // compare the whole run at the end of simulation
};

//--------------------------------------------------------------------
// ref_commit: one reference instruction stepped in the Spike model
//--------------------------------------------------------------------
struct ref_commit
{
    uint32_t pc;
    uint32_t instr;
    bool     rd_wr;
    uint32_t rd;
    uint32_t rd_val;

    ref_commit(): pc(0), instr(0), rd_wr(false), rd(0), rd_val(0) {}
};

//--------------------------------------------------------------------
// spike_ref: in-process Spike reference model (libriscv).
// The model is built once (RAM at 0x0 + a window over the SIM MMIO
// registers, ELF loaded by physical addresses) and stepped one
// instruction at a time in lockstep with the DUT retirement stream.
//--------------------------------------------------------------------
class spike_ref
{
public:
    spike_ref();
    ~spike_ref();

    // patches != NULL: raw image mode - bypass Spike's ELF loader (it
    // cannot consume ET_REL), preload the chunks via the bus and start
    // at the SCR1 reset vector (boot wrapper)
    bool start(const char *elf, const char *isa,
               const std::vector<mem_patch> *patches = NULL);
    void stop(void);
    bool is_running(void) const;

    // Execute one instruction; fill the commit info (pc/instr before
    // the step, GPR writeback as the register file diff)
    bool next_commit(ref_commit &c);

    const std::string &error(void) const { return m_error; }

private:
    spike_ref(const spike_ref &) = delete;
    spike_ref &operator=(const spike_ref &) = delete;

    struct impl;            // PIMPL: holds cfg_t/sim_t/processor_t
    impl       *m_impl;
    std::string m_error;
};

//--------------------------------------------------------------------
// verifier: compares the DUT retirement stream (trace_logger
// listener events) against the reference model, instruction by
// instruction (lockstep).
//--------------------------------------------------------------------
class verifier : public trace_retire_listener
{
public:
    verifier();
    ~verifier();

    bool enable(verify_mode mode, const char *elf, const char *isa,
                const std::vector<mem_patch> *patches = NULL);
    bool        active(void) const  { return m_mode != verify_mode::OFF; }
    verify_mode mode(void) const    { return m_mode; }

    // Write every compared iteration to a file (console keeps only
    // mismatches). Returns false when the file cannot be opened.
    bool set_verbose_file(const char *path);

    // trace_retire_listener
    void on_retire(const retire_event &ev) override;

    // BATCH: step the reference through the accumulated events and
    // compare; in any mode releases the reference model.
    // Returns the number of mismatches (0 = verified clean)
    uint64_t finish(void);

    // INCREMENTAL fail-fast flag: simulation should stop
    bool     failed(void) const      { return m_fail_fast; }
    uint64_t compared(void) const    { return m_compared; }
    uint64_t mismatches(void) const  { return m_mismatches; }

private:
    bool fetch_ref(ref_commit &c);
    void step_exception(const retire_event &ev);
    const char *diff_reason(const retire_event &ev, const ref_commit &ref);
    void compare_and_report(const retire_event &ev, const ref_commit &ref);
    void print_iteration(const retire_event &ev, const ref_commit &ref,
                         const char *reason);
    void print_skip(const retire_event &ev);
    void note_error(const retire_event &ev, const ref_commit &ref,
                    const char *what);
    void note_desync(const retire_event &ev, const ref_commit &ref);

    verify_mode             m_mode;
    spike_ref               m_spike;
    std::vector<retire_event> m_events;   // BATCH accumulation
    uint64_t                m_compared;
    uint64_t                m_mismatches;
    bool                    m_fail_fast;
    bool                    m_ref_eof;
    FILE                   *m_verbose_file;

    static const uint64_t MAX_REPORTED = 10;
};

#endif
