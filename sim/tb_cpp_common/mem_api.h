#ifndef __MEM_API_H__
#define __MEM_API_H__

#include <stdint.h>
#include <vector>

//--------------------------------------------------------------------
// Abstract interface for memory access
//--------------------------------------------------------------------
class mem_api
{
public:
    virtual bool    create_memory(uint32_t addr, uint32_t size, uint8_t *mem = NULL) = 0;
    virtual bool    valid_addr(uint32_t addr) = 0;
    virtual void    write(uint32_t addr, uint8_t data) = 0;
    virtual uint8_t read(uint32_t addr) = 0;
};

//--------------------------------------------------------------------
// mem_patch: a contiguous memory chunk to preload into the reference
// model (used for raw relocatable snippy ELFs that Spike's ELF loader
// cannot consume)
//--------------------------------------------------------------------
struct mem_patch
{
    uint32_t             addr;
    std::vector<uint8_t> data;
};

#endif
