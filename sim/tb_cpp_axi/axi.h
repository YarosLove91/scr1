#ifndef AXI_H
#define AXI_H

#include <cstdint>

//--------------------------------------------------------------------
// AXI response encodings
//--------------------------------------------------------------------
#define AXI_RESP_OKAY       0x0
#define AXI_RESP_EXOKAY     0x1
#define AXI_RESP_SLVERR     0x2
#define AXI_RESP_DECERR     0x3

//--------------------------------------------------------------------
// Simulation service addresses (scr1_arch_description.svh)
//--------------------------------------------------------------------
#define SCR1_SIM_EXIT_ADDR      0x000000F8u
#define SCR1_SIM_PRINT_ADDR     0xF0000000u
#define SCR1_SIM_EXT_IRQ_ADDR   0xF0000100u
#define SCR1_SIM_SOFT_IRQ_ADDR  0xF0000200u

//--------------------------------------------------------------------
// Sampled AXI master outputs (DUT -> memory)
//--------------------------------------------------------------------
struct axi_m2s
{
    // Write address channel
    bool     awvalid;
    uint8_t  awid;
    uint32_t awaddr;
    uint8_t  awsize;
    uint8_t  awlen;
    // Write data channel
    bool     wvalid;
    uint32_t wdata;
    uint8_t  wstrb;
    bool     wlast;
    // Write response channel
    bool     bready;
    // Read address channel
    bool     arvalid;
    uint8_t  arid;
    uint32_t araddr;
    uint8_t  arsize;
    uint8_t  arlen;
    // Read data channel
    bool     rready;

    axi_m2s()
    {
        awvalid = false; awid = 0; awaddr = 0; awsize = 2; awlen = 0;
        wvalid  = false; wdata = 0; wstrb = 0; wlast = false;
        bready  = false;
        arvalid = false; arid = 0; araddr = 0; arsize = 2; arlen = 0;
        rready  = false;
    }
};

//--------------------------------------------------------------------
// Registered AXI slave outputs (memory -> DUT)
//--------------------------------------------------------------------
struct axi_s2m
{
    // Write channels
    bool     awready;
    bool     wready;
    bool     bvalid;
    uint8_t  bid;
    uint8_t  bresp;
    // Read channels
    bool     arready;
    bool     rvalid;
    uint8_t  rid;
    uint32_t rdata;
    bool     rlast;
    uint8_t  rresp;

    axi_s2m()
    {
        awready = true; wready = true;
        bvalid  = false; bid = 0; bresp = AXI_RESP_DECERR;
        arready = true;
        rvalid  = false; rid = 0; rdata = 0; rlast = false; rresp = AXI_RESP_DECERR;
    }
};

#endif
