#ifndef TRACE_LOGGER_H
#define TRACE_LOGGER_H

#include <cstdint>
#include <cstdio>

#include "Vscr1_top_ahb.h"

//--------------------------------------------------------------------
// trace_inputs: DUT internals sampled once per cycle (pre-posedge
// settled values), matching the ports of the native
// scr1_trace_logger.sv module.
//--------------------------------------------------------------------
struct trace_inputs
{
    bool     rst_n;
    // Issue (instruction accepted by the IDU)
    bool     issue_vd;        // ifu2idu_vd_o & idu2ifu_rdy
    uint32_t issue_instr;     // ifu2idu_instr_o
    // Redirect
    bool     redirect;        // new_pc_req
    uint32_t redirect_pc;     // new_pc
    // Retirement (EXU)
    bool     retire;          // instret
    uint32_t retire_pc;       // curr_pc
    bool     rd_wr;           // exu2mprf_w_req_i
    uint8_t  rd_addr;         // exu2mprf_rd_addr_i
    uint32_t rd_data;         // exu2mprf_rd_data_i
    // Trap / return events (CSR)
    bool     exc;             // e_exc
    bool     irq;             // e_irq
    uint32_t mepc;            // {csr_mepc_next, 1'b0} (RVC, PC_LSB=1)
    uint8_t  mcause_ec;       // csr_mcause_ec_next
    bool     mcause_irq;      // csr_mcause_i_next
    uint32_t mtvec;           // {csr_mtvec_base, 4'b0, mode}
    uint32_t mtval;           // csr_mtval_next

    trace_inputs()
    {
        rst_n = false; issue_vd = false; issue_instr = 0;
        redirect = false; redirect_pc = 0;
        retire = false; retire_pc = 0;
        rd_wr = false; rd_addr = 0; rd_data = 0;
        exc = false; irq = false; mepc = 0;
        mcause_ec = 0; mcause_irq = false; mtvec = 0; mtval = 0;
    }
};

//--------------------------------------------------------------------
// trace_logger: C++ reproduction of scr1_trace_logger.sv.
// One text line per retired instruction:
//   <Cycle> <PC> <Opcode> <RD write> <Status>
// - Opcode is the raw instruction word; trap events print 0x--------
// - RD write is "x<N> = 0x<VALUE>", empty for no write or rd = x0
// - Status is IRQ/EXC/MRET/SRET, empty for a normal instruction
// The raw instruction is recovered from a small {pc, instr} FIFO
// pushed on every instruction accepted by the IDU, matching the
// retiring PC and skipping flushed entries.
//--------------------------------------------------------------------
class trace_logger
{
public:
    trace_logger();
    ~trace_logger();

    bool open(const char *path);
    void close(void);
    bool is_open(void) const { return m_file != NULL; }

    // Capture the sampled internals from the verilated model
    static void capture(Vscr1_top_ahb *top, trace_inputs &in);

    // One clock tick: emit trap/retire lines and update the FIFO
    void posedge(const trace_inputs &in);

private:
    static const int FIFO_DEPTH = 16;
    static const int FIFO_MASK  = FIFO_DEPTH - 1;

    bool ret_lookup(uint32_t pc, uint32_t &instr) const;
    void emit_line(uint64_t cycle, const char *pc, const char *op,
                   const char *rd, const char *st, const char *extra);

    FILE    *m_file;
    uint64_t m_time_cnt;
    // Byte-accurate PC of the instruction accepted by the IDU
    uint32_t m_pc_ff;
    // Instruction FIFO
    uint32_t m_f_pc[FIFO_DEPTH];
    uint32_t m_f_instr[FIFO_DEPTH];
    int      m_head;
    int      m_tail;
    int      m_count;
    // mcause/mepc/mtval/mtvec + faulting instr on trap lines
    bool     m_trap_detail;
};

#endif
