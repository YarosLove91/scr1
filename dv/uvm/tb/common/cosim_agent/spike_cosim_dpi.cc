// ============================================================
// File    : spike_cosim_dpi.cc
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Pattern 2B: in-process Spike reference model via DPI-C.
// The SV side (scr1_ref_spike) pulls one golden commit per DUT
// commit (lockstep), so the first divergence is localized on
// the very instruction that broke.
//
// Memory model: flat byte regions mirroring the proven SCR1
// Spike flags (docker/scr1-spike/compare_state.py):
//   RAM    0x00000000 : 0x10000   (verilog hex loaded the same
//                                  way $readmemh does it)
//   TCM    0x00480000 : 0x10000
//   TIMER  0x00490000 : 0x1000    (plain RAM: device not modeled)
//   SIM    0xF0000000 : 0x1000    (console/IRQ regs as plain RAM)
//
// DPI API (imported by scr1_ref_spike.sv):
//   scr1_spike_init(hex_path, isa, start_pc, mtvec_reset, mstatus_reset)
//       -> 0 on success; mtvec_reset/mstatus_reset calibrate the
//          IMPLEMENTATION-DEFINED reset values to the DUT ones (the
//          RISC-V spec leaves them unspecified: SCR1 boots with
//          mtvec=MTVEC_RST_VAL and mstatus.MPIE=1, Spike with 0/0)
//   scr1_spike_step(pc, instr, wr, rd, rd_data, trap, mcause, mepc,
//                   csr_w_valid, csr_w_addr, csr_w_value)
//       -> 0 ok; trap=1 marks a trap-entry step (mcause/mepc valid);
//          csr_w_valid=1 marks a golden CSR-write event of a NON-trap
//          step (value = the write RESULT logged by Spike, not the
//          DUT-side bus operand - see scr1_spike_step comments)
//   scr1_spike_get_csr(addr, val) -> 0 ok / -1 (no model or the CSR is
//       not readable - processor_t::get_csr throws on unknown addresses)
//   scr1_spike_fini()
//
// Built against the host riscv-isa-sim tree (SPIKE_ROOT); the
// proven Oct-master libs are also extracted under tools/bin by
// `make spike_extract` (see dv/uvm/Makefile).
// ============================================================

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include <svdpi.h>

#include "riscv/cfg.h"
#include "riscv/processor.h"
#include "riscv/simif.h"

namespace {

struct Region {
  uint64_t base;
  std::vector<uint8_t> mem;
  Region(uint64_t b, size_t sz) : base(b), mem(sz, 0) {}
  bool contains(uint64_t a) const {
    return a >= base && a < base + mem.size();
  }
};

class Scr1Simif : public simif_t {
public:
  std::vector<std::unique_ptr<Region>> regions;
  cfg_t cfg;
  std::map<size_t, processor_t *> harts;

  char *addr_to_mem(reg_t paddr) override {
    for (auto &r : regions) {
      if (r->contains(paddr)) {
        return reinterpret_cast<char *>(r->mem.data() + (paddr - r->base));
      }
    }
    return nullptr;
  }

  bool mmio_load(reg_t paddr, size_t len, uint8_t *bytes) override {
    char *p = addr_to_mem(paddr);
    if (!p) return false;
    std::memcpy(bytes, p, len);
    return true;
  }

  bool mmio_store(reg_t paddr, size_t len, const uint8_t *bytes) override {
    char *p = addr_to_mem(paddr);
    if (!p) return false;
    std::memcpy(p, bytes, len);
    return true;
  }

  void proc_reset(unsigned) override {}
  const cfg_t &get_cfg() const override { return cfg; }
  const std::map<size_t, processor_t *> &get_harts() const override { return harts; }
  const char *get_symbol(uint64_t) override { return nullptr; }
};

std::unique_ptr<Scr1Simif> g_sim;
std::unique_ptr<processor_t> g_proc;
FILE *g_commit_log_sink = nullptr;  // commit-log print sink (/dev/null)

// verilog hex (objcopy -O verilog, byte tokens + @addr markers) -
// parsed exactly like $readmemh into a byte array
bool load_verilog_hex(Scr1Simif &sim, const std::string &path) {
  std::ifstream f(path);
  if (!f) return false;
  std::string line;
  uint64_t addr = 0;
  while (std::getline(f, line)) {
    std::istringstream is(line);
    std::string tok;
    while (is >> tok) {
      if (tok[0] == '@' || tok[0] == '/') {
        if (tok[0] == '@') addr = std::strtoull(tok.c_str() + 1, nullptr, 16);
        continue;
      }
      char *p = sim.addr_to_mem(addr);
      if (p) *p = static_cast<uint8_t>(std::strtoul(tok.c_str(), nullptr, 16));
      addr++;
    }
  }
  return true;
}

uint32_t fetch_instr(Scr1Simif &sim, uint64_t pc) {
  uint8_t b0 = 0, b1 = 0, b2 = 0, b3 = 0;
  char *p = sim.addr_to_mem(pc);
  if (p) b0 = p[0], b1 = p[1];
  char *p2 = sim.addr_to_mem(pc + 2);
  if (p2) b2 = p2[0], b3 = p2[1];
  uint16_t lo = static_cast<uint16_t>(b0) | (static_cast<uint16_t>(b1) << 8);
  if ((lo & 0x3) != 0x3) return lo;  // RVC
  uint16_t hi = static_cast<uint16_t>(b2) | (static_cast<uint16_t>(b3) << 8);
  return static_cast<uint32_t>(lo) | (static_cast<uint32_t>(hi) << 16);
}

}  // namespace

extern "C" {

// returns 0 on success
int scr1_spike_init(const char *hex_path, const char *isa, unsigned start_pc,
                    unsigned mtvec_reset, unsigned mstatus_reset) {
  g_sim.reset(new Scr1Simif());
  g_sim->regions.emplace_back(new Region(0x00000000ull, 0x10000));
  g_sim->regions.emplace_back(new Region(0x00480000ull, 0x10000));
  g_sim->regions.emplace_back(new Region(0x00490000ull, 0x1000));
  g_sim->regions.emplace_back(new Region(0xF0000000ull, 0x1000));

  if (!load_verilog_hex(*g_sim, hex_path ? hex_path : "")) {
    std::fprintf(stderr, "spike_cosim: cannot load hex '%s'\n",
                 hex_path ? hex_path : "(null)");
    return -1;
  }

  // enable_log_commits() also PRINTS every commit into the processor's
  // log file (commit_log_print_insn -> fprintf), so a nullptr log_file
  // segfaults; the record maps we consume (log_reg_write etc.) are
  // filled regardless - park the printer on /dev/null
  if (!g_commit_log_sink) g_commit_log_sink = std::fopen("/dev/null", "w");

  g_proc.reset(new processor_t(isa, "M", &g_sim->cfg, g_sim.get(), 0,
                               /*halt_on_reset=*/false,
                               /*log_file=*/g_commit_log_sink, std::cerr));
  g_sim->harts[0] = g_proc.get();
  g_proc->enable_log_commits();
  g_proc->reset();
  g_proc->get_state()->pc = start_pc;
  // mtvec has an IMPLEMENTATION-DEFINED reset value: SCR1 boots with its
  // trap vector (MTVEC_RST_VAL, 0x1C0), Spike resets it to 0 - calibrate
  // the golden state to the DUT one so programs that never write mtvec
  // still compare equal at the run exit (and any pre-configuration trap
  // vectors like the SCR1 hardware)
  if (mtvec_reset != 0) g_proc->put_csr(CSR_MTVEC, mtvec_reset);
  // mstatus reset value is likewise implementation-defined: SCR1 resets
  // MPIE=1 (SCR1_CSR_MSTATUS_MPIE_RST_VAL) so mstatus=0x1880, Spike resets
  // MPIE=0 (0x1800). Calibrate to the DUT so a trap-free program that never
  // writes mstatus still compares equal at the exit; the MPP field is
  // legalized to PRV_M by Spike (M-only), matching the SCR1 hardwiring.
  if (mstatus_reset != 0) g_proc->put_csr(CSR_MSTATUS, mstatus_reset);
  return 0;
}

// One golden commit per call (lockstep pull from the scoreboard).
// Trap detection: a trap-entry step writes BOTH mcause and mepc
// (take_trap); a program `csrw mcause` (CSR fuzzing) writes a single
// CSR per step, so requiring the pair separates real traps from
// CSR writes. On a trap *pc/*instr describe the faulting instruction
// and *mcause/*mepc carry the logged values.
//
// CSR sideband (csr_w_valid/csr_w_addr/csr_w_value): the golden
// CSR-write event of NON-trap steps only, from log_reg_write entries
// of type 4. Suppressed cases:
//   - trap steps: take_trap writes mepc/mcause/mstatus/mtval - these
//     hardware updates are covered by the trap alignment (mepc+mcause
//     are compared there) and the milestone-7 mirror re-sync;
//   - MRET steps: Spike logs the hardware mstatus update (and
//     mstatush when present), but the SCR1 mret commit carries no
//     exu2csr write strobe (the hardware path bypasses the CSR bus;
//     the milestone-7 mirror re-syncs mstatus from the mret opcode).
// *csr_w_value is the write RESULT (csr_t::written_value() = read()
// after the store, i.e. the WARL-masked new content), while the DUT
// side carries the bus OPERAND in csr_w_data (pipe_csr applies
// WRITE/SET/CLEAR itself) - the scoreboard therefore compares only
// the write presence and the address. Multiple CSR writes in one
// non-trap step must not occur (one instruction - one CSR write);
// they are warned about and the first logged one is emitted.
int scr1_spike_step(int *pc, int *instr, int *wr, int *rd, int *rd_data,
                    int *trap, int *mcause, int *mepc,
                    int *csr_w_valid, int *csr_w_addr, int *csr_w_value) {
  if (!g_proc) return -1;
  state_t *st = g_proc->get_state();

  const uint64_t step_pc = st->pc & 0xffffffffull;
  const uint32_t instr_word = fetch_instr(*g_sim, step_pc);
  *instr = static_cast<int>(instr_word);

  st->log_reg_write.clear();
  st->log_mem_read.clear();
  st->log_mem_write.clear();

  g_proc->step(1);

  int gpr_wr = 0;
  unsigned gpr_idx = 0;
  uint64_t gpr_val = 0;
  int have_mcause = 0, have_mepc = 0;
  uint64_t mcause_val = 0, mepc_val = 0;
  int csr_wr_cnt = 0;
  unsigned csr_wr_addr = 0;
  uint64_t csr_wr_val = 0;
  for (const auto &e : st->log_reg_write) {
    const unsigned type = static_cast<unsigned>(e.first & 0xf);
    const unsigned idx = static_cast<unsigned>(e.first >> 4);
    if (type == 0) {
      if (idx != 0) {  // GPR, x0 writes are not logged by us
        gpr_wr = 1;
        gpr_idx = idx;
        gpr_val = e.second.v[0];
      }
    } else if (type == 4) {
      if (idx == 0x342) {
        have_mcause = 1;
        mcause_val = e.second.v[0];
      } else if (idx == 0x341) {
        have_mepc = 1;
        mepc_val = e.second.v[0];
      }
      if (csr_wr_cnt == 0) {
        csr_wr_addr = idx;
        csr_wr_val = e.second.v[0];
      }
      csr_wr_cnt++;
    }
  }

  const int is_trap = (have_mcause && have_mepc) ? 1 : 0;
  const bool is_mret = (instr_word == 0x30200073u);  // mret (never RVC)

  *pc = static_cast<int>(step_pc);
  *wr = gpr_wr;
  *rd = static_cast<int>(gpr_idx);
  *rd_data = static_cast<int>(gpr_val & 0xffffffffull);
  *trap = is_trap;
  *mcause = static_cast<int>(mcause_val & 0xffffffffull);
  *mepc = have_mepc ? static_cast<int>(mepc_val & 0xffffffffull)
                    : static_cast<int>(step_pc);
  *csr_w_valid = (!is_trap && !is_mret && csr_wr_cnt > 0) ? 1 : 0;
  *csr_w_addr = static_cast<int>(csr_wr_addr);
  *csr_w_value = static_cast<int>(csr_wr_val & 0xffffffffull);
  if (!is_trap && !is_mret && csr_wr_cnt > 1) {
    std::fprintf(stderr,
                 "spike_cosim: warning: %d CSR writes logged in one non-trap "
                 "step at pc=0x%08x - only the first (0x%03x) is emitted\n",
                 csr_wr_cnt, static_cast<unsigned>(step_pc), csr_wr_addr);
  }
  return 0;
}

// Current CSR value of the golden model (run-exit cross-check of the
// DUT snapshot). Peek-mode read (no side effects); processor_t::get_csr
// THROWS on unknown/illegal addresses (e.g. the SCR1-custom mcounten
// 0x7E0), so the call is guarded - returns 0 ok / -1 unavailable.
int scr1_spike_get_csr(int addr, int *val) {
  if (!g_proc) return -1;
  try {
    *val = static_cast<int>(g_proc->get_csr(addr) & 0xffffffffull);
    return 0;
  } catch (...) {
    return -1;
  }
}

void scr1_spike_fini() {
  g_proc.reset();
  g_sim.reset();
}

}  // extern "C"
