#include <charconv>
#include <fstream>
#include <iomanip>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <libelf.h>
#include <gelf.h>

#include "elf_load.h"
#include "logger.h"

//--------------------------------------------------------------------
// Constructor
//--------------------------------------------------------------------
elf_load::elf_load(const char *filename, mem_api *target)
{
    m_filename    = std::string(filename);
    m_target      = target;
    m_entry_point = 0;
    m_relocatable = false;
    m_stack_top   = SNIPPY_STACK_BASE + SNIPPY_STACK_SIZE;
    m_util_base   = SNIPPY_UTIL_BASE;
}

//--------------------------------------------------------------------
// load: dispatch by ELF type
//--------------------------------------------------------------------
bool elf_load::load(void)
{
    int fd;
    Elf *e;

    if (elf_version(EV_CURRENT) == EV_NONE)
        return false;

    if ((fd = open(m_filename.c_str(), O_RDONLY, 0)) < 0)
        return false;

    if ((e = elf_begin(fd, ELF_C_READ, NULL)) == NULL)
    {
        close(fd);
        return false;
    }

    if (elf_kind(e) != ELF_K_ELF)
    {
        elf_end(e);
        close(fd);
        return false;
    }

    GElf_Ehdr ehdr;
    if (gelf_getehdr(e, &ehdr) == NULL)
    {
        elf_end(e);
        close(fd);
        return false;
    }

    bool ok;
    if (ehdr.e_type == ET_REL)
    {
        m_relocatable = true;
        ok = load_sections(fd, e);
    }
    else
    {
        m_entry_point = (uint32_t)ehdr.e_entry;
        ok = load_segments(fd, e);
    }

    elf_end(e);
    close(fd);
    return ok;
}

//--------------------------------------------------------------------
// load_segments: ET_EXEC - load PT_LOAD segments at their LMA
//--------------------------------------------------------------------
bool elf_load::load_segments(int fd, Elf *e)
{
    size_t phnum = 0;
    if (elf_getphdrnum(e, &phnum) != 0)
        return false;

    for (size_t i = 0; i < phnum; i++)
    {
        GElf_Phdr phdr;
        if (gelf_getphdr(e, i, &phdr) == NULL)
            continue;

        if (phdr.p_type != PT_LOAD || phdr.p_filesz == 0)
            continue;

        uint32_t base = (uint32_t)phdr.p_paddr;   // LMA, as in objcopy verilog hex

        {
            std::ostringstream ss;
            ss << "Memory: 0x" << std::hex << std::setw(8) << std::setfill('0') << base
               << " - 0x" << std::setw(8) << (base + (uint32_t)phdr.p_filesz - 1)
               << std::dec << std::setfill(' ') << " (Size=" << (phdr.p_filesz / 1024)
               << "KB) [LOAD vaddr=0x"
               << std::hex << std::setw(8) << std::setfill('0') << (uint32_t)phdr.p_vaddr
               << std::dec << std::setfill(' ') << "]";
            logger::inst().info(ss.str());
        }

        if (!m_target->create_memory(base, (uint32_t)phdr.p_filesz))
        {
            logger::inst().error("Cannot allocate memory region");
            return false;
        }

        std::vector<uint8_t> buf(phdr.p_filesz);
        if (pread(fd, buf.data(), phdr.p_filesz, phdr.p_offset) != (ssize_t)phdr.p_filesz)
        {
            logger::inst().error("Cannot read segment data");
            return false;
        }

        for (size_t j = 0; j < phdr.p_filesz; j++)
        {
            uint32_t load_addr = base + (uint32_t)j;
            if (m_target->valid_addr(load_addr))
                m_target->write(load_addr, buf[j]);
            else
            {
                std::ostringstream ss;
                ss << "Cannot write byte to 0x" << std::hex << std::setw(8)
                   << std::setfill('0') << load_addr;
                logger::inst().error(ss.str());
                return false;
            }
        }
    }

    return true;
}

//--------------------------------------------------------------------
// snippy_defaults: built-in section placement (matches the generation
// yaml / link_snippy.ld conventions); used as a fallback only
//--------------------------------------------------------------------
static bool snippy_defaults(const char *name, uint32_t &base)
{
    if (strcmp(name, ".snippy.stack.rw") == 0)   { base = SNIPPY_STACK_BASE; return true; }
    if (strcmp(name, ".snippy.utility.rw") == 0) { base = SNIPPY_UTIL_BASE;  return true; }
    if (strcmp(name, ".snippy.code.rx") == 0)    { base = SNIPPY_CODE_BASE;  return true; }
    if (strcmp(name, ".snippy.data.rw") == 0)    { base = SNIPPY_DATA_BASE;  return true; }
    return false;
}

//--------------------------------------------------------------------
// parse_snippy_ld: section base addresses from the companion linker
// script that llvm-snippy emits next to the raw ELF
// (<name>.elf.ld). Recognized lines look like:
//   .snippy.code.rx 0x3000: {
//   .snippy.stack.rw 0x1000 (NOLOAD) : {
//--------------------------------------------------------------------
static bool parse_snippy_ld(const std::string &path,
                            std::map<std::string, uint32_t> &out)
{
    std::ifstream f(path);
    if (!f.is_open())
        return false;

    std::string line;
    while (std::getline(f, line))
    {
        size_t sec = line.find(".snippy.");
        if (sec == std::string::npos)
            continue;

        // Section name: up to the first whitespace
        size_t name_end = line.find_first_of(" \t", sec);
        std::string name = line.substr(sec, name_end - sec);

        // Base address: first hex literal after the name
        size_t hex = line.find("0x", name_end);
        if (hex == std::string::npos)
            hex = line.find("0X", name_end);
        if (hex == std::string::npos)
            continue;

        const char *first = line.c_str() + hex + 2;
        const char *last  = line.c_str() + line.size();
        uint32_t    base  = 0;
        if (std::from_chars(first, last, base, 16).ec != std::errc())
            continue;

        out[name] = base;
    }
    return !out.empty();
}

//--------------------------------------------------------------------
// load_sections: ET_REL (raw llvm-snippy output). Places allocated
// PROGBITS sections at the snippy map addresses, records the chunks
// for the reference model, and resolves SnippyFunction as the entry.
//--------------------------------------------------------------------
bool elf_load::load_sections(int fd, Elf *e)
{
    (void)fd;

    GElf_Ehdr ehdr;
    gelf_getehdr(e, &ehdr);

    // Section base addresses: companion <name>.elf.ld first, built-in
    // defaults as a fallback
    std::map<std::string, uint32_t> ldmap;
    std::string ld_path = m_filename + ".ld";
    bool have_ld = parse_snippy_ld(ld_path, ldmap);
    if (!have_ld)
        logger::inst().warning("snippy map '" + ld_path +
                               "' not found, using built-in section addresses");

    auto resolve_base = [&](const char *name, uint32_t &base) -> bool {
        auto it = ldmap.find(name);
        if (it != ldmap.end())
        {
            base = it->second;
            return true;
        }
        return snippy_defaults(name, base);
    };

    // Section bases for symbol resolution
    uint32_t code_base = 0;
    bool     have_code = false;

    Elf_Scn *scn = NULL;
    while ((scn = elf_nextscn(e, scn)) != NULL)
    {
        GElf_Shdr shdr;
        if (gelf_getshdr(scn, &shdr) == NULL)
            continue;

        const char *name = elf_strptr(e, ehdr.e_shstrndx, shdr.sh_name);
        if (name == NULL)
            continue;

        if ((shdr.sh_type == SHT_REL || shdr.sh_type == SHT_RELA) && shdr.sh_size != 0)
        {
            logger::inst().error(std::string("unsupported: raw ELF has relocations (") +
                                 name + ") - use a fully linked image");
            return false;
        }

        if (!(shdr.sh_flags & SHF_ALLOC))
            continue;

        uint32_t base;
        bool known = resolve_base(name, base);

        // Boot-stub layout comes from the (NOBITS) stack/utility sections
        if (known && (strcmp(name, ".snippy.stack.rw") == 0))
            m_stack_top = base + (uint32_t)shdr.sh_size;
        if (known && (strcmp(name, ".snippy.utility.rw") == 0))
            m_util_base = base;

        if (shdr.sh_type != SHT_PROGBITS || shdr.sh_size == 0)
            continue;   // NOBITS sections stay zero-filled

        if (!known)
            continue;   // .note.snippy and friends are not runtime image

        if (strcmp(name, ".snippy.code.rx") == 0)
        {
            code_base = base;
            have_code = true;
        }

        Elf_Data *data = elf_getdata(scn, NULL);
        if (data == NULL || data->d_buf == NULL)
            return false;

        if (!m_target->create_memory(base, (uint32_t)shdr.sh_size))
        {
            logger::inst().error("Cannot allocate memory region for " + std::string(name));
            return false;
        }

        mem_patch patch;
        patch.addr = base;
        patch.data.resize(shdr.sh_size);
        memcpy(patch.data.data(), data->d_buf, shdr.sh_size);

        const uint8_t *src = patch.data.data();
        for (size_t j = 0; j < shdr.sh_size; j++)
        {
            if (!m_target->valid_addr(base + (uint32_t)j))
            {
                std::ostringstream ss;
                ss << "Cannot write byte to 0x" << std::hex << (base + (uint32_t)j);
                logger::inst().error(ss.str());
                return false;
            }
            m_target->write(base + (uint32_t)j, src[j]);
        }
        m_patches.push_back(std::move(patch));

        std::ostringstream ss;
        ss << "Memory: 0x" << std::hex << std::setw(8) << std::setfill('0') << base
           << " - 0x" << std::setw(8) << (base + (uint32_t)shdr.sh_size - 1)
           << std::dec << std::setfill(' ') << " (Size=" << (shdr.sh_size / 1024)
           << "KB) [" << name << "]";
        logger::inst().info(ss.str());
    }

    if (!have_code)
    {
        logger::inst().error("no .snippy.code.rx section in the raw ELF");
        return false;
    }

    // Entry point: SnippyFunction symbol (section-relative)
    m_entry_point = code_base;      // fallback: start of the code section
    scn = NULL;
    while ((scn = elf_nextscn(e, scn)) != NULL)
    {
        GElf_Shdr shdr;
        if (gelf_getshdr(scn, &shdr) == NULL)
            continue;
        if (shdr.sh_type != SHT_SYMTAB)
            continue;

        Elf_Data *data = elf_getdata(scn, NULL);
        if (data == NULL)
            continue;

        int count = (shdr.sh_entsize > 0) ? (int)(shdr.sh_size / shdr.sh_entsize) : 0;
        for (int i = 0; i < count; i++)
        {
            GElf_Sym sym;
            if (gelf_getsym(data, i, &sym) == NULL)
                continue;
            const char *sname = elf_strptr(e, shdr.sh_link, sym.st_name);
            if (sname && strcmp(sname, "SnippyFunction") == 0)
            {
                m_entry_point = code_base + (uint32_t)sym.st_value;
                break;
            }
        }
    }

    return true;
}

//--------------------------------------------------------------------
// get_symbol: get symbol from ELF symbol table (libelf, no bfd)
//--------------------------------------------------------------------
bool elf_load::get_symbol(const char *symname, uint32_t &value)
{
    int fd;
    Elf *e;
    bool found = false;

    if (elf_version(EV_CURRENT) == EV_NONE)
        return false;

    if ((fd = open(m_filename.c_str(), O_RDONLY, 0)) < 0)
        return false;

    if ((e = elf_begin(fd, ELF_C_READ, NULL)) == NULL)
    {
        close(fd);
        return false;
    }

    Elf_Scn *scn = NULL;
    while (!found && (scn = elf_nextscn(e, scn)) != NULL)
    {
        GElf_Shdr shdr;
        if (gelf_getshdr(scn, &shdr) == NULL)
            continue;
        if (shdr.sh_type != SHT_SYMTAB && shdr.sh_type != SHT_DYNSYM)
            continue;

        Elf_Data *data = elf_getdata(scn, NULL);
        if (data == NULL)
            continue;

        int count = (shdr.sh_entsize > 0) ? (int)(shdr.sh_size / shdr.sh_entsize) : 0;
        for (int i = 0; i < count; i++)
        {
            GElf_Sym sym;
            if (gelf_getsym(data, i, &sym) == NULL)
                continue;
            const char *name = elf_strptr(e, shdr.sh_link, sym.st_name);
            if (name && strcmp(name, symname) == 0)
            {
                value  = (uint32_t)sym.st_value;
                found  = true;
                break;
            }
        }
    }

    elf_end(e);
    close(fd);

    return found;
}
