#ifndef __ELF_LOAD_H__
#define __ELF_LOAD_H__

#include <string>
#include <vector>

#include "mem_api.h"

typedef struct Elf Elf;

//--------------------------------------------------------------------
// ELF loader
//
// Executable ELFs (ET_EXEC): PT_LOAD segments are loaded at their
// physical address (LMA), matching the objcopy verilog-hex / $readmemh
// flow of the native testbench. Required for TCM-linked images, whose
// VMA (0x0048_xxxx) differs from the LMA in external RAM (relocated by
// crt at runtime).
//
// Relocatable ELFs (ET_REL, e.g. raw llvm-snippy output): allocated
// PROGBITS sections are placed at the fixed snippy memory-map
// addresses; the entry point is the SnippyFunction symbol. Loaded
// chunks are recorded in patches() so the reference model can be
// preloaded with the same image (Spike cannot load ET_REL itself).
//--------------------------------------------------------------------

// Snippy section placement (must match the generation yaml)
#define SNIPPY_STACK_BASE   0x00001000u
#define SNIPPY_UTIL_BASE    0x00002000u
#define SNIPPY_CODE_BASE    0x00003000u
#define SNIPPY_DATA_BASE    0x00009000u

class elf_load
{
public:
    elf_load(const char *filename, mem_api *target);

    bool     load(void);
    uint32_t get_entry_point(void) { return m_entry_point; }
    bool     get_symbol(const char *symname, uint32_t &value);

    // True when the image is a raw relocatable (snippy) ELF that needs
    // the synthesized boot wrapper
    bool     is_relocatable(void) const { return m_relocatable; }
    // Loaded chunks for reference-model preloading (ET_REL only)
    const std::vector<mem_patch> &patches(void) const { return m_patches; }

protected:
    bool load_segments(int fd, Elf *elf);
    bool load_sections(int fd, Elf *elf);

    std::string m_filename;
    mem_api *   m_target;
    uint32_t    m_entry_point;
    bool        m_relocatable;
    std::vector<mem_patch> m_patches;
};

#endif
