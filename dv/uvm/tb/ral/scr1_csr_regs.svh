// ============================================================
// File    : scr1_csr_regs.svh
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// RAL register classes of the SCR1 M-mode CSR subset (RV32,
// milestone 3). Field layout per scr1/src/includes/scr1_csr.svh;
// reset constants per scr1_cfg_pkg (per-CFG). Class style follows
// rv_csr_uvm_ral_unloader/src/csr.
// ============================================================

// mstatus (0x300): MIE[3], MPIE[7], MPP[12:11]=3 (hardwired M-only)
class scr1_csr_mstatus_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mstatus_reg )

  rand uvm_reg_field mie;
  rand uvm_reg_field mpie;
  rand uvm_reg_field mpp;

  function new( string name = "scr1_csr_mstatus_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mie = uvm_reg_field::type_id::create("mie");
    mie.configure( .parent(this), .size(1), .lsb_pos(MSTATUS_MIE_BIT), .access("RW"),
                   .volatile(0), .reset('0), .has_reset(1),
                   .is_rand(1), .individually_accessible(1) );
    mpie = uvm_reg_field::type_id::create("mpie");
    mpie.configure( .parent(this), .size(1), .lsb_pos(MSTATUS_MPIE_BIT), .access("RW"),
                    .volatile(0), .reset(MSTATUS_MPIE >> MSTATUS_MPIE_BIT), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
    mpp = uvm_reg_field::type_id::create("mpp");
    mpp.configure( .parent(this), .size(2), .lsb_pos(MSTATUS_MPP_LSB), .access("RO"),
                   .volatile(0), .reset(MSTATUS_MPP >> MSTATUS_MPP_LSB), .has_reset(1),
                   .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mstatus_reg

// misa (0x301): read-only, per-CFG constant
class scr1_csr_misa_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_misa_reg )

  rand uvm_reg_field misa;

  function new( string name = "scr1_csr_misa_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    misa = uvm_reg_field::type_id::create("misa");
    misa.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RO"),
                    .volatile(0), .reset(MISA_RST_VAL), .has_reset(1),
                    .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_misa_reg

// mie (0x304): MSIE[3], MTIE[7], MEIE[11]
class scr1_csr_mie_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mie_reg )

  rand uvm_reg_field msie;
  rand uvm_reg_field mtie;
  rand uvm_reg_field meie;

  function new( string name = "scr1_csr_mie_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    msie = uvm_reg_field::type_id::create("msie");
    msie.configure( .parent(this), .size(1), .lsb_pos(MIE_MSIE_BIT), .access("RW"),
                    .volatile(0), .reset('0), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
    mtie = uvm_reg_field::type_id::create("mtie");
    mtie.configure( .parent(this), .size(1), .lsb_pos(MIE_MTIE_BIT), .access("RW"),
                    .volatile(0), .reset('0), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
    meie = uvm_reg_field::type_id::create("meie");
    meie.configure( .parent(this), .size(1), .lsb_pos(MIE_MEIE_BIT), .access("RW"),
                    .volatile(0), .reset('0), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mie_reg

// mtvec (0x305): MODE[1:0], BASE[31:2] (bits [5:0] always zero)
class scr1_csr_mtvec_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mtvec_reg )

  rand uvm_reg_field mode;
  rand uvm_reg_field base;

  function new( string name = "scr1_csr_mtvec_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mode = uvm_reg_field::type_id::create("mode");
    mode.configure( .parent(this), .size(MTVEC_MODE_BITS), .lsb_pos(0), .access("RW"),
                    .volatile(0), .reset('0), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
    base = uvm_reg_field::type_id::create("base");
    base.configure( .parent(this), .size(XLEN - MTVEC_MODE_BITS), .lsb_pos(MTVEC_MODE_BITS), .access("RW"),
                    .volatile(0), .reset(MTVEC_RST_VAL >> MTVEC_MODE_BITS), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mtvec_reg

// mscratch (0x340)
class scr1_csr_mscratch_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mscratch_reg )

  rand uvm_reg_field mscratch;

  function new( string name = "scr1_csr_mscratch_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mscratch = uvm_reg_field::type_id::create("mscratch");
    mscratch.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                        .volatile(0), .reset('0), .has_reset(1),
                        .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mscratch_reg

// mepc (0x341)
class scr1_csr_mepc_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mepc_reg )

  rand uvm_reg_field mepc;

  function new( string name = "scr1_csr_mepc_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mepc = uvm_reg_field::type_id::create("mepc");
    mepc.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                    .volatile(0), .reset('0), .has_reset(1),
                    .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mepc_reg

// mcause (0x342): EC[5:0], IRQ[31]
class scr1_csr_mcause_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mcause_reg )

  rand uvm_reg_field ec;
  rand uvm_reg_field irq;

  function new( string name = "scr1_csr_mcause_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    ec = uvm_reg_field::type_id::create("ec");
    // arch EC field per scr1_csr.svh (bits [5:0]); SCR1 WARL stores
    // only ec[3:0] - the legalizer masks via MCAUSE_MASK
    ec.configure( .parent(this), .size(6), .lsb_pos(0), .access("RW"),
                  .volatile(0), .reset('0), .has_reset(1),
                  .is_rand(1), .individually_accessible(1) );
    irq = uvm_reg_field::type_id::create("irq");
    irq.configure( .parent(this), .size(1), .lsb_pos(XLEN-1), .access("RW"),
                   .volatile(0), .reset('0), .has_reset(1),
                   .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mcause_reg

// mtval (0x343)
class scr1_csr_mtval_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mtval_reg )

  rand uvm_reg_field mtval;

  function new( string name = "scr1_csr_mtval_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mtval = uvm_reg_field::type_id::create("mtval");
    mtval.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                     .volatile(0), .reset('0), .has_reset(1),
                     .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mtval_reg

// mip (0x344): MSIP[3], MTIP[7], MEIP[11] - read-only mirror of irq lines
class scr1_csr_mip_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mip_reg )

  rand uvm_reg_field msip;
  rand uvm_reg_field mtip;
  rand uvm_reg_field meip;

  function new( string name = "scr1_csr_mip_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    msip = uvm_reg_field::type_id::create("msip");
    msip.configure( .parent(this), .size(1), .lsb_pos(MIE_MSIE_BIT), .access("RO"),
                    .volatile(1), .reset('0), .has_reset(1),
                    .is_rand(0), .individually_accessible(1) );
    mtip = uvm_reg_field::type_id::create("mtip");
    mtip.configure( .parent(this), .size(1), .lsb_pos(MIE_MTIE_BIT), .access("RO"),
                    .volatile(1), .reset('0), .has_reset(1),
                    .is_rand(0), .individually_accessible(1) );
    meip = uvm_reg_field::type_id::create("meip");
    meip.configure( .parent(this), .size(1), .lsb_pos(MIE_MEIE_BIT), .access("RO"),
                    .volatile(1), .reset('0), .has_reset(1),
                    .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mip_reg

// mcounten (0x7E0, SCR1 custom): CY[0], IR[2]
class scr1_csr_mcounten_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mcounten_reg )

  rand uvm_reg_field cy;
  rand uvm_reg_field ir;

  function new( string name = "scr1_csr_mcounten_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    cy = uvm_reg_field::type_id::create("cy");
    cy.configure( .parent(this), .size(1), .lsb_pos(MCOUNTEN_CY_BIT), .access("RW"),
                  .volatile(0), .reset(MCOUNTEN_RST_VAL[MCOUNTEN_CY_BIT]), .has_reset(1),
                  .is_rand(1), .individually_accessible(1) );
    ir = uvm_reg_field::type_id::create("ir");
    ir.configure( .parent(this), .size(1), .lsb_pos(MCOUNTEN_IR_BIT), .access("RW"),
                  .volatile(0), .reset(MCOUNTEN_RST_VAL[MCOUNTEN_IR_BIT]), .has_reset(1),
                  .is_rand(1), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mcounten_reg

// Counters (RV32 halves), volatile: mcycle B00 / minstret B02 /
// mcycleh B80 / minstreth B82
class scr1_csr_mcycle_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mcycle_reg )

  rand uvm_reg_field mcycle;

  function new( string name = "scr1_csr_mcycle_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mcycle = uvm_reg_field::type_id::create("mcycle");
    mcycle.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                      .volatile(1), .reset('0), .has_reset(1),
                      .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mcycle_reg

class scr1_csr_minstret_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_minstret_reg )

  rand uvm_reg_field minstret;

  function new( string name = "scr1_csr_minstret_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    minstret = uvm_reg_field::type_id::create("minstret");
    minstret.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                        .volatile(1), .reset('0), .has_reset(1),
                        .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_minstret_reg

class scr1_csr_mcycleh_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mcycleh_reg )

  rand uvm_reg_field mcycleh;

  function new( string name = "scr1_csr_mcycleh_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mcycleh = uvm_reg_field::type_id::create("mcycleh");
    mcycleh.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                       .volatile(1), .reset('0), .has_reset(1),
                       .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mcycleh_reg

class scr1_csr_minstreth_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_minstreth_reg )

  rand uvm_reg_field minstreth;

  function new( string name = "scr1_csr_minstreth_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    minstreth = uvm_reg_field::type_id::create("minstreth");
    minstreth.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RW"),
                         .volatile(1), .reset('0), .has_reset(1),
                         .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_minstreth_reg

// Machine information (read-only constants)
class scr1_csr_mvendorid_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mvendorid_reg )

  rand uvm_reg_field mvendorid;

  function new( string name = "scr1_csr_mvendorid_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mvendorid = uvm_reg_field::type_id::create("mvendorid");
    mvendorid.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RO"),
                         .volatile(0), .reset(MVENDORID_RST_VAL), .has_reset(1),
                         .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mvendorid_reg

class scr1_csr_marchid_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_marchid_reg )

  rand uvm_reg_field marchid;

  function new( string name = "scr1_csr_marchid_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    marchid = uvm_reg_field::type_id::create("marchid");
    marchid.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RO"),
                       .volatile(0), .reset(MARCHID_RST_VAL), .has_reset(1),
                       .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_marchid_reg

class scr1_csr_mimpid_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mimpid_reg )

  rand uvm_reg_field mimpid;

  function new( string name = "scr1_csr_mimpid_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mimpid = uvm_reg_field::type_id::create("mimpid");
    mimpid.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RO"),
                      .volatile(0), .reset(MIMPID_RST_VAL), .has_reset(1),
                      .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mimpid_reg

class scr1_csr_mhartid_reg extends uvm_reg;
  `uvm_object_utils( scr1_csr_mhartid_reg )

  rand uvm_reg_field mhartid;

  function new( string name = "scr1_csr_mhartid_reg" );
    super.new( .name(name), .n_bits($bits(csr_data_t)), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    mhartid = uvm_reg_field::type_id::create("mhartid");
    mhartid.configure( .parent(this), .size($bits(csr_data_t)), .lsb_pos(0), .access("RO"),
                       .volatile(0), .reset(MHARTID_RST_VAL), .has_reset(1),
                       .is_rand(0), .individually_accessible(1) );
  endfunction : build
endclass : scr1_csr_mhartid_reg
