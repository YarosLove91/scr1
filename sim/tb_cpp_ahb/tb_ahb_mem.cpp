#include <cstdlib>
#include <cstring>
#include <iostream>

#include "tb_ahb_mem.h"

#define AHB_STATE_IDLE  0
#define AHB_STATE_DATA  1
#define AHB_STATE_ERR   2

//--------------------------------------------------------------------
// Constructor
//--------------------------------------------------------------------
tb_ahb_mem::tb_ahb_mem(uint32_t size)
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
bool tb_ahb_mem::create_memory(uint32_t addr, uint32_t size, uint8_t *mem)
{
    (void)mem;
    return ((uint64_t)addr + size) <= (uint64_t)m_size;
}

bool tb_ahb_mem::valid_addr(uint32_t addr)
{
    return addr < m_size;
}

void tb_ahb_mem::write(uint32_t addr, uint8_t data)
{
    if (addr < m_size)
        m_mem[addr] = data;
}

uint8_t tb_ahb_mem::read(uint32_t addr)
{
    return (addr < m_size) ? m_mem[addr] : 0;
}

//--------------------------------------------------------------------
// Byte enables (scr1_be_form)
//--------------------------------------------------------------------
uint8_t tb_ahb_mem::be_form(uint8_t offset, uint8_t hsize)
{
    switch (hsize)
    {
        case SCR1_HSIZE_8B:  return (uint8_t)(0x1 << offset) & 0xF;
        case SCR1_HSIZE_16B: return (uint8_t)(0x3 << offset) & 0xF;
        case SCR1_HSIZE_32B: return 0xF;
        default:             return 0xF;
    }
}

//--------------------------------------------------------------------
// Aligned word access with byte enables
//--------------------------------------------------------------------
uint32_t tb_ahb_mem::read_word(uint32_t addr, uint8_t be)
{
    uint32_t tmp = 0;
    addr &= ~3u;
    for (int i = 0; i < 4; i++)
    {
        if (be & (1u << i))
        {
            uint32_t a = addr + i;
            tmp |= ((a < m_size) ? (uint32_t)m_mem[a] : 0u) << (8 * i);
        }
    }
    return tmp;
}

void tb_ahb_mem::write_word(uint32_t addr, uint8_t be, uint32_t data)
{
    addr &= ~3u;
    for (int i = 0; i < 4; i++)
    {
        if (be & (1u << i))
        {
            uint32_t a = addr + i;
            if (a < m_size)
                m_mem[a] = (uint8_t)(data >> (8 * i));
        }
    }
}

//--------------------------------------------------------------------
// Stall pattern rotation (native imem/dmem_req_ack_stall)
//--------------------------------------------------------------------
void tb_ahb_mem::rotate_stall(channel &ch)
{
    if (ch.req_ack_stall == 0)
    {
        ch.req_ack_rnd = (rand() & 1) != 0;
    }
    else
    {
        if ((ch.state == AHB_STATE_DATA) || !(ch.req_ack_stall & 1u))
            ch.req_ack_stall = ((ch.req_ack_stall & 1u) << 31) | (ch.req_ack_stall >> 1);
    }
}

//--------------------------------------------------------------------
// sample_inputs: capture DUT master outputs (address/data phase bus
// values presented at the coming posedge)
//--------------------------------------------------------------------
void tb_ahb_mem::sample_inputs(const ahb_master_ports &imem, const ahb_master_ports &dmem)
{
    m_imem_in = imem;
    m_dmem_in = dmem;
}

//--------------------------------------------------------------------
// drive_outputs: combinational slave response from registered state
//--------------------------------------------------------------------
void tb_ahb_mem::drive_outputs(ahb_slave_ports &imem, ahb_slave_ports &dmem)
{
    // imem: hready is always 1 in the native model
    imem.hready = true;
    imem.hresp  = SCR1_HRESP_OKAY;
    imem.hrdata = 0;
    if ((m_imem.state == AHB_STATE_DATA) && m_imem.req_ack())
        imem.hrdata = m_imem.hrdata_l;

    // dmem
    dmem.hready = false;
    dmem.hresp  = SCR1_HRESP_ERROR;
    dmem.hrdata = 0;
    switch (m_dmem.state)
    {
        case AHB_STATE_IDLE:
            if (m_dmem.req_ack())
                dmem.hready = true;
            break;
        case AHB_STATE_DATA:
            if (m_dmem.req_ack())
            {
                dmem.hready = true;
                dmem.hresp  = SCR1_HRESP_OKAY;
                if (!m_dmem.wr)
                    dmem.hrdata = m_dmem.hrdata_l;
            }
            break;
        default:
            break;
    }
}

//--------------------------------------------------------------------
// posedge: FSM update, write commit, address/data latch
//--------------------------------------------------------------------
void tb_ahb_mem::posedge(void)
{
    bool imem_ack = m_imem.req_ack();
    bool dmem_ack = m_dmem.req_ack();

    //----------------------------------------------------------------
    // dmem: write commit of the current data phase (before relatch)
    //----------------------------------------------------------------
    if ((m_dmem.state == AHB_STATE_DATA) && dmem_ack && m_dmem.wr)
    {
        uint32_t hwdata = m_dmem_in.hwdata;
        switch (m_dmem.addr)
        {
            case SCR1_SIM_PRINT_ADDR:
                std::cout.put((char)(hwdata & 0xFF));
                std::cout.flush();
                m_print_count++;
                break;
            case SCR1_SIM_SOFT_IRQ_ADDR:
                m_soft_irq_reg = (hwdata & 1u) != 0;
                break;
            case SCR1_SIM_EXT_IRQ_ADDR:
                m_irq_lines_reg = (uint16_t)(hwdata & 0xFFFFu);
                break;
            default:
                write_word(m_dmem.addr, m_dmem.be, hwdata);
                break;
        }
    }

    //----------------------------------------------------------------
    // imem: FSM + latch
    //----------------------------------------------------------------
    {
        uint8_t next_state = m_imem.state;
        bool    do_latch   = false;

        switch (m_imem.state)
        {
            case AHB_STATE_IDLE:
                if (m_imem_in.htrans == SCR1_HTRANS_NONSEQ)
                {
                    next_state = AHB_STATE_DATA;
                    do_latch   = true;
                }
                else if (m_imem_in.htrans == SCR1_HTRANS_IDLE)
                {
                    next_state = AHB_STATE_IDLE;
                }
                else
                {
                    next_state = AHB_STATE_ERR;
                }
                break;
            case AHB_STATE_DATA:
                if (imem_ack)
                {
                    if (m_imem_in.htrans == SCR1_HTRANS_NONSEQ)
                    {
                        next_state = AHB_STATE_DATA;
                        do_latch   = true;
                    }
                    else if (m_imem_in.htrans == SCR1_HTRANS_IDLE)
                    {
                        next_state = AHB_STATE_IDLE;
                    }
                    else
                    {
                        next_state = AHB_STATE_ERR;
                    }
                }
                break;
            default:
                next_state = AHB_STATE_ERR;
                break;
        }

        if (do_latch)
        {
            m_imem.addr     = m_imem_in.haddr;
            m_imem.size     = m_imem_in.hsize;
            m_imem.be       = be_form(0, m_imem_in.hsize);
            m_imem.hrdata_l = read_word(m_imem_in.haddr, m_imem.be);

            // Test completion: core fetches the SIM_STOP self-jump
            if ((m_imem_in.haddr & ~3u) == SCR1_SIM_EXIT_ADDR)
                m_exit_detected = true;
        }

        m_imem.state = next_state;
    }

    //----------------------------------------------------------------
    // dmem: FSM + latch
    //----------------------------------------------------------------
    {
        uint8_t next_state = m_dmem.state;
        bool    do_latch   = false;

        switch (m_dmem.state)
        {
            case AHB_STATE_IDLE:
                if (m_dmem_in.htrans == SCR1_HTRANS_NONSEQ)
                {
                    next_state = AHB_STATE_DATA;
                    do_latch   = true;
                }
                else if (m_dmem_in.htrans == SCR1_HTRANS_IDLE)
                {
                    next_state = AHB_STATE_IDLE;
                }
                else
                {
                    next_state = AHB_STATE_ERR;
                }
                break;
            case AHB_STATE_DATA:
                if (dmem_ack)
                {
                    if (m_dmem_in.htrans == SCR1_HTRANS_NONSEQ)
                    {
                        if (!m_dmem_in.hwrite &&
                            ((m_dmem_in.haddr == SCR1_SIM_SOFT_IRQ_ADDR) ||
                             (m_dmem_in.haddr == SCR1_SIM_EXT_IRQ_ADDR)))
                        {
                            // Skip access, switch to IDLE (native quirk)
                            next_state = AHB_STATE_IDLE;
                        }
                        else
                        {
                            next_state = AHB_STATE_DATA;
                        }
                        do_latch = true;
                    }
                    else if (m_dmem_in.htrans == SCR1_HTRANS_IDLE)
                    {
                        next_state = AHB_STATE_IDLE;
                    }
                    else
                    {
                        next_state = AHB_STATE_ERR;
                    }
                }
                break;
            default:
                next_state = AHB_STATE_ERR;
                break;
        }

        if (do_latch)
        {
            m_dmem.addr = m_dmem_in.haddr;
            m_dmem.wr   = m_dmem_in.hwrite;
            m_dmem.size = m_dmem_in.hsize;
            m_dmem.be   = be_form((uint8_t)(m_dmem_in.haddr & 3u), m_dmem_in.hsize);

            if (!m_dmem_in.hwrite)
            {
                switch (m_dmem_in.haddr)
                {
                    case SCR1_SIM_SOFT_IRQ_ADDR:
                        m_dmem.hrdata_l = m_soft_irq_reg ? 1u : 0u;
                        break;
                    case SCR1_SIM_EXT_IRQ_ADDR:
                        m_dmem.hrdata_l = (uint32_t)m_irq_lines_reg;
                        break;
                    default:
                        m_dmem.hrdata_l = read_word(m_dmem_in.haddr, m_dmem.be);
                        break;
                }
            }
        }

        m_dmem.state = next_state;
    }

    //----------------------------------------------------------------
    // Stall pattern shift
    //----------------------------------------------------------------
    rotate_stall(m_imem);
    rotate_stall(m_dmem);
}
