#ifndef AHB_H
#define AHB_H

#include <cstdint>

//--------------------------------------------------------------------
// AHB encodings (scr1_ahb.svh)
//--------------------------------------------------------------------
#define SCR1_HTRANS_IDLE    0x0
#define SCR1_HTRANS_BUSY    0x1
#define SCR1_HTRANS_NONSEQ  0x2
#define SCR1_HTRANS_SEQ     0x3

#define SCR1_HSIZE_8B       0x0
#define SCR1_HSIZE_16B      0x1
#define SCR1_HSIZE_32B      0x2

#define SCR1_HRESP_OKAY     0x0
#define SCR1_HRESP_ERROR    0x1

//--------------------------------------------------------------------
// Simulation service addresses (scr1_arch_description.svh)
//--------------------------------------------------------------------
#define SCR1_SIM_EXIT_ADDR      0x000000F8u
#define SCR1_SIM_PRINT_ADDR     0xF0000000u
#define SCR1_SIM_EXT_IRQ_ADDR   0xF0000100u
#define SCR1_SIM_SOFT_IRQ_ADDR  0xF0000200u

//--------------------------------------------------------------------
// Sampled AHB master outputs (DUT -> memory)
//--------------------------------------------------------------------
struct ahb_master_ports
{
    uint8_t  htrans;
    uint32_t haddr;
    uint8_t  hsize;
    bool     hwrite;
    uint32_t hwdata;

    ahb_master_ports()
    {
        htrans = SCR1_HTRANS_IDLE;
        haddr  = 0;
        hsize  = SCR1_HSIZE_32B;
        hwrite = false;
        hwdata = 0;
    }
};

//--------------------------------------------------------------------
// Driven AHB slave inputs (memory -> DUT)
//--------------------------------------------------------------------
struct ahb_slave_ports
{
    bool     hready;
    uint32_t hrdata;
    bool     hresp;

    ahb_slave_ports()
    {
        hready = true;
        hrdata = 0;
        hresp  = SCR1_HRESP_OKAY;
    }
};

#endif
