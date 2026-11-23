// ============================================================
// File    : scr1_mem_txn.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// AHB transaction of the memory agent: one completed transfer
// (address accept + data response) of either channel, observed by
// the monitor; also carries the side-channel fields arming the
// driver's ERROR injection / delay windows. Published on the
// monitor ap (hook for the future DRVFuzz store-stream
// comparison). No rand string fields (known simulator limit).
// ============================================================
  class scr1_mem_txn extends uvm_sequence_item;

    rand bit          is_imem;    // channel: 1 = imem, 0 = dmem
    rand ahb_addr_t   addr;       // transfer address (address phase)
    rand bit          write;      // dmem_hwrite (imem: always 0)
    rand ahb_hsize_t  size;       // hsize of the transfer
    rand ahb_data_t   wdata;      // hwdata sampled in the data phase
    rand ahb_data_t   rdata;      // hrdata of the response
    rand bit          resp_err;   // hresp == ERROR on the response
    rand int unsigned rdelay;     // MINIMUM delay of a seq-driven delay
                                  // window (delay_mod items)
    rand int unsigned rdelay_max; // side-channel ONLY: window maximum delay;
                                  // drawn per matching transfer from the
                                  // driver's seeded PRNG when > rdelay
    rand bit          delay_mod;  // side-channel ONLY: 1 = arm a delay window
                                  // in the driver (scr1_mem_delay_seq); the
                                  // monitor leaves it 0 on observed txns
    rand mem_delay_ch_t delay_ch; // window channel: DMEM / IMEM / BOTH
    rand ahb_addr_t   addr_hi;    // window upper bound, inclusive (addr = lower)
    rand int unsigned delay_count;// transfers the window modulates (0 = unlimited)
    rand int unsigned err_count;  // side-channel ONLY: matching transfers to
                                  // answer hresp ERROR (scr1_mem_err_seq ->
                                  // driver injection map); monitor leaves 0

    `uvm_object_utils_begin(scr1_mem_txn)
      `uvm_field_int (is_imem,     UVM_ALL_ON)
      `uvm_field_int (addr,        UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (write,       UVM_ALL_ON)
      `uvm_field_int (size,        UVM_ALL_ON | UVM_BIN)
      `uvm_field_int (wdata,       UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (rdata,       UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (resp_err,    UVM_ALL_ON)
      `uvm_field_int (rdelay,      UVM_ALL_ON | UVM_DEC)
      `uvm_field_int (rdelay_max,  UVM_ALL_ON | UVM_DEC)
      `uvm_field_int (delay_mod,   UVM_ALL_ON)
      `uvm_field_int (delay_ch,    UVM_ALL_ON | UVM_DEC)
      `uvm_field_int (addr_hi,     UVM_ALL_ON | UVM_HEX)
      `uvm_field_int (delay_count, UVM_ALL_ON | UVM_DEC)
      `uvm_field_int (err_count,   UVM_ALL_ON | UVM_DEC)
    `uvm_object_utils_end

    function new(string name = "scr1_mem_txn");
      super.new(name);
    endfunction : new

    virtual function string convert2string();
      return $sformatf("%s %s addr=0x%08h size=%03b wdata=0x%08h rdata=0x%08h resp=%s",
                       is_imem ? "IMEM" : "DMEM",
                       write   ? "WR " : "RD ",
                       addr, size, wdata, rdata,
                       resp_err ? "ERROR" : "OKAY");
    endfunction : convert2string

  endclass : scr1_mem_txn
