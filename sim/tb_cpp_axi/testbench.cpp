#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <iostream>

#include "boot_stub.h"
#include "elf_load.h"
#include "logger.h"
#include "state_dump.h"
#include "testbench.h"

//--------------------------------------------------------------------
// Construction
//--------------------------------------------------------------------
testbench::testbench():
    m_top(std::make_unique<Vscr1_top_axi>()),
    m_mem(1024 * 1024),
    m_time(0),
    m_cycle(0),
    m_entry_point(0),
    m_gp_sym(0)
#if VM_TRACE
    ,
    m_tfp(nullptr),
    m_trace_start(0),
    m_trace_on(false)
#endif
{
    // Static inputs
    m_top->test_mode  = 0;
    m_top->test_rst_n = 1;
    m_top->clk        = 0;
    m_top->rtc_clk    = 0;

    m_top->fuse_mhartid = 0;
#ifndef TB_NO_DBG
    m_top->fuse_idcode = 0xDEB11001;    // `SCR1_TAP_IDCODE
    m_top->trst_n      = 0;
    m_top->tck         = 0;
    m_top->tms         = 0;
    m_top->tdi         = 0;
#endif

    // AXI sideband inputs
    m_top->io_axi_imem_buser = 0;
    m_top->io_axi_imem_ruser = 0;
    m_top->io_axi_dmem_buser = 0;
    m_top->io_axi_dmem_ruser = 0;

    // Reset asserted
    m_top->pwrup_rst_n = 0;
    m_top->rst_n       = 0;
    m_top->cpu_rst_n   = 0;

    // Slave outputs (registered defaults of the memory model)
    drive_bus();

    m_top->eval();
}

//--------------------------------------------------------------------
// Destruction
//--------------------------------------------------------------------
testbench::~testbench()
{
    abort();
    if (m_top)
        m_top->final();
}

//--------------------------------------------------------------------
// load_elf
//--------------------------------------------------------------------
bool testbench::load_elf(const char *filename)
{
    elf_load elf(filename, &m_mem);
    if (!elf.load())
        return false;
    m_entry_point = elf.get_entry_point();
    // C-family marker: crt sets gp = __global_pointer$ at startup
    elf.get_symbol("__global_pointer$", m_gp_sym);

    m_spike_patches = elf.patches();
    if (elf.is_relocatable())
    {
        // Raw snippy image: synthesize the boot wrapper at the reset
        // vector and mirror everything into the reference model patches
        for (const auto &w : make_boot_stub(m_entry_point))
        {
            mem_patch p;
            p.addr = w.addr;
            p.data.resize(4);
            for (int b = 0; b < 4; b++)
            {
                uint8_t byte = (uint8_t)(w.word >> (8 * b));
                m_mem.write(w.addr + (uint32_t)b, byte);
                p.data[b] = byte;
            }
            m_spike_patches.push_back(std::move(p));
        }

        std::ostringstream ss;
        ss << "Snippy mode: boot wrapper at 0x200, entry=0x"
           << std::hex << std::setw(8) << std::setfill('0') << m_entry_point;
        logger::inst().info(ss.str());
    }
    return true;
}

//--------------------------------------------------------------------
// update_resets: native-like reset sequence
//--------------------------------------------------------------------
void testbench::update_resets(void)
{
    bool rst = (m_cycle < RESET_CYCLES) ? false : true;
    m_top->pwrup_rst_n = rst;
    m_top->rst_n       = rst;
    m_top->cpu_rst_n   = rst;

#ifndef TB_NO_DBG
    m_top->trst_n = (m_cycle < TRST_CYCLES) ? 0 : 1;
#endif
}

//--------------------------------------------------------------------
// sample_bus: capture DUT AXI master outputs (pre-posedge values)
//--------------------------------------------------------------------
void testbench::sample_bus(void)
{
    axi_m2s &im = m_mem.bus_in(tb_axi_mem::IF_IMEM);
    im.awvalid = m_top->io_axi_imem_awvalid;
    im.awid    = m_top->io_axi_imem_awid;
    im.awaddr  = m_top->io_axi_imem_awaddr;
    im.awsize  = m_top->io_axi_imem_awsize;
    im.awlen   = m_top->io_axi_imem_awlen;
    im.wvalid  = m_top->io_axi_imem_wvalid;
    im.wdata   = m_top->io_axi_imem_wdata;
    im.wstrb   = m_top->io_axi_imem_wstrb;
    im.wlast   = m_top->io_axi_imem_wlast;
    im.bready  = m_top->io_axi_imem_bready;
    im.arvalid = m_top->io_axi_imem_arvalid;
    im.arid    = m_top->io_axi_imem_arid;
    im.araddr  = m_top->io_axi_imem_araddr;
    im.arsize  = m_top->io_axi_imem_arsize;
    im.arlen   = m_top->io_axi_imem_arlen;
    im.rready  = m_top->io_axi_imem_rready;

    axi_m2s &dm = m_mem.bus_in(tb_axi_mem::IF_DMEM);
    dm.awvalid = m_top->io_axi_dmem_awvalid;
    dm.awid    = m_top->io_axi_dmem_awid;
    dm.awaddr  = m_top->io_axi_dmem_awaddr;
    dm.awsize  = m_top->io_axi_dmem_awsize;
    dm.awlen   = m_top->io_axi_dmem_awlen;
    dm.wvalid  = m_top->io_axi_dmem_wvalid;
    dm.wdata   = m_top->io_axi_dmem_wdata;
    dm.wstrb   = m_top->io_axi_dmem_wstrb;
    dm.wlast   = m_top->io_axi_dmem_wlast;
    dm.bready  = m_top->io_axi_dmem_bready;
    dm.arvalid = m_top->io_axi_dmem_arvalid;
    dm.arid    = m_top->io_axi_dmem_arid;
    dm.araddr  = m_top->io_axi_dmem_araddr;
    dm.arsize  = m_top->io_axi_dmem_arsize;
    dm.arlen   = m_top->io_axi_dmem_arlen;
    dm.rready  = m_top->io_axi_dmem_rready;
}

//--------------------------------------------------------------------
// drive_bus: apply registered memory model outputs to the DUT inputs
//--------------------------------------------------------------------
void testbench::drive_bus(void)
{
    const axi_s2m &im = m_mem.bus_out(tb_axi_mem::IF_IMEM);
    m_top->io_axi_imem_awready = im.awready;
    m_top->io_axi_imem_wready  = im.wready;
    m_top->io_axi_imem_bvalid  = im.bvalid;
    m_top->io_axi_imem_bid     = im.bid;
    m_top->io_axi_imem_bresp   = im.bresp;
    m_top->io_axi_imem_arready = im.arready;
    m_top->io_axi_imem_rvalid  = im.rvalid;
    m_top->io_axi_imem_rid     = im.rid;
    m_top->io_axi_imem_rdata   = im.rdata;
    m_top->io_axi_imem_rlast   = im.rlast;
    m_top->io_axi_imem_rresp   = im.rresp;

    const axi_s2m &dm = m_mem.bus_out(tb_axi_mem::IF_DMEM);
    m_top->io_axi_dmem_awready = dm.awready;
    m_top->io_axi_dmem_wready  = dm.wready;
    m_top->io_axi_dmem_bvalid  = dm.bvalid;
    m_top->io_axi_dmem_bid     = dm.bid;
    m_top->io_axi_dmem_bresp   = dm.bresp;
    m_top->io_axi_dmem_arready = dm.arready;
    m_top->io_axi_dmem_rvalid  = dm.rvalid;
    m_top->io_axi_dmem_rid     = dm.rid;
    m_top->io_axi_dmem_rdata   = dm.rdata;
    m_top->io_axi_dmem_rlast   = dm.rlast;
    m_top->io_axi_dmem_rresp   = dm.rresp;

    // IRQ registers owned by the memory model
#ifndef TB_NO_IPIC
    m_top->irq_lines = m_mem.irq_lines();
#else
    m_top->ext_irq   = m_mem.irq_lines() & 1u;
#endif
    m_top->soft_irq  = m_mem.soft_irq();
}

//--------------------------------------------------------------------
// dump: VCD trace
//--------------------------------------------------------------------
void testbench::dump(void)
{
#if VM_TRACE
    if (m_trace_on && m_tfp && (m_time >= m_trace_start))
        m_tfp->dump(m_time);
#endif
}

//--------------------------------------------------------------------
// tick: one full clock cycle (same eval ordering as the AHB variant)
//--------------------------------------------------------------------
void testbench::tick(void)
{
    update_resets();

    // rtc_clk: 1 MHz against 100 MHz system clock
    if ((m_cycle % RTC_CLK_DIV) == 0)
        m_top->rtc_clk = !m_top->rtc_clk;

    // Posedge: DUT latches the bus sampled at the end of the previous tick
    m_top->clk = 1;
    m_top->eval();

    // Slave registers advance on the same edge, using the pre-edge samples
    m_mem.posedge();

    // Execution tracer / verifier consume the pre-edge internal samples too
    if (m_trace.events_enabled())
        m_trace.posedge(m_trace_in);

    // Drive the new slave outputs and re-settle combinational logic
    // with clk still high (no edge event)
    drive_bus();
    m_top->eval();
    m_time += CLK_HALF_PERIOD;
    dump();

    // Negedge: clocked SVA samples the consistent settled values
    m_top->clk = 0;
    m_top->eval();
    m_time += CLK_HALF_PERIOD;
    dump();

    // Sample the bus presented at the next posedge
    sample_bus();

    // Sample DUT internals for the tracer/verifier (pre-posedge values)
    if (m_trace.events_enabled())
        trace_logger::capture(m_top.get(), m_trace_in);

#ifdef TB_DEBUG_AXI
    if (m_cycle < 120)
    {
        const axi_m2s &im = m_mem.bus_in(tb_axi_mem::IF_IMEM);
        const axi_m2s &dm = m_mem.bus_in(tb_axi_mem::IF_DMEM);
        const axi_s2m &io = m_mem.bus_out(tb_axi_mem::IF_IMEM);
        const axi_s2m &doo = m_mem.bus_out(tb_axi_mem::IF_DMEM);
        std::cout << "cyc " << std::dec << std::setw(3) << std::setfill(' ') << m_cycle
                  << " rst " << (int)m_top->rst_n
                  << std::hex
                  << " | I: ar " << (int)im.arvalid << " ad " << std::setw(8) << std::setfill('0') << im.araddr
                  << std::setfill(' ') << " rd " << (int)io.arready
                  << " rv " << (int)io.rvalid << " da " << std::setw(8) << std::setfill('0') << io.rdata
                  << std::setfill(' ') << " rr " << (int)im.rready
                  << " | D: aw " << (int)dm.awvalid << " ad " << std::setw(8) << std::setfill('0') << dm.awaddr
                  << " w " << (int)dm.wvalid << " da " << std::setw(8) << std::setfill('0') << dm.wdata
                  << " st " << std::setw(1) << (unsigned)dm.wstrb
                  << std::setfill(' ') << " br " << (int)doo.bvalid << "/" << (int)dm.bready
                  << " ar " << (int)dm.arvalid << " rv " << (int)doo.rvalid
                  << std::dec
                  << " | irq " << std::hex << std::setw(4) << std::setfill('0') << m_mem.irq_lines()
                  << std::setfill(' ') << std::dec << " s " << (int)m_mem.soft_irq()
                  << std::endl;
    }
#endif
    m_cycle++;
}

//--------------------------------------------------------------------
// run: main loop. Returns 0 on test exit, 1 on timeout.
//--------------------------------------------------------------------
int testbench::run(uint64_t max_cycles)
{
    while (m_cycle < max_cycles)
    {
        tick();

        if (m_verify.failed())
            return 2;

        if (m_mem.exit_detected())
            return 0;

        if (Verilated::gotFinish())
            return 0;
    }
    return 1;
}

//--------------------------------------------------------------------
// abort: flush and close trace
//--------------------------------------------------------------------
void testbench::abort(void)
{
    m_trace.close();
#if VM_TRACE
    if (m_tfp)
    {
        m_tfp->flush();
        m_tfp->close();
        m_tfp.reset();
    }
    m_trace_on = false;
#endif
}

//--------------------------------------------------------------------
// trace_enable
//--------------------------------------------------------------------
void testbench::trace_enable(const char *vcd_name)
{
#if VM_TRACE
    Verilated::traceEverOn(true);
    m_tfp = std::make_unique<VerilatedVcdC>();
    m_top->trace(m_tfp.get(), 99);
    m_tfp->open(vcd_name);
    m_trace_on = true;
#else
    (void)vcd_name;
    logger::inst().warning("model built without tracing support");
#endif
}

//--------------------------------------------------------------------
// set_trace_delay_us
//--------------------------------------------------------------------
void testbench::set_trace_delay_us(uint32_t us)
{
#if VM_TRACE
    m_trace_start = (uint64_t)us * 1000ull;
    logger::inst().info("WAVES: Delay start until " + std::to_string(us) + "uS");
#else
    (void)us;
#endif
}

//--------------------------------------------------------------------
// capture_state
//--------------------------------------------------------------------
void testbench::capture_state(scr1_state &st) const
{
    state_dump::capture(m_top.get(), st);
}

//--------------------------------------------------------------------
// result_a0: test return code convention (0 = pass)
//--------------------------------------------------------------------
uint32_t testbench::result_a0(void) const
{
    return state_dump::read_gpr(m_top.get(), 10);
}

//--------------------------------------------------------------------
// result_gp: riscv-tests TESTNUM register
//--------------------------------------------------------------------
uint32_t testbench::result_gp(void) const
{
    return state_dump::read_gpr(m_top.get(), 3);
}

//--------------------------------------------------------------------
// trace_log_enable
//--------------------------------------------------------------------
bool testbench::trace_log_enable(const char *path)
{
    return m_trace.open(path);
}

//--------------------------------------------------------------------
// verify_enable: start Spike and attach the verifier to the
// retirement stream of the trace logger
//--------------------------------------------------------------------
bool testbench::verify_enable(verify_mode mode, const char *elf,
                              const char *isa)
{
    if (!m_verify.enable(mode, elf, isa,
                         m_spike_patches.empty() ? NULL : &m_spike_patches))
        return false;
    if (m_verify.active())
        m_trace.set_listener(&m_verify);
    return true;
}

//--------------------------------------------------------------------
// waves_enabled
//--------------------------------------------------------------------
bool testbench::waves_enabled(void)
{
    char *s = getenv("ENABLE_WAVES");
    if (s && !strcmp(s, "no"))
        return false;
    return true;
}
