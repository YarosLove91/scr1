// ============================================================
// File    : scr1_csr_blocks.svh
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// RAL reg_blocks of the SCR1 M-mode CSR subset (milestone 3):
// scr1_csr_sm_block (trap setup/handling + info + mcounten),
// scr1_csr_cnt_block (RV32 counter halves), scr1_csr_top_block
// (single model, two submaps, create_map n_bytes=XLEN/8).
// Structure follows rv_csr_uvm_ral_unloader/src/csr; addresses
// per scr1/src/includes/scr1_csr.svh.
// ============================================================

class scr1_csr_sm_block extends uvm_reg_block;
  `uvm_object_utils( scr1_csr_sm_block )

  rand scr1_csr_mstatus_reg   mstatus;
  rand scr1_csr_misa_reg      misa;
  rand scr1_csr_mie_reg       mie;
  rand scr1_csr_mtvec_reg     mtvec;
  rand scr1_csr_mscratch_reg  mscratch;
  rand scr1_csr_mepc_reg      mepc;
  rand scr1_csr_mcause_reg    mcause;
  rand scr1_csr_mtval_reg     mtval;
  rand scr1_csr_mip_reg       mip;
  rand scr1_csr_mcounten_reg  mcounten;
  rand scr1_csr_mvendorid_reg mvendorid;
  rand scr1_csr_marchid_reg   marchid;
  rand scr1_csr_mimpid_reg    mimpid;
  rand scr1_csr_mhartid_reg   mhartid;

  uvm_reg_map csr_map;

  function new( string name = "scr1_csr_sm_block" );
    super.new( .name(name), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    default_map = create_map("csr_map", 'h0, XLEN/8, UVM_LITTLE_ENDIAN, 1);
    csr_map = default_map;

    mstatus = scr1_csr_mstatus_reg::type_id::create("mstatus");
    mstatus.configure( .blk_parent(this) );
    mstatus.build();
    csr_map.add_reg(mstatus, CSR_MSTATUS, "RW");

    misa = scr1_csr_misa_reg::type_id::create("misa");
    misa.configure( .blk_parent(this) );
    misa.build();
    csr_map.add_reg(misa, CSR_MISA, "RO");

    mie = scr1_csr_mie_reg::type_id::create("mie");
    mie.configure( .blk_parent(this) );
    mie.build();
    csr_map.add_reg(mie, CSR_MIE, "RW");

    mtvec = scr1_csr_mtvec_reg::type_id::create("mtvec");
    mtvec.configure( .blk_parent(this) );
    mtvec.build();
    csr_map.add_reg(mtvec, CSR_MTVEC, "RW");

    mscratch = scr1_csr_mscratch_reg::type_id::create("mscratch");
    mscratch.configure( .blk_parent(this) );
    mscratch.build();
    csr_map.add_reg(mscratch, CSR_MSCRATCH, "RW");

    mepc = scr1_csr_mepc_reg::type_id::create("mepc");
    mepc.configure( .blk_parent(this) );
    mepc.build();
    csr_map.add_reg(mepc, CSR_MEPC, "RW");

    mcause = scr1_csr_mcause_reg::type_id::create("mcause");
    mcause.configure( .blk_parent(this) );
    mcause.build();
    csr_map.add_reg(mcause, CSR_MCAUSE, "RW");

    mtval = scr1_csr_mtval_reg::type_id::create("mtval");
    mtval.configure( .blk_parent(this) );
    mtval.build();
    csr_map.add_reg(mtval, CSR_MTVAL, "RW");

    mip = scr1_csr_mip_reg::type_id::create("mip");
    mip.configure( .blk_parent(this) );
    mip.build();
    csr_map.add_reg(mip, CSR_MIP, "RO");

    mcounten = scr1_csr_mcounten_reg::type_id::create("mcounten");
    mcounten.configure( .blk_parent(this) );
    mcounten.build();
    csr_map.add_reg(mcounten, CSR_MCOUNTEN, "RW");

    mvendorid = scr1_csr_mvendorid_reg::type_id::create("mvendorid");
    mvendorid.configure( .blk_parent(this) );
    mvendorid.build();
    csr_map.add_reg(mvendorid, CSR_MVENDORID, "RO");

    marchid = scr1_csr_marchid_reg::type_id::create("marchid");
    marchid.configure( .blk_parent(this) );
    marchid.build();
    csr_map.add_reg(marchid, CSR_MARCHID, "RO");

    mimpid = scr1_csr_mimpid_reg::type_id::create("mimpid");
    mimpid.configure( .blk_parent(this) );
    mimpid.build();
    csr_map.add_reg(mimpid, CSR_MIMPID, "RO");

    mhartid = scr1_csr_mhartid_reg::type_id::create("mhartid");
    mhartid.configure( .blk_parent(this) );
    mhartid.build();
    csr_map.add_reg(mhartid, CSR_MHARTID, "RO");
  endfunction : build
endclass : scr1_csr_sm_block


class scr1_csr_cnt_block extends uvm_reg_block;
  `uvm_object_utils( scr1_csr_cnt_block )

  rand scr1_csr_mcycle_reg    mcycle;
  rand scr1_csr_minstret_reg  minstret;
  rand scr1_csr_mcycleh_reg   mcycleh;
  rand scr1_csr_minstreth_reg minstreth;

  uvm_reg_map csr_map;

  function new( string name = "scr1_csr_cnt_block" );
    super.new( .name(name), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    default_map = create_map("csr_map", 'h0, XLEN/8, UVM_LITTLE_ENDIAN, 1);
    csr_map = default_map;

    mcycle = scr1_csr_mcycle_reg::type_id::create("mcycle");
    mcycle.configure( .blk_parent(this) );
    mcycle.build();
    csr_map.add_reg(mcycle, CSR_MCYCLE, "RW");

    minstret = scr1_csr_minstret_reg::type_id::create("minstret");
    minstret.configure( .blk_parent(this) );
    minstret.build();
    csr_map.add_reg(minstret, CSR_MINSTRET, "RW");

    mcycleh = scr1_csr_mcycleh_reg::type_id::create("mcycleh");
    mcycleh.configure( .blk_parent(this) );
    mcycleh.build();
    csr_map.add_reg(mcycleh, CSR_MCYCLEH, "RW");

    minstreth = scr1_csr_minstreth_reg::type_id::create("minstreth");
    minstreth.configure( .blk_parent(this) );
    minstreth.build();
    csr_map.add_reg(minstreth, CSR_MINSTRETH, "RW");
  endfunction : build
endclass : scr1_csr_cnt_block


class scr1_csr_top_block extends uvm_reg_block;
  `uvm_object_utils( scr1_csr_top_block )

  rand scr1_csr_sm_block  Sm;
  rand scr1_csr_cnt_block Cnt;

  uvm_reg_map csr_map;

  function new( string name = "scr1_csr_top_block" );
    super.new( .name(name), .has_coverage(UVM_NO_COVERAGE) );
  endfunction : new

  virtual function void build();
    csr_map = create_map("csr_map", 'h0, XLEN/8, UVM_LITTLE_ENDIAN, 1);

    // Flat 12-bit CSR space: both submaps are based at offset '0 -
    // every register carries its full CSR address as its own offset
    Sm = scr1_csr_sm_block::type_id::create("Sm");
    Sm.configure( this );
    Sm.build();
    csr_map.add_submap( Sm.csr_map, '0 );

    Cnt = scr1_csr_cnt_block::type_id::create("Cnt");
    Cnt.configure( this );
    Cnt.build();
    csr_map.add_submap( Cnt.csr_map, '0 );

    lock_model();
  endfunction : build
endclass : scr1_csr_top_block
