#ifndef BOOT_STUB_H
#define BOOT_STUB_H

#include <cstdint>
#include <vector>

//--------------------------------------------------------------------
// Boot stub for raw (ET_REL) llvm-snippy tests.
//
// A raw snippy ELF has no crt, no vectors and no sc_exit: only the
// generated sections placed at fixed addresses (see the generation
// yaml). The testbench synthesizes a minimal boot wrapper at the SCR1
// reset vector (0x200):
//
//   0x200: lui  sp, <stack_top>    # snippy stack top (stack base + size)
//   0x204: lui  tp, <util_base>    # utility/spill base
//   0x208: lui  gp, <util_base>    # utility/spill base
//   0x20c: jal  ra, <entry>        # call SnippyFunction
//   0x210: li   a0, 0              # result code: pass
//   0x214: jal  x0, 0xF8           # -> SIM_STOP (test done)
//
// plus the SIM_EXIT/SIM_STOP words at 0xF4/0xF8, exactly like the
// .text.init of the linked tests. The same bytes are preloaded into
// the Spike reference model, keeping the lockstep 1:1.
//--------------------------------------------------------------------

#define BOOT_STUB_BASE      0x00000200u
#define SIM_EXIT_ADDR_WORD  0x000000F4u     // nop
#define SIM_STOP_ADDR_WORD  0x000000F8u     // j .

// Default layout (fallback when the snippy .ld map is unavailable)
#define SNIPPY_STACK_TOP    0x00002000u
#define SNIPPY_UTIL_BASE    0x00002000u

//--------------------------------------------------------------------
// Instruction encoders
//--------------------------------------------------------------------
inline uint32_t lui_enc(uint8_t rd, uint32_t imm20)
{
    return (imm20 << 12) | ((uint32_t)rd << 7) | 0x37u;
}

// J-type: imm[20|10:1|11|19:12], offset in bytes, must be even
inline uint32_t jal_enc(uint8_t rd, int32_t off)
{
    uint32_t b20    = ((uint32_t)off >> 20) & 1u;
    uint32_t b10_1  = ((uint32_t)off >> 1)  & 0x3FFu;
    uint32_t b11    = ((uint32_t)off >> 11) & 1u;
    uint32_t b19_12 = ((uint32_t)off >> 12) & 0xFFu;
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) |
           ((uint32_t)rd << 7) | 0x6Fu;
}

//--------------------------------------------------------------------
// make_boot_stub: full patch set for a raw snippy image
//--------------------------------------------------------------------
struct boot_stub_patch
{
    uint32_t addr;
    uint32_t word;
};

// stack_top and util_base must be 4 KiB aligned (lui loads imm<<12)
inline std::vector<boot_stub_patch> make_boot_stub(uint32_t entry,
                                                   uint32_t stack_top = SNIPPY_STACK_TOP,
                                                   uint32_t util_base = SNIPPY_UTIL_BASE)
{
    std::vector<boot_stub_patch> p;

    // SIM_EXIT / SIM_STOP words (link.ld .text.init equivalent)
    p.push_back({SIM_EXIT_ADDR_WORD, 0x00000013u});      // nop
    p.push_back({SIM_STOP_ADDR_WORD, 0x0000006Fu});      // j .

    // Boot wrapper at the reset vector
    p.push_back({BOOT_STUB_BASE + 0x00, lui_enc(2, stack_top >> 12)});
    p.push_back({BOOT_STUB_BASE + 0x04, lui_enc(4, util_base >> 12)});
    p.push_back({BOOT_STUB_BASE + 0x08, lui_enc(3, util_base >> 12)});
    p.push_back({BOOT_STUB_BASE + 0x0C,
                 jal_enc(1, (int32_t)(entry - (BOOT_STUB_BASE + 0x0C)))});
    p.push_back({BOOT_STUB_BASE + 0x10, 0x00000513u});   // li a0, 0
    p.push_back({BOOT_STUB_BASE + 0x14,
                 jal_enc(0, (int32_t)(SIM_STOP_ADDR_WORD - (BOOT_STUB_BASE + 0x14)))});
    return p;
}

#endif
