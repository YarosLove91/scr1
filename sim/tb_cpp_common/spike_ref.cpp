#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <iomanip>
#include <iostream>

#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include "logger.h"
#include "spike_ref.h"

//--------------------------------------------------------------------
// spike_ref
//--------------------------------------------------------------------
spike_ref::spike_ref()
{
    m_file = NULL;
    m_pid  = -1;
}

spike_ref::~spike_ref()
{
    stop();
}

//--------------------------------------------------------------------
// resolve_exe: locate an executable by name (PATH lookup like execvp)
// so that a missing Spike binary is reported before forking.
//--------------------------------------------------------------------
static std::string resolve_exe(const char *name)
{
    if (strchr(name, '/') != NULL)
        return (access(name, X_OK) == 0) ? std::string(name) : std::string();

    const char *path = getenv("PATH");
    if (path == NULL)
        return std::string();

    std::string candidate;
    const char *p = path;
    while (*p != '\0')
    {
        const char *colon = strchr(p, ':');
        size_t len = (colon != NULL) ? (size_t)(colon - p) : strlen(p);
        if (len > 0)
        {
            candidate.assign(p, len);
            candidate += '/';
            candidate += name;
            if (access(candidate.c_str(), X_OK) == 0)
                return candidate;
        }
        if (colon == NULL)
            break;
        p = colon + 1;
    }
    return std::string();
}

//--------------------------------------------------------------------
// start: fork Spike with the commit log streaming into a pipe.
// Spike never terminates on scr1 tests (SIM_STOP is a self-jump),
// so the log is consumed lazily and the process is killed at stop().
//--------------------------------------------------------------------
bool spike_ref::start(const char *elf, const char *isa, const char *spike_path)
{
    std::string exe = resolve_exe(spike_path);
    if (exe.empty())
    {
        m_error = std::string("executable not found: '") + spike_path +
                  "' (set $SPIKE or pass --spike /path/to/spike)";
        logger::inst().error("spike: " + m_error);
        return false;
    }

    int fds[2];
    if (pipe(fds) != 0)
    {
        m_error = std::string("pipe(): ") + strerror(errno);
        logger::inst().error("spike: " + m_error);
        return false;
    }

    pid_t pid = fork();
    if (getenv("TB_DEBUG_SPIKE"))
    {
        char dbg[128];
        int n = snprintf(dbg, sizeof(dbg), "[tb] fork() returned %d (errno=%d)\n", (int)pid, errno);
        write(STDERR_FILENO, dbg, n);
    }
    if (pid < 0)
    {
        m_error = std::string("fork(): ") + strerror(errno);
        logger::inst().error("spike: " + m_error);
        close(fds[0]);
        close(fds[1]);
        return false;
    }

    if (pid == 0)
    {
        // Child: spike <args> with stdout+stderr merged into the pipe.
        // stdin goes to /dev/null so Spike never touches the terminal
        // (blocking reads / SIGTTIN when the TB runs in background).
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0)
        {
            dup2(devnull, STDIN_FILENO);
            close(devnull);
        }
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);

        std::string isa_arg  = std::string("--isa=") + isa;
        std::string map_arg  = std::string("-m");
        const char *map_env  = getenv("SPIKE_MEM_MAP");
        // RAM at 0x0 (code/data/TCM) + RAM window over the SIM MMIO
        // registers (0xF0000000 print / 0xF0000100 ext_irq / 0xF0000200
        // soft_irq): stores there become plain memory writes for Spike,
        // keeping the commit stream in sync with the DUT.
        map_arg += (map_env && map_env[0]) ? map_env
                                           : "0x0:0x1000000,0xf0000000:0x1000";

        const char *argv[] =
        {
            exe.c_str(),
            "--disable-dtb",      // no boot ROM: PC starts at the ELF entry
            "--no-dm",            // no debug module at [0x0, 0x1000)
            "--log-commits",
            isa_arg.c_str(),
            "--priv=m",
            map_arg.c_str(),
            elf,
            NULL
        };
        execv(exe.c_str(), (char *const *)argv);
        if (getenv("TB_DEBUG_SPIKE"))
        {
            char dbg[256];
            int n = snprintf(dbg, sizeof(dbg), "[tb-child] execv(%s) failed: %s\n",
                             exe.c_str(), strerror(errno));
            write(STDERR_FILENO, dbg, n);
        }
        _exit(127);
    }

    // Parent
    close(fds[1]);
    m_file = fdopen(fds[0], "r");
    if (m_file == NULL)
    {
        m_error = std::string("fdopen(): ") + strerror(errno);
        logger::inst().error("spike: " + m_error);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return false;
    }
    m_pid = pid;
    return true;
}

//--------------------------------------------------------------------
// stop: kill the reference process and close the pipe
//--------------------------------------------------------------------
void spike_ref::stop(void)
{
    if (m_file != NULL)
    {
        fclose(m_file);
        m_file = NULL;
    }
    if (m_pid > 0)
    {
        kill(m_pid, SIGKILL);
        waitpid(m_pid, NULL, 0);
        m_pid = -1;
    }
}

//--------------------------------------------------------------------
// parse_commit: extract pc/instr and an optional GPR write from one
// Spike commit-log line, e.g.
//   core   0: 3 0x00000200 (0x00000093) x 1 0x00000000
//--------------------------------------------------------------------
bool spike_ref::parse_commit(const char *line, ref_commit &c)
{
    // Instruction word is enclosed in parentheses
    const char *open_paren  = strchr(line, '(');
    const char *close_paren = (open_paren != NULL) ? strchr(open_paren, ')') : NULL;
    if ((open_paren == NULL) || (close_paren == NULL) ||
        (close_paren - open_paren < 3))
        return false;

    c = ref_commit();
    c.instr = (uint32_t)strtoul(open_paren + 1, NULL, 16);

    // PC: last "0x..." token before the parenthesis
    const char *pc_tok = NULL;
    for (const char *p = line; p < open_paren - 1; ++p)
    {
        if ((p[0] == '0') && ((p[1] == 'x') || (p[1] == 'X')))
            pc_tok = p;
    }
    if (pc_tok == NULL)
        return false;
    c.pc = (uint32_t)strtoul(pc_tok + 2, NULL, 16);

    // Optional register write: "x<reg> 0x<val>" after the parenthesis
    // (CSR writes look like "c773_mtvec 0x..." and are ignored)
    const char *t = close_paren + 1;
    while (*t == ' ')
        t++;
    if ((t[0] == 'x') && (t[1] >= '0') && (t[1] <= '9'))
    {
        char *end = NULL;
        unsigned long rd = strtoul(t + 1, &end, 10);
        if ((end != NULL) && (end != t + 1))
        {
            while (*end == ' ')
                end++;
            if ((end[0] == '0') && ((end[1] == 'x') || (end[1] == 'X')))
            {
                c.rd_wr  = true;
                c.rd     = (uint32_t)rd;
                c.rd_val = (uint32_t)strtoul(end + 2, NULL, 16);
            }
        }
    }
    return true;
}

//--------------------------------------------------------------------
// next_commit: blocking read of the next commit record; non-commit
// lines (banners, exception reports) are skipped
//--------------------------------------------------------------------
bool spike_ref::next_commit(ref_commit &c)
{
    if (m_file == NULL)
        return false;

    char line[1024];
    while (fgets(line, sizeof(line), m_file) != NULL)
    {
        if (parse_commit(line, c))
            return true;
    }
    return false;
}

//--------------------------------------------------------------------
// verifier
//--------------------------------------------------------------------
verifier::verifier()
{
    m_mode       = verify_mode::OFF;
    m_compared   = 0;
    m_mismatches = 0;
    m_fail_fast  = false;
    m_ref_eof    = false;
    m_verbose_file = NULL;
}

verifier::~verifier()
{
    m_spike.stop();
    if (m_verbose_file != NULL)
    {
        fclose(m_verbose_file);
        m_verbose_file = NULL;
    }
}

//--------------------------------------------------------------------
// set_verbose_file: iteration log destination (console keeps only
// mismatches)
//--------------------------------------------------------------------
bool verifier::set_verbose_file(const char *path)
{
    if (m_verbose_file != NULL)
    {
        fclose(m_verbose_file);
        m_verbose_file = NULL;
    }
    m_verbose_file = fopen(path, "w");
    if (m_verbose_file == NULL)
    {
        logger::inst().error(std::string("cannot open verification log '") + path + "'");
        return false;
    }
    fprintf(m_verbose_file, "# SCR1 vs Spike verification iterations\n");
    return true;
}

//--------------------------------------------------------------------
// enable
//--------------------------------------------------------------------
bool verifier::enable(verify_mode mode, const char *elf, const char *isa,
                      const char *spike_path)
{
    m_mode = mode;
    if (m_mode == verify_mode::OFF)
        return true;

#ifndef TB_STATE_DUMP
    logger::inst().error("verification needs a STATE_DUMP=1 build (public model internals)");
    m_mode = verify_mode::OFF;
    return false;
#else
    if (!m_spike.start(elf, isa, spike_path))
    {
        logger::inst().error("cannot start Spike: " + m_spike.error());
        m_mode = verify_mode::OFF;
        return false;
    }
    logger::inst().info(std::string("Verification: ") +
                        (m_mode == verify_mode::INCREMENTAL ? "INCREMENTAL" : "BATCH") +
                        " (spike: " + spike_path + ", isa: " + isa + ")");
    return true;
#endif
}

//--------------------------------------------------------------------
// fetch_ref
//--------------------------------------------------------------------
bool verifier::fetch_ref(ref_commit &c)
{
    if (m_ref_eof)
        return false;
    if (!m_spike.next_commit(c))
    {
        m_ref_eof = true;
        return false;
    }
    return true;
}

//--------------------------------------------------------------------
// note_error
//--------------------------------------------------------------------
void verifier::note_error(const retire_event &ev, const ref_commit &ref,
                          const char *what)
{
    m_mismatches++;
    if (m_mismatches <= MAX_REPORTED)
    {
        char dut_rd[32], ref_rd[32], buf[512];

        if (ev.rd_wr)
            snprintf(dut_rd, sizeof(dut_rd), "x%u=0x%08x", (unsigned)ev.rd, ev.rd_val);
        else
            snprintf(dut_rd, sizeof(dut_rd), "-");

        if (ref.rd_wr)
            snprintf(ref_rd, sizeof(ref_rd), "x%u=0x%08x", (unsigned)ref.rd, ref.rd_val);
        else
            snprintf(ref_rd, sizeof(ref_rd), "-");

        snprintf(buf, sizeof(buf),
                 "VERIFY %s at cycle %llu: DUT pc=0x%08x instr=0x%08x rd[%s] | "
                 "spike pc=0x%08x instr=0x%08x rd[%s]",
                 what, (unsigned long long)ev.cycle,
                 ev.pc, ev.instr, dut_rd,
                 ref.pc, ref.instr, ref_rd);
        logger::inst().error(buf);
    }
    else if (m_mismatches == MAX_REPORTED + 1)
    {
        logger::inst().error("VERIFY: further mismatches suppressed");
    }
}

//--------------------------------------------------------------------
// diff_reason: NULL when the DUT event matches the reference commit
//--------------------------------------------------------------------
const char *verifier::diff_reason(const retire_event &ev, const ref_commit &ref)
{
    if (ev.pc != ref.pc)        return "pc mismatch";
    if (ev.instr != ref.instr)  return "instr mismatch";
    if (ev.rd_wr != ref.rd_wr)  return "rd write presence mismatch";
    if (ev.rd_wr)
    {
        if (ev.rd != ref.rd)        return "rd index mismatch";
        if (ev.rd_val != ref.rd_val) return "rd value mismatch";
    }
    return NULL;
}

//--------------------------------------------------------------------
// print_iteration: one verbose line per compared instruction
//--------------------------------------------------------------------
void verifier::print_iteration(const retire_event &ev, const ref_commit &ref,
                               const char *reason)
{
    char dut_rd[32], ref_rd[32];

    if (ev.rd_wr)
        snprintf(dut_rd, sizeof(dut_rd), "x%u=0x%08x", (unsigned)ev.rd, ev.rd_val);
    else
        snprintf(dut_rd, sizeof(dut_rd), "-");

    if (ref.rd_wr)
        snprintf(ref_rd, sizeof(ref_rd), "x%u=0x%08x", (unsigned)ref.rd, ref.rd_val);
    else
        snprintf(ref_rd, sizeof(ref_rd), "-");

    fprintf(m_verbose_file,
            "V[%7llu] cyc %7llu  DUT pc=0x%08x instr=0x%08x rd[%s]  |  "
            "REF pc=0x%08x instr=0x%08x rd[%s]  -> %s\n",
            (unsigned long long)m_compared, (unsigned long long)ev.cycle,
            ev.pc, ev.instr, dut_rd,
            ref.pc, ref.instr, ref_rd,
            (reason != NULL) ? reason : "OK");

    if ((m_compared & 0x3FFu) == 0u)
        fflush(m_verbose_file);
}

//--------------------------------------------------------------------
// print_skip: verbose line for events excluded from the comparison
//--------------------------------------------------------------------
void verifier::print_skip(const retire_event &ev)
{
    fprintf(m_verbose_file,
            "V[   skip] cyc %7llu  DUT pc=0x%08x instr=0x%08x  "
            "-> SKIP (exception, not committed in spike)\n",
            (unsigned long long)ev.cycle, ev.pc, ev.instr);
}

//--------------------------------------------------------------------
// compare_and_report
//--------------------------------------------------------------------
void verifier::compare_and_report(const retire_event &ev, const ref_commit &ref)
{
    m_compared++;

    const char *reason = diff_reason(ev, ref);
    if (m_verbose_file != NULL)
        print_iteration(ev, ref, reason);
    // Console: mismatches only
    if (reason != NULL)
        note_error(ev, ref, reason);
}

//--------------------------------------------------------------------
// on_retire: called by the trace logger on every DUT retirement
//--------------------------------------------------------------------
void verifier::on_retire(const retire_event &ev)
{
    if (m_mode == verify_mode::OFF)
        return;

    // Spike does not emit a commit record for an instruction that took
    // an exception (only an "exception ..." line), while scr1's instret
    // counts it. Skip such events to stay in sync with the reference.
    if (ev.exc)
    {
        if (m_verbose_file != NULL)
            print_skip(ev);
        return;
    }

    if (m_mode == verify_mode::BATCH)
    {
        m_events.push_back(ev);
        return;
    }

    // INCREMENTAL: lockstep compare, fail fast
    if (m_fail_fast)
        return;

    ref_commit ref;
    if (!fetch_ref(ref))
    {
        logger::inst().error("VERIFY: reference model produced no more commits "
                             "(spike terminated early or log unreadable) at cycle " +
                             std::to_string(ev.cycle));
        m_mismatches++;
        m_fail_fast = true;
        return;
    }
    compare_and_report(ev, ref);
    if (m_mismatches > 0)
        m_fail_fast = true;
}

//--------------------------------------------------------------------
// finish: BATCH comparison at the end of simulation; in any mode it
// stops the reference process (guaranteed child cleanup).
//--------------------------------------------------------------------
uint64_t verifier::finish(void)
{
    if (m_mode == verify_mode::BATCH)
    {
        for (size_t i = 0; i < m_events.size(); ++i)
        {
            ref_commit ref;
            if (!fetch_ref(ref))
            {
                if (m_mismatches < MAX_REPORTED)
                    logger::inst().error("VERIFY: reference exhausted after " +
                                         std::to_string(m_compared) + " commits, " +
                                         std::to_string(m_events.size() - i) +
                                         " DUT events left uncompared");
                m_mismatches += (m_events.size() - i);
                break;
            }
            compare_and_report(m_events[i], ref);
        }
        if (m_verbose_file != NULL)
            fflush(m_verbose_file);
    }

    m_spike.stop();
    return m_mismatches;
}
