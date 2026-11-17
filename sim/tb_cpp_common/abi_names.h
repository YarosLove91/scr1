#ifndef ABI_NAMES_H
#define ABI_NAMES_H

//--------------------------------------------------------------------
// RISC-V ABI register names, indexed by register number
//--------------------------------------------------------------------
inline const char *abi_name(unsigned idx)
{
    static const char *const names[32] =
    {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
    };
    return (idx < 32) ? names[idx] : "?";
}

#endif
