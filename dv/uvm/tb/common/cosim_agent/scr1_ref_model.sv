// ============================================================
// File    : scr1_ref_model.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Reference-model seam of the cosim scoreboard: pull API, one
// golden commit per DUT commit. Backends (both cfg-driven, no own
// plusarg reads): scr1_ref_csv - 2A offline replay of a Spike log
// (tools/spike_log2csv.py, +REF_CSV; SCR1-specific, README 2A) and
// scr1_ref_spike - 2B in-process DPI (+SPIKE_HEX, SCR1_SPIKE_COSIM).
// CSV record: <pc_hex>,<instr_hex>,<wr 0|1>,<rd_dec>,<rd_data_hex>
// ('#' comment); the 2A converter emits NO trap records, so DUT
// trap commits are skipped for it - see supports_traps().
// ============================================================

  virtual class scr1_ref_model extends uvm_component;
    `uvm_component_utils(scr1_ref_model)

    // agent cfg (assigned by the scoreboard right after creation, consumed
    // in build_phase - the parent builds before the child, ibex pattern)
    scr1_cosim_cfg cfg;

    function new(string name = "scr1_ref_model", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    // 1 = a golden commit was produced, 0 = reference exhausted
    pure virtual function bit get_next(output scr1_commit_s c);
    pure virtual function int unsigned remaining();
    virtual function string model_name();
      return "ref_model";
    endfunction : model_name

    // 1 = the model emits golden TRAP records (trap=1, mcause, pc=mepc) for
    // precise-exception comparison; 0 = no trap records (2A CSV), DUT trap
    // commits are skipped without consuming goldens
    virtual function bit supports_traps();
      return 1'b0;
    endfunction : supports_traps

    // 1 = the model reports CURRENT CSR values (live golden state, 2B) for
    // the run-exit cross-check; 0 = replay models (2A) keep no CSR state
    virtual function bit supports_csr_read();
      return 1'b0;
    endfunction : supports_csr_read

    // 1 = v holds the current CSR value; 0 = unsupported/not readable
    virtual function bit get_csr_value(csr_addr_t a, output csr_data_t v);
      return 1'b0;
    endfunction : get_csr_value

  endclass : scr1_ref_model

  // ---- 2A: CSV replay of a pre-recorded Spike commit log ----
  class scr1_ref_csv extends scr1_ref_model;
    `uvm_component_utils(scr1_ref_csv)

    protected scr1_commit_s q[$];
    protected string        csv_path;
    protected int unsigned  load_errors;

    function new(string name = "scr1_ref_csv", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function string model_name();
      return $sformatf("ref_csv(%s)", csv_path);
    endfunction : model_name

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if ((cfg == null) || (cfg.csv_path == "")) begin
        `uvm_fatal({get_type_name(), ".NOCSV"},
            {"scr1_ref_csv selected but the agent cfg carries no csv_path ",
             "(+REF_CSV=<path> plusarg missing?)"})
      end
      csv_path = cfg.csv_path;
      load_csv(csv_path);
    endfunction : build_phase

    protected function void load_csv(string path);
      int fd;
      string line;
      int code;
      xlen_word_t  pc;
      raw_opcode_t instr;
      xlen_word_t  val;
      int wr, rd;
      scr1_commit_s c;
      int unsigned n;

      fd = $fopen(path, "r");
      if (fd == 0) begin
        `uvm_fatal({get_type_name(), ".OPEN"},
            $sformatf("cannot open REF_CSV file %s", path))
      end
      n = 0;
      while ($fgets(line, fd) > 0) begin
        // strip trailing newline
        if ((line.len() > 0) && ((line[line.len()-1] == "\n") || (line[line.len()-1] == 8'h0A)))
          line = line.substr(0, line.len()-2);
        if ((line.len() == 0) || (line[0] == "#")) continue;
        code = $sscanf(line, "%h,%h,%d,%d,%h", pc, instr, wr, rd, val);
        if (code != 5) begin
          load_errors++;
          if (load_errors <= 5) begin
            `uvm_warning({get_type_name(), ".PARSE"},
                $sformatf("cannot parse CSV line: %s", line))
          end
          continue;
        end
        c = '0;
        c.valid   = 1'b1;
        c.pc      = pc;
        c.instr   = instr;
        c.rd_wr   = (wr != 0) && (rd != 0);
        c.rd_addr = reg_idx_t'(rd);
        c.rd_data = val;
        q.push_back(c);
        n++;
      end
      $fclose(fd);
      `uvm_info({get_type_name(), ".LOADED"},
          $sformatf("%0d golden commits from %s (parse errors: %0d)", n, path, load_errors),
          UVM_LOW)
    endfunction : load_csv

    virtual function bit get_next(output scr1_commit_s c);
      if (q.size() == 0) return 1'b0;
      c = q.pop_front();
      return 1'b1;
    endfunction : get_next

    virtual function int unsigned remaining();
      return q.size();
    endfunction : remaining

  endclass : scr1_ref_csv
