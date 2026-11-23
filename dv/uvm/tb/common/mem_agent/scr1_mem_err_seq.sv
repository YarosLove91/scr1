// ============================================================
// File    : scr1_mem_err_seq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Sequence-driven ERROR injection (side channel of
// scr1_mem_sequencer): each entry arms hresp=ERROR on `count`
// transfers whose word address matches `addr` on the selected
// channel - the runtime, counted equivalent of the
// +AGENT_*_ERROR_ADDR plusargs. The driver accumulates the items
// in an injection map OFF the bus-FSM critical path (never blocks
// on get_next_item); reactive bus timing is untouched.
// ============================================================
  class scr1_mem_err_seq extends uvm_sequence #(scr1_mem_txn);
    `uvm_object_utils(scr1_mem_err_seq)

    // injection entries (parallel queues); add via add_err()
    protected ahb_addr_t   m_addr [$];
    protected int unsigned m_count[$];
    protected bit          m_imem [$];

    function new(string name = "scr1_mem_err_seq");
      super.new(name);
    endfunction : new

    // arm `count` ERROR responses on the word address `addr`
    // (is_imem selects the channel; default dmem)
    virtual function void add_err(ahb_addr_t addr, int unsigned count,
                                  bit is_imem = 1'b0);
      m_addr.push_back(addr);
      m_count.push_back(count);
      m_imem.push_back(is_imem);
    endfunction : add_err

    virtual task body();
      scr1_mem_txn item;
      if (m_addr.size() == 0) begin
        `uvm_warning({get_type_name(), ".EMPTY"},
                     "no ERROR-injection entries armed, nothing to send")
        return;
      end
      foreach (m_addr[i]) begin
        item = scr1_mem_txn::type_id::create($sformatf("err%0d", i));
        start_item(item);
        item.is_imem   = m_imem[i];
        item.addr      = m_addr[i];
        item.write     = 1'b0;          // channel-agnostic injection flag
        item.resp_err  = 1'b1;          // intent: inject ERROR
        item.err_count = m_count[i];    // number of matching transfers
        finish_item(item);
        `uvm_info({get_type_name(), ".ARM"},
            $sformatf("armed %s ERROR x%0d on word addr 0x%08h",
                      m_imem[i] ? "IMEM" : "DMEM", m_count[i],
                      (m_addr[i] & AHB_WORD_MASK)),
            UVM_LOW)
      end
    endtask : body

  endclass : scr1_mem_err_seq
