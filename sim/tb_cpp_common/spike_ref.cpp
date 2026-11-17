#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <exception>

#include <riscv/sim.h>
#include <riscv/devices.h>
#include <riscv/processor.h>
#include <riscv/decode.h>

#include "abi_names.h"
#include "boot_stub.h"
#include "logger.h"
#include "spike_ref.h"

//--------------------------------------------------------------------
// Default memory map: RAM at 0x0 (code/data/TCM) + a RAM window over
// the SIM MMIO registers (0xF0000000 print / 0xF0000100 ext_irq /
// 0xF0000200 soft_irq) so that stores there are plain memory writes
// for the reference model and do not disturb the commit stream.
//--------------------------------------------------------------------
#define SPIKE_MEM_MAP_DEFAULT "0x0:0x1000000,0xf0000000:0x1000"

//--------------------------------------------------------------------
// tb_sim_t: thin sim_t wrapper exposing the protected ELF entry point
// (the CLI reaches it via htif_t::run() -> reset(), which we do not
// call; the model is stepped manually in lockstep)
//--------------------------------------------------------------------
namespace {
class tb_sim_t : public sim_t
{
public:
    using sim_t::sim_t;
    reg_t entry_pc(void) { return get_entry_point(); }
    // htif_t::start(): load the ELF and reset the cores (sets the PC
    // to the ELF entry point via sim_t::reset/set_pc_to_entry_point)
    void tb_start(void) { start(); }
};
}

//--------------------------------------------------------------------
// spike_ref::impl: everything that needs the Spike headers
//--------------------------------------------------------------------
struct spike_ref::impl
{
    cfg_t                    cfg;         // must outlive sim
    std::string              isa_str;     // storage for cfg.isa
    std::string              priv_str;
    tb_sim_t                *sim;
    processor_t             *core;
    state_t                 *state;

    // RAM regions for direct instruction fetch (host pointers)
    struct ram_region
    {
        reg_t   base;
        reg_t   size;
        mem_t  *ram;
    };
    std::vector<ram_region>  rams;

    impl(): sim(NULL), core(NULL), state(NULL) {}
};

//--------------------------------------------------------------------
// parse_mem_map: "base:size[,base:size...]" -> mem_cfg_t vector
//--------------------------------------------------------------------
static bool parse_mem_map(const char *s, std::vector<mem_cfg_t> &out)
{
    out.clear();
    std::string copy(s);
    size_t pos = 0;
    while (pos < copy.size())
    {
        size_t comma = copy.find(',', pos);
        std::string item = copy.substr(pos, (comma == std::string::npos)
                                                 ? std::string::npos : comma - pos);
        size_t colon = item.find(':');
        if (colon == std::string::npos)
            return false;
        unsigned long long base = strtoull(item.substr(0, colon).c_str(), NULL, 0);
        unsigned long long size = strtoull(item.substr(colon + 1).c_str(), NULL, 0);
        if ((base == 0 && size == 0) || (size == 0))
            return false;
        out.push_back(mem_cfg_t((reg_t)base, (reg_t)size));
        if (comma == std::string::npos)
            break;
        pos = comma + 1;
    }
    return !out.empty();
}

//--------------------------------------------------------------------
// spike_ref
//--------------------------------------------------------------------
spike_ref::spike_ref()
{
    m_impl = new impl();
}

spike_ref::~spike_ref()
{
    stop();
    delete m_impl;
    m_impl = NULL;
}

//--------------------------------------------------------------------
// start: build the reference platform and load the ELF (by LMA,
// same as the DUT loader)
//--------------------------------------------------------------------
bool spike_ref::start(const char *elf, const char *isa,
                      const std::vector<mem_patch> *patches)
{
    stop();

    const char *map_env = getenv("SPIKE_MEM_MAP");
    std::vector<mem_cfg_t> layout;
    if (!parse_mem_map((map_env && map_env[0]) ? map_env : SPIKE_MEM_MAP_DEFAULT,
                       layout))
    {
        m_error = std::string("bad SPIKE_MEM_MAP format: '") +
                  ((map_env && map_env[0]) ? map_env : SPIKE_MEM_MAP_DEFAULT) + "'";
        logger::inst().error("spike: " + m_error);
        return false;
    }

    m_impl->isa_str  = isa;
    m_impl->priv_str = "m";
    m_impl->cfg.isa        = m_impl->isa_str.c_str();
    m_impl->cfg.priv       = m_impl->priv_str.c_str();
    m_impl->cfg.mem_layout = layout;

    std::vector<std::pair<reg_t, abstract_mem_t *>> mems;
    m_impl->rams.clear();
    for (const auto &m : layout)
    {
        mem_t *ram = new mem_t(m.get_size());
        mems.push_back(std::make_pair(m.get_base(), ram));
        m_impl->rams.push_back({m.get_base(), m.get_size(), ram});
    }

    std::vector<std::string> htif_args;
    // Raw image mode: do NOT give the ELF to htif (it asserts on ET_REL).
    // "none" keeps htif happy without loading anything; the image is
    // preloaded through the bus after construction.
    if ((patches == NULL) || patches->empty())
        htif_args.push_back(std::string(elf));
    else
        htif_args.push_back(std::string("none"));

    try
    {
        // No boot ROM (dtb disabled -> pc starts at the ELF entry),
        // no debug module, no plugins, no instruction limit
        m_impl->sim = new tb_sim_t(&m_impl->cfg,
                                /* halted            */ false,
                                /* mems              */ mems,
                                /* plugin devices    */ {},
                                /* dtb_discovery     */ false,
                                /* htif args         */ htif_args,
                                /* dm_config         */ std::nullopt,
                                /* log_path          */ "/dev/null",   // commit text sink
                                /* dtb_enabled       */ false,
                                /* dtb_file          */ nullptr,
                                /* socket_enabled    */ false,
                                /* cmd_file          */ nullptr,
                                /* instruction_limit */ std::nullopt);
    }
    catch (const std::exception &e)
    {
        m_error = std::string("sim_t: ") + e.what();
        logger::inst().error("spike: " + m_error);
        m_impl->sim = NULL;
        return false;
    }

    m_impl->core  = m_impl->sim->get_core(0);
    m_impl->state = m_impl->core->get_state();

    if ((patches != NULL) && !patches->empty())
    {
        // Raw image mode (ET_REL snippy): preload the chunks through the
        // bus and start at the reset vector where the boot wrapper lives
        bus_t &bus = const_cast<bus_t &>(m_impl->sim->get_bus());
        for (const auto &p : *patches)
        {
            if (!bus.store(p.addr, p.data.size(), p.data.data()))
            {
                m_error = "preload: bus store failed";
                logger::inst().error("spike: " + m_error);
                stop();
                return false;
            }
        }
        m_impl->core->reset();
        m_impl->state->pc = BOOT_STUB_BASE;
    }
    else
    {
        // Load the ELF via htif and start at its entry point
        try
        {
            m_impl->sim->tb_start();
        }
        catch (const std::exception &e)
        {
            m_error = std::string("start: ") + e.what();
            logger::inst().error("spike: " + m_error);
            stop();
            return false;
        }
    }

    // Record per-instruction register writebacks (state->log_reg_write);
    // the text commit log goes to /dev/null (see log_path above)
    m_impl->core->enable_log_commits();
    return true;
}

//--------------------------------------------------------------------
// stop: destroy the reference model
//--------------------------------------------------------------------
void spike_ref::stop(void)
{
    if (m_impl->sim != NULL)
    {
        delete m_impl->sim;
        m_impl->sim   = NULL;
        m_impl->core  = NULL;
        m_impl->state = NULL;
    }
}

bool spike_ref::is_running(void) const
{
    return m_impl->sim != NULL;
}

//--------------------------------------------------------------------
// next_commit: execute exactly one instruction in the reference
// model and report it as a commit record
//--------------------------------------------------------------------
bool spike_ref::next_commit(ref_commit &c)
{
    if (m_impl->sim == NULL)
        return false;

    c = ref_commit();
    state_t *st = m_impl->state;
    c.pc = (uint32_t)st->pc;

    // Instruction fetch straight from the RAM host memory (RVC aware).
    // NB: mem_t is page-sparse; contents() is valid only within one
    // 4 KiB page, so fetch in aligned 16-bit chunks (a 2-byte aligned
    // halfword never crosses a page boundary).
    auto fetch16 = [this](reg_t a) -> uint16_t {
        for (const auto &r : m_impl->rams)
        {
            if ((a >= r.base) && (a + 1 < r.base + r.size))
            {
                const uint8_t *p = (const uint8_t *)r.ram->contents(a - r.base);
                return (uint16_t)(p[0] | (p[1] << 8));
            }
        }
        return 0;
    };
    uint16_t lo = fetch16(st->pc);
    if ((lo & 3u) == 3u)
        c.instr = (uint32_t)lo | ((uint32_t)fetch16(st->pc + 2) << 16);
    else
        c.instr = lo;

    try
    {
        m_impl->core->step(1);
    }
    catch (const std::exception &e)
    {
        m_error = std::string("step: ") + e.what();
        logger::inst().error("spike: " + m_error);
        return false;
    }

    // GPR writeback from the commit log records:
    //   key = (rd << 4) | type, type 0 = integer register
    for (const auto &kv : st->log_reg_write)
    {
        if ((kv.first & 0xFu) != 0u)
            continue;                       // FPR (|1) / CSR (|4) entries
        reg_t rd = kv.first >> 4;
        if (rd == 0)
            break;                          // x0 writes are discarded
        c.rd_wr  = true;
        c.rd     = (uint32_t)rd;
        c.rd_val = (uint32_t)kv.second.v[0];
        break;
    }
    return true;
}

//--------------------------------------------------------------------
// verifier
//--------------------------------------------------------------------
verifier::verifier()
{
    m_mode         = verify_mode::OFF;
    m_compared     = 0;
    m_mismatches   = 0;
    m_fail_fast    = false;
    m_ref_eof      = false;
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
                      const std::vector<mem_patch> *patches)
{
    m_mode = mode;
    if (m_mode == verify_mode::OFF)
        return true;

#ifndef TB_STATE_DUMP
    logger::inst().error("verification needs a STATE_DUMP=1 build (public model internals)");
    m_mode = verify_mode::OFF;
    return false;
#else
    if (!m_spike.start(elf, isa, patches))
    {
        logger::inst().error("cannot start the in-process Spike model: " + m_spike.error());
        m_mode = verify_mode::OFF;
        return false;
    }
    logger::inst().info(std::string("Verification: ") +
                        (m_mode == verify_mode::INCREMENTAL ? "INCREMENTAL" : "BATCH") +
                        " (in-process Spike lockstep, isa: " + isa + ")");
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
        if (m_spike.error().empty() == false)
            logger::inst().error("VERIFY: reference model error: " + m_spike.error());
        return false;
    }
    return true;
}

//--------------------------------------------------------------------
// step_exception: the DUT retired a faulting instruction; step the
// reference through the same instruction and only check PC alignment
// (Spike takes the trap within the same step, no commit semantics)
//--------------------------------------------------------------------
void verifier::step_exception(const retire_event &ev)
{
    ref_commit ref;
    if (!fetch_ref(ref))
    {
        logger::inst().error("VERIFY: reference model stopped at exception, cycle " +
                             std::to_string(ev.cycle));
        m_mismatches++;
        m_fail_fast = true;
        return;
    }
    if (ref.pc != ev.pc)
    {
        note_desync(ev, ref);
        m_fail_fast = true;
        return;
    }
    if (m_verbose_file != NULL)
        print_skip(ev);
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
            snprintf(dut_rd, sizeof(dut_rd), "x%u(%s)=0x%08x",
                     (unsigned)ev.rd, abi_name(ev.rd), ev.rd_val);
        else
            snprintf(dut_rd, sizeof(dut_rd), "-");

        if (ref.rd_wr)
            snprintf(ref_rd, sizeof(ref_rd), "x%u(%s)=0x%08x",
                     (unsigned)ref.rd, abi_name(ref.rd), ref.rd_val);
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
// note_desync: exception-path PC alignment broken
//--------------------------------------------------------------------
void verifier::note_desync(const retire_event &ev, const ref_commit &ref)
{
    char buf[256];
    snprintf(buf, sizeof(buf),
             "VERIFY desync at cycle %llu: DUT exception at pc=0x%08x, "
             "reference at pc=0x%08x",
             (unsigned long long)ev.cycle, ev.pc, ref.pc);
    m_mismatches++;
    if (m_mismatches <= MAX_REPORTED)
        logger::inst().error(buf);
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
        if (ev.rd != ref.rd)         return "rd index mismatch";
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
        snprintf(dut_rd, sizeof(dut_rd), "x%u(%s)=0x%08x",
                 (unsigned)ev.rd, abi_name(ev.rd), ev.rd_val);
    else
        snprintf(dut_rd, sizeof(dut_rd), "-");

    if (ref.rd_wr)
        snprintf(ref_rd, sizeof(ref_rd), "x%u(%s)=0x%08x",
                 (unsigned)ref.rd, abi_name(ref.rd), ref.rd_val);
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
            "-> SKIP (exception, stepped in reference without compare)\n",
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

    if (m_mode == verify_mode::BATCH)
    {
        m_events.push_back(ev);
        return;
    }

    // INCREMENTAL: lockstep compare, fail fast
    if (m_fail_fast)
        return;

    // Faulting instructions: step the reference in lockstep but skip
    // the value comparison (no commit semantics for traps)
    if (ev.exc)
    {
        step_exception(ev);
        return;
    }

    ref_commit ref;
    if (!fetch_ref(ref))
    {
        logger::inst().error("VERIFY: reference model stopped at cycle " +
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
// releases the reference model.
//--------------------------------------------------------------------
uint64_t verifier::finish(void)
{
    if (m_mode == verify_mode::BATCH)
    {
        for (size_t i = 0; i < m_events.size(); ++i)
        {
            if (m_fail_fast)
                break;

            if (m_events[i].exc)
            {
                step_exception(m_events[i]);
                continue;
            }

            ref_commit ref;
            if (!fetch_ref(ref))
            {
                if (m_mismatches < MAX_REPORTED)
                    logger::inst().error("VERIFY: reference stopped after " +
                                         std::to_string(m_compared) + " commits, " +
                                         std::to_string(m_events.size() - i) +
                                         " DUT events left uncompared");
                m_mismatches += (m_events.size() - i);
                break;
            }
            compare_and_report(m_events[i], ref);
            if (m_mismatches > 0)
                m_fail_fast = true;
        }
        if (m_verbose_file != NULL)
            fflush(m_verbose_file);
    }

    m_spike.stop();
    return m_mismatches;
}
