#ifndef TB_AHB_MEM_H
#define TB_AHB_MEM_H

#include <cstdint>
#include <vector>

#include "ahb.h"
#include "mem_api.h"

//--------------------------------------------------------------------
// tb_ahb_mem: C++ model of the native scr1_memory_tb_ahb SV module.
//
// Two independent AHB slave channels (imem - read only, dmem - R/W)
// with zero wait states by default (req_ack pattern all ones, same
// as native +imem_pattern=FFFFFFFF +dmem_pattern=FFFFFFFF).
//
// Service addresses on the dmem channel:
//   SCR1_SIM_PRINT_ADDR    - write: character to stdout
//   SCR1_SIM_SOFT_IRQ_ADDR - R/W: soft_irq register
//   SCR1_SIM_EXT_IRQ_ADDR  - R/W: irq_lines register
// Test completion is detected by an imem fetch of SCR1_SIM_EXIT_ADDR
// (equivalent of native `curr_pc == SCR1_SIM_EXIT_ADDR` check).
//--------------------------------------------------------------------
class tb_ahb_mem : public mem_api
{
public:
    tb_ahb_mem(uint32_t size = 1024 * 1024);

    //-------------------------------------------------------------
    // mem_api (backdoor for ELF loading)
    //-------------------------------------------------------------
    bool    create_memory(uint32_t addr, uint32_t size, uint8_t *mem = NULL);
    bool    valid_addr(uint32_t addr);
    void    write(uint32_t addr, uint8_t data);
    uint8_t read(uint32_t addr);

    //-------------------------------------------------------------
    // Cycle based interface (called by the testbench)
    //-------------------------------------------------------------
    // Sample DUT master outputs after clk low edge settled
    void sample_inputs(const ahb_master_ports &imem, const ahb_master_ports &dmem);
    // Combinational outputs from the current registered state
    void drive_outputs(ahb_slave_ports &imem, ahb_slave_ports &dmem);
    // Posedge: commit writes, advance FSMs
    void posedge(void);

    //-------------------------------------------------------------
    // Status
    //-------------------------------------------------------------
    bool     exit_detected(void) const { return m_exit_detected; }
    uint16_t irq_lines(void) const     { return m_irq_lines_reg; }
    bool     soft_irq(void) const      { return m_soft_irq_reg; }
    uint64_t print_count(void) const   { return m_print_count; }

private:
    struct channel
    {
        // Registered data phase state
        uint8_t  state;        // 0 = IDLE, 1 = DATA
        uint32_t addr;
        bool     wr;
        uint8_t  size;
        uint8_t  be;
        uint32_t hrdata_l;
        bool     req_ack_rnd;
        uint32_t req_ack_stall;

        channel(): state(0), addr(0), wr(false), size(SCR1_HSIZE_32B), be(0),
                   hrdata_l(0), req_ack_rnd(true), req_ack_stall(0xFFFFFFFFu) {}

        bool req_ack(void) const
        {
            return (req_ack_stall == 0) ? req_ack_rnd : (req_ack_stall & 1u);
        }
    };

    uint8_t  be_form(uint8_t offset, uint8_t hsize);
    uint32_t read_word(uint32_t addr, uint8_t be);
    void     write_word(uint32_t addr, uint8_t be, uint32_t data);
    void     rotate_stall(channel &ch);

    std::vector<uint8_t> m_mem;
    uint32_t             m_size;

    channel              m_imem;
    channel              m_dmem;

    ahb_master_ports     m_imem_in;
    ahb_master_ports     m_dmem_in;

    uint16_t             m_irq_lines_reg;
    bool                 m_soft_irq_reg;
    bool                 m_exit_detected;
    uint64_t             m_print_count;
};

#endif
