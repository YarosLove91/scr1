#include <cstring>

#include "logger.h"
#include "trace_logger.h"

// Reset vector (SCR1_ARCH_RST_VECTOR)
#define SCR1_RST_VECTOR 0x00000200u

//--------------------------------------------------------------------
// Construction / destruction
//--------------------------------------------------------------------
trace_logger::trace_logger()
{
    m_file        = NULL;
    m_listener    = NULL;
    m_time_cnt    = 0;
    m_pc_ff       = SCR1_RST_VECTOR;
    m_head        = 0;
    m_tail        = 0;
    m_count       = 0;
    m_trap_detail = true;
    memset(m_f_pc, 0, sizeof(m_f_pc));
    memset(m_f_instr, 0, sizeof(m_f_instr));
}

trace_logger::~trace_logger()
{
    close();
}

//--------------------------------------------------------------------
// open / close
//--------------------------------------------------------------------
bool trace_logger::open(const char *path)
{
#ifndef TB_STATE_DUMP
    (void)path;
    logger::inst().warning("model built without state dump support (STATE_DUMP=0), trace log disabled");
    return false;
#else
    close();
    m_file = fopen(path, "w");
    if (m_file == NULL)
    {
        logger::inst().error(std::string("cannot open trace log '") + path + "'");
        return false;
    }
    fprintf(m_file, "# SCR1 program execution trace\n");
    fprintf(m_file, "%10s %-10s %-10s %-20s %-8s\n",
            "Cycle", "PC", "Opcode", "RD write", "Status");
    return true;
#endif
}

void trace_logger::close(void)
{
    if (m_file != NULL)
    {
        fclose(m_file);
        m_file = NULL;
    }
}

//--------------------------------------------------------------------
// capture: sample the DUT internals for the coming posedge
//--------------------------------------------------------------------
void trace_logger::capture(dut_top_t *top, trace_inputs &in)
{
#ifndef TB_STATE_DUMP
    (void)top;
    in = trace_inputs();
#else
    in.rst_n       = (bool)SCR1_PIPE(top, pipe_rst_n);
    in.issue_vd    = SCR1_PIPE(top, i_pipe_ifu__DOT__ifu2idu_vd_o) &&
                     SCR1_PIPE(top, idu2ifu_rdy);
    in.issue_instr = (uint32_t)SCR1_PIPE(top, i_pipe_ifu__DOT__ifu2idu_instr_o);
    in.redirect    = (bool)SCR1_PIPE(top, new_pc_req);
    in.redirect_pc = (uint32_t)SCR1_PIPE(top, new_pc);
    in.retire      = (bool)SCR1_PIPE(top, instret);
    in.retire_pc   = (uint32_t)SCR1_PIPE(top, curr_pc);
    in.rd_wr       = (bool)SCR1_PIPE(top, i_pipe_mprf__DOT__exu2mprf_w_req_i);
    in.rd_addr     = (uint8_t)SCR1_PIPE(top, i_pipe_mprf__DOT__exu2mprf_rd_addr_i);
    in.rd_data     = (uint32_t)SCR1_PIPE(top, i_pipe_mprf__DOT__exu2mprf_rd_data_i);
    in.exc         = (bool)SCR1_PIPE(top, i_pipe_csr__DOT__e_exc);
    in.irq         = (bool)SCR1_PIPE(top, i_pipe_csr__DOT__e_irq);
    in.mepc        = (uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mepc_next) << 1;
    in.mcause_ec   = (uint8_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mcause_ec_next);
    in.mcause_irq  = (bool)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mcause_i_next);
    in.mtvec       = ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mtvec_base) << 6) |
                     ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mtvec_mode) & 3u);
    in.mtval       = (uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mtval_next);
#endif
}

//--------------------------------------------------------------------
// ret_lookup: combinational search of the retiring PC in the FIFO
//--------------------------------------------------------------------
bool trace_logger::ret_lookup(uint32_t pc, uint32_t &instr) const
{
    for (int k = 0; k < m_count; ++k)
    {
        int idx = (m_head + k) & FIFO_MASK;
        if (m_f_pc[idx] == pc)
        {
            instr = m_f_instr[idx];
            return true;
        }
    }
    instr = 0;
    return false;
}

//--------------------------------------------------------------------
// emit_line: SV-compatible formatting with trailing whitespace trimmed
//--------------------------------------------------------------------
void trace_logger::emit_line(uint64_t cycle, const char *pc, const char *op,
                             const char *rd, const char *st, const char *extra)
{
    char line[1024];
    int  len;

    snprintf(line, sizeof(line), "%10llu %-10s %-10s %-20s %-8s",
             (unsigned long long)cycle, pc, op, rd, st);
    if (extra != NULL && extra[0] != '\0')
    {
        len = strlen(line);
        snprintf(line + len, sizeof(line) - len, "%s", extra);
    }

    // rtrim: no trailing spaces in a line
    len = strlen(line);
    while ((len > 0) && ((line[len - 1] == ' ') || (line[len - 1] == '\t')))
        line[--len] = '\0';

    fprintf(m_file, "%s\n", line);

    // Periodic flush so long runs leave a usable partial log
    if ((m_time_cnt & 0xFFFu) == 0u)
        fflush(m_file);
}

//--------------------------------------------------------------------
// posedge: one clock tick of the logger
//--------------------------------------------------------------------
void trace_logger::posedge(const trace_inputs &in)
{
    if (!in.rst_n)
    {
        // Synchronous reset of the logger state
        m_time_cnt = 0;
        m_pc_ff    = SCR1_RST_VECTOR;
        m_head     = 0;
        m_tail     = 0;
        m_count    = 0;
        return;
    }

    uint32_t ret_instr = 0;
    bool     ret_found = ret_lookup(in.retire_pc, ret_instr);

    //----------------------------------------------------------------
    // Trap events: IRQ/EXC (priority EXC > IRQ), PC = mepc
    //----------------------------------------------------------------
    if ((m_file != NULL) && (in.exc || in.irq))
    {
        char pc_str[16], op_str[16], st_str[8], extra[256];

        snprintf(pc_str, sizeof(pc_str), "0x%08x", in.mepc);
        snprintf(op_str, sizeof(op_str), "0x--------");
        snprintf(st_str, sizeof(st_str), "%s", in.exc ? "EXC" : "IRQ");

        extra[0] = '\0';
        if (m_trap_detail)
        {
            uint32_t mcause_val = ((uint32_t)in.mcause_irq << 31) |
                                  ((uint32_t)in.mcause_ec & 0x3Fu);
            snprintf(extra, sizeof(extra),
                     " | mcause=0x%08x mepc=0x%08x mtval=0x%08x mtvec=0x%08x instr=0x%08x",
                     mcause_val, in.mepc, in.mtval, in.mtvec, ret_instr);
        }

        emit_line(m_time_cnt, pc_str, op_str, "", st_str, extra);
    }

    //----------------------------------------------------------------
    // Retired instruction (suppressed for the faulting instruction,
    // which is represented by the EXC trap line above)
    //----------------------------------------------------------------
    if (in.retire && !in.exc && (m_file != NULL))
    {
        char pc_str[16], op_str[16], rd_str[24], st_str[8];

        snprintf(pc_str, sizeof(pc_str), "0x%08x", in.retire_pc);
        snprintf(op_str, sizeof(op_str), "0x%08x", ret_instr);
        if (in.rd_wr && (in.rd_addr != 0))
            snprintf(rd_str, sizeof(rd_str), "x%u = 0x%08x",
                     (unsigned)in.rd_addr, in.rd_data);
        else
            rd_str[0] = '\0';

        if (ret_instr == 0x30200073u)      snprintf(st_str, sizeof(st_str), "MRET");
        else if (ret_instr == 0x10200073u) snprintf(st_str, sizeof(st_str), "SRET");
        else                               st_str[0] = '\0';

        emit_line(m_time_cnt, pc_str, op_str, rd_str, st_str, NULL);
    }

    //----------------------------------------------------------------
    // Retirement event for listeners (reference model verification);
    // includes faulting instructions, matching Spike commit semantics
    //----------------------------------------------------------------
    if (in.retire && (m_listener != NULL))
    {
        retire_event ev;
        ev.cycle  = m_time_cnt;
        ev.pc     = in.retire_pc;
        ev.instr  = ret_instr;
        ev.rd_wr  = in.rd_wr && (in.rd_addr != 0);
        ev.rd     = in.rd_addr;
        ev.rd_val = in.rd_data;
        ev.exc    = in.exc;
        m_listener->on_retire(ev);
    }

    //----------------------------------------------------------------
    // FIFO update: drop entries up to the retired one, push issued
    //----------------------------------------------------------------
    if (in.retire && ret_found)
    {
        for (int m = 0; m < m_count; ++m)
        {
            int idx = (m_head + m) & FIFO_MASK;
            if (m_f_pc[idx] == in.retire_pc)
            {
                m_head  = (m_head + m + 1) & FIFO_MASK;
                m_count = m_count - m - 1;
                break;
            }
        }
    }

    if (in.issue_vd && (m_count < FIFO_DEPTH))
    {
        m_f_pc[m_tail]    = m_pc_ff;
        m_f_instr[m_tail] = in.issue_instr;
        m_tail            = (m_tail + 1) & FIFO_MASK;
        m_count           = m_count + 1;
    }

    //----------------------------------------------------------------
    // Byte-accurate PC tracker (RVC aware)
    //----------------------------------------------------------------
    bool is_rvc = ((in.issue_instr & 3u) != 3u);
    if (in.redirect)
        m_pc_ff = in.redirect_pc;
    else if (in.issue_vd)
        m_pc_ff += is_rvc ? 2u : 4u;

    m_time_cnt++;
}
