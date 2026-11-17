#include <cstdlib>
#include <cstring>
#include <iostream>

#include "tb_axi_mem.h"

//--------------------------------------------------------------------
// Constructor
//--------------------------------------------------------------------
tb_axi_mem::tb_axi_mem(uint32_t size)
{
    m_size          = size;
    m_mem.resize(size, 0);
    m_irq_lines_reg = 0;
    m_soft_irq_reg  = false;
    m_exit_detected = false;
    m_print_count   = 0;
}

//--------------------------------------------------------------------
// mem_api: backdoor access (ELF loading)
//--------------------------------------------------------------------
bool tb_axi_mem::create_memory(uint32_t addr, uint32_t size, uint8_t *mem)
{
    (void)mem;
    return ((uint64_t)addr + size) <= (uint64_t)m_size;
}

bool tb_axi_mem::valid_addr(uint32_t addr)
{
    return addr < m_size;
}

void tb_axi_mem::write(uint32_t addr, uint8_t data)
{
    if (addr < m_size)
        m_mem[addr] = data;
}

uint8_t tb_axi_mem::read(uint32_t addr)
{
    return (addr < m_size) ? m_mem[addr] : 0;
}

//--------------------------------------------------------------------
// mem_read_fn: native mem_read() function port.
// Service address matching uses adr[31:1] comparison, as in SV.
//--------------------------------------------------------------------
uint32_t tb_axi_mem::mem_read_fn(uint32_t adr, uint32_t bytes_num)
{
    uint32_t r    = 0;
    uint32_t lane = adr & 3u;

    for (uint32_t i = lane; (i < 4u) && (bytes_num != 0); ++i)
    {
        if ((adr & ~1u) == (SCR1_SIM_SOFT_IRQ_ADDR & ~1u))
        {
            // Reading Soft IRQ value
            r |= (m_soft_irq_reg ? 1u : 0u);
        }
        else if ((adr & ~1u) == (SCR1_SIM_EXT_IRQ_ADDR & ~1u))
        {
            // Reading IRQ Lines values
            if ((i * 8u) < 16u)
                r |= ((uint32_t)(m_irq_lines_reg >> (i * 8u)) & 0xFFu) << (i * 8u);
        }
        else
        {
            // Regular read operation
            r |= ((adr < m_size) ? (uint32_t)m_mem[adr] : 0u) << (i * 8u);
        }

        adr++;
        bytes_num--;
    }
    return r;
}

//--------------------------------------------------------------------
// mem_write_fn: native mem_write() function port
//--------------------------------------------------------------------
void tb_axi_mem::mem_write_fn(uint32_t adr, uint32_t data, uint8_t strb, uint32_t bytes_num)
{
    uint32_t lane = adr & 3u;

    for (uint32_t i = lane; (i < 4u) && (bytes_num != 0); ++i)
    {
        uint8_t byte = (uint8_t)((data >> (i * 8u)) & 0xFFu);
        bool    en   = ((strb >> i) & 1u) != 0;

        if (en && (adr == SCR1_SIM_PRINT_ADDR))
        {
            // Printing character in the simulation console
            std::cout.put((char)byte);
            std::cout.flush();
            m_print_count++;
        }
        else if (((strb & 1u) != 0) && ((adr & ~1u) == (SCR1_SIM_SOFT_IRQ_ADDR & ~1u)))
        {
            // Writing Soft IRQ value
            m_soft_irq_reg = (data & 1u) != 0;
        }
        else if (en && ((adr & ~1u) == (SCR1_SIM_EXT_IRQ_ADDR & ~1u)))
        {
            // Writing IRQ Lines values
            if ((i * 8u) < 16u)
            {
                uint16_t mask = (uint16_t)(0xFFu << (i * 8u));
                m_irq_lines_reg = (uint16_t)((m_irq_lines_reg & ~mask) |
                                             ((uint16_t)(byte << (i * 8u)) & mask));
            }
        }
        else if (en)
        {
            // Regular write operation
            if (adr < m_size)
                m_mem[adr] = byte;
        }

        adr++;
        bytes_num--;
    }
}

//--------------------------------------------------------------------
// rd_posedge: read channels FSM (native "Read operation" always block).
// All conditions use the pre-edge snapshot `o` (NBA semantics),
// updates go to `n` (the live output registers).
//--------------------------------------------------------------------
void tb_axi_mem::rd_posedge(axi_if &f, bool detect_exit)
{
    const axi_m2s &in = f.in;
    const axi_s2m  o  = f.out;    // pre-edge snapshot
    axi_s2m       &n  = f.out;    // next state

    // Read data: acked
    if (o.rvalid && in.rready)
    {
        n.arready = true;
        n.rvalid  = false;
    }
    else if (o.rvalid && !in.rready)
    {
        n.arready = false;
    }

    // Read data: valid
    if (in.arvalid && o.arready && !(o.rvalid && !in.rready))
    {
        n.rvalid = true;
        n.rresp  = AXI_RESP_OKAY;
        n.rlast  = true;
        n.rid    = in.arid;
        n.rdata  = mem_read_fn(in.araddr, 1u << in.arsize);

        // Test completion: core fetches the SIM_STOP self-jump
        if (detect_exit && ((in.araddr & ~3u) == SCR1_SIM_EXIT_ADDR))
            m_exit_detected = true;
    }
}

//--------------------------------------------------------------------
// wr_posedge: write channels FSM (native "Write operation" always
// block). Same NBA discipline as rd_posedge.
//--------------------------------------------------------------------
void tb_axi_mem::wr_posedge(axi_if &f)
{
    const axi_m2s &in = f.in;
    const axi_s2m  o  = f.out;    // pre-edge snapshot
    axi_s2m       &n  = f.out;    // next state

    // Write data: response
    if (o.bvalid && in.bready)
    {
        n.bvalid  = false;
        n.awready = true;
        n.wready  = true;
    }
    else if (o.bvalid && !in.bready)
    {
        n.awready = false;
        n.wready  = false;
    }

    // Write data: get address
    if (in.awvalid && o.awready && !(o.bvalid && !in.bready))
    {
        n.bid = in.awid;
        if (!in.wvalid)
        {
            f.awaddr_hold = in.awaddr;
            f.awsize_hold = in.awsize;
            n.awready     = false;
        }
    }

    // Write data: get data
    if (in.wvalid && o.wready && in.wlast)
    {
        n.bvalid = true;
        n.bresp  = AXI_RESP_OKAY;

        mem_write_fn(o.awready ? in.awaddr : f.awaddr_hold,
                     in.wdata,
                     in.wstrb,
                     1u << (o.awready ? in.awsize : f.awsize_hold));
    }
}

//--------------------------------------------------------------------
// posedge: advance both interfaces. Reads are processed before writes
// so that service registers keep their pre-edge values for reads,
// matching the NBA semantics of the native model.
//--------------------------------------------------------------------
void tb_axi_mem::posedge(void)
{
    rd_posedge(m_if[IF_IMEM], true);
    rd_posedge(m_if[IF_DMEM], false);

    wr_posedge(m_if[IF_IMEM]);
    wr_posedge(m_if[IF_DMEM]);
}
