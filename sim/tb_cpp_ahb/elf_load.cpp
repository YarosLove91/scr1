#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <libelf.h>
#include <gelf.h>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

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
}

//--------------------------------------------------------------------
// load: Load ELF program segments (by LMA) to target
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
        return false;

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
    m_entry_point = (uint32_t)ehdr.e_entry;

    size_t phnum = 0;
    if (elf_getphdrnum(e, &phnum) != 0)
    {
        elf_end(e);
        close(fd);
        return false;
    }

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
            elf_end(e);
            close(fd);
            return false;
        }

        std::vector<uint8_t> buf(phdr.p_filesz);
        if (pread(fd, buf.data(), phdr.p_filesz, phdr.p_offset) != (ssize_t)phdr.p_filesz)
        {
            logger::inst().error("Cannot read segment data");
            elf_end(e);
            close(fd);
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
                elf_end(e);
                close(fd);
                return false;
            }
        }
    }

    elf_end(e);
    close(fd);

    return true;
}

//--------------------------------------------------------------------
// get_symbol: Get symbol from ELF symbol table (libelf, no bfd)
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
