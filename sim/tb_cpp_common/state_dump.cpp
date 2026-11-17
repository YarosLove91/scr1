#include <fstream>
#include <iomanip>
#include <sstream>

#include "abi_names.h"
#include "logger.h"
#include "state_dump.h"

// misa: RV32IMC (MXL=1(32), C|M|I), same default as the native mechanism
#ifndef SCR1_STATE_MISA
#define SCR1_STATE_MISA 0x40001104u
#endif

// mepc is stored as [31:PC_LSB]; PC_LSB=1 for RVC configs (MAX/BASE),
// PC_LSB=2 otherwise. Native used a hardcoded <<2 which is wrong for RVC.
#ifndef SCR1_MEPC_SHIFT
#define SCR1_MEPC_SHIFT 1
#endif

//--------------------------------------------------------------------
// capture: read GPRs and CSRs from the model internals
//--------------------------------------------------------------------
void state_dump::capture(dut_top_t *top, scr1_state &st)
{
#ifndef TB_STATE_DUMP
    (void)top;
    st = scr1_state();
    logger::inst().warning("model built without state dump support (STATE_DUMP=0)");
#else
    // GPRs: mprf_int is a flat wide vector over the unpacked array
    // [1:31], register xN lives in word (31 - N); x0 is hardwired zero
    st.gpr[0] = 0;
    for (int idx = 1; idx < 32; ++idx)
        st.gpr[idx] = (uint32_t)SCR1_PIPE(top, i_pipe_mprf__DOT__mprf_int)[31 - idx];

    st.mstatus  = ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mstatus_mie_ff) << 3)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mstatus_mpie_ff) << 7)
                | (3u << 11);
    st.mie      = ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mie_msie_ff) << 3)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mie_mtie_ff) << 7)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mie_meie_ff) << 11);
    st.mtvec    = ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mtvec_base) << 6)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mtvec_mode) & 1u);
    st.mscratch = (uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mscratch_ff);
    st.mepc     = (uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mepc_ff) << SCR1_MEPC_SHIFT;
    st.mcause   = ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mcause_i_ff) << 31)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mcause_ec_ff) & 0xFu);
    st.mtval    = (uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mtval_ff);
    st.mip      = ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mip_msip) << 3)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mip_mtip) << 7)
                | ((uint32_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mip_meip) << 11);
    st.mhartid  = (uint32_t)top->fuse_mhartid;
    st.mcycle   = (uint64_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_mcycle);
    st.minstret = (uint64_t)SCR1_PIPE(top, i_pipe_csr__DOT__csr_minstret);
    st.pc       = (uint32_t)SCR1_PIPE(top, curr_pc);
    st.misa     = SCR1_STATE_MISA;
#endif
}

//--------------------------------------------------------------------
// read_gpr: single register read (x0 is hardwired zero)
//--------------------------------------------------------------------
uint32_t state_dump::read_gpr(dut_top_t *top, unsigned idx)
{
#ifndef TB_STATE_DUMP
    (void)top;
    (void)idx;
    return 0;
#else
    if ((idx == 0) || (idx > 31))
        return 0;
    return (uint32_t)SCR1_PIPE(top, i_pipe_mprf__DOT__mprf_int)[31 - idx];
#endif
}

//--------------------------------------------------------------------
// to_string: native scr1_final_state.txt-compatible report
//--------------------------------------------------------------------
std::string state_dump::to_string(const scr1_state &st, const char *status, uint64_t time_ns)
{
    std::ostringstream ss;
    ss << std::hex << std::setfill('0');

    ss << "# SCR1 final architectural state\n";
    ss << "# sim_status: " << status << "\n";
    ss << std::dec << "# time: " << time_ns << "\n" << std::hex;
    ss << "# pc: 0x" << std::setw(8) << st.pc << "\n";

    for (int row = 0; row < 8; ++row)
    {
        for (int col = 0; col < 4; ++col)
        {
            int idx = row * 4 + col;
            ss << std::setfill(' ') << std::setw(4) << abi_name((unsigned)idx) << ": 0x"
               << std::setfill('0') << std::setw(8) << st.gpr[idx];
        }
        ss << "\n";
    }

    ss << std::dec;
    ss << "priv M\n";
    ss << "# CSR\n";
    ss << std::hex;

    struct { const char *name; uint32_t val; } csrs[] =
    {
        { "mstatus",  st.mstatus  },
        { "misa",     st.misa     },
        { "mie",      st.mie      },
        { "mtvec",    st.mtvec    },
        { "mscratch", st.mscratch },
        { "mepc",     st.mepc     },
        { "mcause",   st.mcause   },
        { "mtval",    st.mtval    },
        { "mip",      st.mip      },
        { "mhartid",  st.mhartid  },
        { "mcycle",   (uint32_t)st.mcycle        },
        { "mcycleh",  (uint32_t)(st.mcycle >> 32)   },
        { "minstret", (uint32_t)st.minstret      },
        { "minstreth",(uint32_t)(st.minstret >> 32) },
    };
    for (const auto &csr : csrs)
        ss << std::left << std::setfill(' ') << std::setw(9) << csr.name << std::right
           << " 0x" << std::setfill('0') << std::setw(8) << csr.val << "\n";

    return ss.str();
}

//--------------------------------------------------------------------
// to_log: print the snapshot through the logger
//--------------------------------------------------------------------
void state_dump::to_log(const scr1_state &st, const char *status, uint64_t time_ns)
{
    logger::inst().raw(to_string(st, status, time_ns));
}

//--------------------------------------------------------------------
// to_file: write the snapshot to a file
//--------------------------------------------------------------------
bool state_dump::to_file(const char *path, const scr1_state &st,
                         const char *status, uint64_t time_ns)
{
    std::ofstream f(path);
    if (!f.is_open())
    {
        logger::inst().error(std::string("cannot open state file '") + path + "'");
        return false;
    }
    f << to_string(st, status, time_ns);
    if (!f.good())
    {
        logger::inst().error(std::string("cannot write state file '") + path + "'");
        return false;
    }
    return true;
}
