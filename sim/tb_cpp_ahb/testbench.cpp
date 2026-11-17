#include <cstdlib>
#include <iomanip>
#include <iostream>

#include "elf_load.h"
#include "logger.h"
#include "testbench.h"

//--------------------------------------------------------------------
// Construction
//--------------------------------------------------------------------
testbench::testbench():
    m_top(std::make_unique<Vscr1_top_ahb>()),
    m_mem(1024 * 1024),
    m_time(0),
    m_cycle(0),
    m_entry_point(0)
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

#ifndef TB_NO_IPIC
    m_top->irq_lines = 0;
#else
    m_top->ext_irq   = 0;
#endif
    m_top->soft_irq  = 0;

    // Reset asserted
    m_top->pwrup_rst_n = 0;
    m_top->rst_n       = 0;
    m_top->cpu_rst_n   = 0;

    // Default slave response
    m_top->imem_hready = 1;
    m_top->imem_hrdata = 0;
    m_top->imem_hresp  = 0;
    m_top->dmem_hready = 1;
    m_top->dmem_hrdata = 0;
    m_top->dmem_hresp  = 0;

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
// tick: one full clock cycle.
//
// Ordering replicates RTL semantics. After the posedge eval the memory
// model state is updated and its outputs are re-driven while clk is
// still high, followed by a settling eval (no edge). This guarantees
// that:
//  - clocked processes (incl. @(negedge clk) SVA) always sample
//    combinationally consistent values, never a stale hresp against
//    the DUT's new FSM state;
//  - the VCD only shows settled values.
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

    // Slave state advances on the same edge, using the pre-edge bus samples
    m_mem.posedge();

    // Drive slave outputs from the NEW state and re-settle combinational
    // logic with clk still high (no edge event)
    ahb_slave_ports is;
    ahb_slave_ports ds;
    m_mem.drive_outputs(is, ds);

    m_top->imem_hready = is.hready;
    m_top->imem_hrdata = is.hrdata;
    m_top->imem_hresp  = is.hresp;
    m_top->dmem_hready = ds.hready;
    m_top->dmem_hrdata = ds.hrdata;
    m_top->dmem_hresp  = ds.hresp;

    // IRQ registers owned by the memory model
#ifndef TB_NO_IPIC
    m_top->irq_lines = m_mem.irq_lines();
#else
    m_top->ext_irq   = m_mem.irq_lines() & 1u;
#endif
    m_top->soft_irq  = m_mem.soft_irq();

    m_top->eval();
    m_time += CLK_HALF_PERIOD;
    dump();

    // Negedge: clocked SVA samples the consistent settled values
    m_top->clk = 0;
    m_top->eval();
    m_time += CLK_HALF_PERIOD;
    dump();

    // Sample AHB master outputs: bus values presented at the next posedge
    ahb_master_ports im;
    im.htrans = m_top->imem_htrans;
    im.haddr  = m_top->imem_haddr;
    im.hsize  = m_top->imem_hsize;

    ahb_master_ports dm;
    dm.htrans = m_top->dmem_htrans;
    dm.haddr  = m_top->dmem_haddr;
    dm.hsize  = m_top->dmem_hsize;
    dm.hwrite = m_top->dmem_hwrite;
    dm.hwdata = m_top->dmem_hwdata;

    m_mem.sample_inputs(im, dm);

#ifdef TB_DEBUG_AHB
    if (m_cycle < 120)
    {
        std::cout << "cyc " << std::dec << std::setw(3) << std::setfill(' ') << m_cycle
                  << " rst " << (int)m_top->rst_n
                  << std::hex
                  << " | I: tr " << (unsigned)im.htrans
                  << " ad " << std::setw(8) << std::setfill('0') << im.haddr
                  << " rd " << std::setw(8) << is.hrdata
                  << std::setfill(' ') << std::dec << " rdy " << (int)is.hready
                  << std::hex
                  << " | D: tr " << (unsigned)dm.htrans
                  << " ad " << std::setw(8) << std::setfill('0') << dm.haddr
                  << std::setfill(' ') << std::dec << " wr " << (int)dm.hwrite
                  << std::hex
                  << " wd " << std::setw(8) << std::setfill('0') << dm.hwdata
                  << " rd " << std::setw(8) << ds.hrdata
                  << std::setfill(' ') << std::dec << " rdy " << (int)ds.hready
                  << " rs " << (int)ds.hresp
                  << std::hex << " | irq " << std::setw(4) << std::setfill('0') << m_mem.irq_lines()
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
// waves_enabled
//--------------------------------------------------------------------
bool testbench::waves_enabled(void)
{
    char *s = getenv("ENABLE_WAVES");
    if (s && !strcmp(s, "no"))
        return false;
    return true;
}
