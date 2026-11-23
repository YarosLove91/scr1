// ============================================================
// File    : scr1_commit_tr.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Commit transaction (milestone 2): carries one scr1_commit_s
// record from the DUT monitor (or the reference model) to the
// differential scoreboard. The payload struct lives in
// scr1_tb_pkg.
// ============================================================
  class scr1_commit_tr extends uvm_sequence_item;

    scr1_commit_s c;

    `uvm_object_utils_begin(scr1_commit_tr)
      `uvm_field_int(c, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "scr1_commit_tr");
      super.new(name);
    endfunction : new

    virtual function string convert2string();
      if (c.trap) begin
        return $sformatf("TRAP  pc=0x%08h mcause=0x%08h mtval_src=0x%08h",
                         c.pc, c.mcause, c.trap_val);
      end
      return $sformatf("pc=0x%08h instr=0x%08h rd_wr=%0b x%0d=0x%08h mem=%0b%s%0h%s",
          c.pc, c.instr, c.rd_wr, c.rd_addr, c.rd_data,
          c.mem_we, (c.mem_valid ? " @0x" : ""), (c.mem_valid ? c.mem_addr : '0),
          ((c.csr_r_req || c.csr_w_req) ? $sformatf(" %s csr[%03h r=%0b w=%0b rdata=0x%08h wdata=0x%08h rs1=0x%08h]",
              scr1_csr_txn_name(scr1_csr_txn_of(c.instr)),
              c.csr_addr, c.csr_r_req, c.csr_w_req, c.csr_r_data, c.csr_w_data, c.csr_rs1) : ""));
    endfunction : convert2string

  endclass : scr1_commit_tr
