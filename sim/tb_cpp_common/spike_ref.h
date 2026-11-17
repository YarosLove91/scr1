#ifndef SPIKE_REF_H
#define SPIKE_REF_H

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include <sys/types.h>

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
// ref_commit: one parsed record of the Spike commit log
//   core   0: 3 0x00000200 (0x00000093) x 1 0x00000000
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
// spike_ref: runs Spike as a subprocess (commit log streaming) and
// parses its output lazily, record by record.
//--------------------------------------------------------------------
class spike_ref
{
public:
    spike_ref();
    ~spike_ref();

    bool start(const char *elf, const char *isa, const char *spike_path);
    void stop(void);
    bool is_running(void) const { return m_pid > 0; }

    // Blocking read of the next commit record; false on EOF/error
    bool next_commit(ref_commit &c);

    const std::string &error(void) const { return m_error; }

private:
    bool parse_commit(const char *line, ref_commit &c);

    FILE   *m_file;
    pid_t   m_pid;
    std::string m_error;
};

//--------------------------------------------------------------------
// verifier: compares the DUT retirement stream (trace_logger
// listener events) against Spike commits.
//--------------------------------------------------------------------
class verifier : public trace_retire_listener
{
public:
    verifier();
    ~verifier();

    bool enable(verify_mode mode, const char *elf, const char *isa,
                const char *spike_path);
    bool        active(void) const  { return m_mode != verify_mode::OFF; }
    verify_mode mode(void) const    { return m_mode; }

    // Write every compared iteration to a file (console keeps only
    // mismatches). Returns false when the file cannot be opened.
    bool set_verbose_file(const char *path);

    // trace_retire_listener
    void on_retire(const retire_event &ev) override;

    // BATCH: drain the reference and compare everything; returns the
    // number of mismatches (0 = verified clean)
    uint64_t finish(void);

    // INCREMENTAL fail-fast flag: simulation should stop
    bool     failed(void) const      { return m_fail_fast; }
    uint64_t compared(void) const    { return m_compared; }
    uint64_t mismatches(void) const  { return m_mismatches; }

private:
    bool fetch_ref(ref_commit &c);
    const char *diff_reason(const retire_event &ev, const ref_commit &ref);
    void compare_and_report(const retire_event &ev, const ref_commit &ref);
    void print_iteration(const retire_event &ev, const ref_commit &ref,
                         const char *reason);
    void print_skip(const retire_event &ev);
    void note_error(const retire_event &ev, const ref_commit &ref,
                    const char *what);

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
