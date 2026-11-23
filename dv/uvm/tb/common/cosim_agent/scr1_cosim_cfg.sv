// ============================================================
// File    : scr1_cosim_cfg.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Cosim agent configuration object (ibex core_ibex_cosim_cfg
// pattern). Backend plusargs: +SPIKE_HEX -> COSIM_SPIKE (wins),
// +REF_CSV -> COSIM_CSV, neither -> COSIM_NONE (agent inert).
// Fields are per-build constants but stay cfg-driven for the DPI
// init (ibex init_cosim); defaults: dv/uvm/README.md, 2B section.
// ============================================================

  // Reference-model backend selection
  typedef enum bit [1:0] {
    COSIM_NONE  = 2'b00,  // no reference configured: agent inert
    COSIM_SPIKE = 2'b01,  // 2B: in-process Spike via DPI-C
    COSIM_CSV   = 2'b10   // 2A: offline replay of a Spike CSV log
  } scr1_cosim_mode_e;

  class scr1_cosim_cfg extends uvm_object;

    scr1_cosim_mode_e mode;
    // test vector (verilog hex) for the Spike memory model (+SPIKE_HEX)
    string            hex_path;
    // pre-recorded Spike commit log, tools/spike_log2csv.py (+REF_CSV)
    string            csv_path;
    // Spike ISA string of the golden model
    string            isa;
    xlen_word_t       start_pc;
    // golden-model reset calibration: SCR1 boots mtvec=MTVEC_RST_VAL,
    // mstatus.MPIE=1; plain Spike resets them to 0/0x1800
    csr_data_t        mtvec_reset;
    csr_data_t        mstatus_reset;

    `uvm_object_utils_begin(scr1_cosim_cfg)
      `uvm_field_enum(scr1_cosim_mode_e, mode, UVM_DEFAULT)
      `uvm_field_string(hex_path,      UVM_DEFAULT)
      `uvm_field_string(csv_path,      UVM_DEFAULT)
      `uvm_field_string(isa,           UVM_DEFAULT)
      `uvm_field_int(start_pc,         UVM_DEFAULT | UVM_HEX)
      `uvm_field_int(mtvec_reset,      UVM_DEFAULT | UVM_HEX)
      `uvm_field_int(mstatus_reset,    UVM_DEFAULT | UVM_HEX)
    `uvm_object_utils_end

    function new(string name = "scr1_cosim_cfg");
      super.new(name);
      mode          = COSIM_NONE;
      hex_path      = "";
      csv_path      = "";
      isa           = SPIKE_ISA;
      start_pc      = RST_VECTOR;
      mtvec_reset   = MTVEC_RST_VAL;
      mstatus_reset = MSTATUS_RST_VAL;
    endfunction : new

    function string mode_name();
      case (mode)
        COSIM_SPIKE: return "spike";
        COSIM_CSV:   return "csv";
        default:     return "none";
      endcase
    endfunction : mode_name

  endclass : scr1_cosim_cfg
