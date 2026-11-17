#ifndef TB_AXI_MEM_H
#define TB_AXI_MEM_H

#include <cstdint>
#include <vector>

#include "axi.h"
#include "mem_api.h"

//--------------------------------------------------------------------
// tb_axi_mem: C++ model of the native scr1_memory_tb_axi SV module.
//
// Two independent single-beat AXI4 slave interfaces sharing one
// byte memory (interface 0 = imem, interface 1 = dmem), with
// registered outputs, exactly like the native model.
//
// Service addresses on write:
//   SCR1_SIM_PRINT_ADDR    - character to stdout
//   SCR1_SIM_SOFT_IRQ_ADDR - soft_irq register
//   SCR1_SIM_EXT_IRQ_ADDR  - irq_lines register
// Test completion is detected by an imem read of SCR1_SIM_EXIT_ADDR
// (equivalent of native `curr_pc == SCR1_SIM_EXIT_ADDR` check).
//--------------------------------------------------------------------
class tb_axi_mem : public mem_api
{
public:
    static const int IF_IMEM = 0;
    static const int IF_DMEM = 1;

    tb_axi_mem(uint32_t size = 1024 * 1024);

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
    // Master bus samples for the coming posedge
    axi_m2s &bus_in(int idx)             { return m_if[idx].in; }
    // Registered slave outputs (valid after posedge())
    const axi_s2m &bus_out(int idx) const { return m_if[idx].out; }
    // Posedge: advance both interface FSMs, commit writes
    void posedge(void);

    //-------------------------------------------------------------
    // Status
    //-------------------------------------------------------------
    bool     exit_detected(void) const { return m_exit_detected; }
    uint16_t irq_lines(void) const     { return m_irq_lines_reg; }
    bool     soft_irq(void) const      { return m_soft_irq_reg; }
    uint64_t print_count(void) const   { return m_print_count; }

private:
    struct axi_if
    {
        axi_m2s    in;             // sampled master bus
        axi_s2m    out;            // registered slave outputs
        uint32_t   awaddr_hold;    // held AW while waiting for W
        uint8_t    awsize_hold;

        axi_if(): awaddr_hold(0), awsize_hold(2) {}
    };

    void     rd_posedge(axi_if &f, bool detect_exit);
    void     wr_posedge(axi_if &f);
    uint32_t mem_read_fn(uint32_t adr, uint32_t bytes_num);
    void     mem_write_fn(uint32_t adr, uint32_t data, uint8_t strb, uint32_t bytes_num);

    std::vector<uint8_t> m_mem;
    uint32_t             m_size;

    axi_if               m_if[2];

    uint16_t             m_irq_lines_reg;
    bool                 m_soft_irq_reg;
    bool                 m_exit_detected;
    uint64_t             m_print_count;
};

#endif
