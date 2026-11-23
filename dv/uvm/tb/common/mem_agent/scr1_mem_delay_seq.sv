// ============================================================
// File    : scr1_mem_delay_seq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Sequence-driven WAIT-STATE modulation (rdelay side channel of
// scr1_mem_sequencer). Each entry arms one delay WINDOW: matching
// transfers take their address-phase wait-state target from
// rdelay..rdelay_max, drawn by the driver from a DEDICATED
// xorshift32 stream (+AGENT_STALL_SEED; min==max: fixed, no draw)
// - bit-reproducible. PRIORITY: a matching window OVERRIDES both
// stall knobs; with no window the FSM is bit-identical to the
// reactive-only agent. Items are consumed off the bus-FSM critical
// path. Details: dv/uvm/README.md (seq delay modulation).
// ============================================================
  class scr1_mem_delay_seq extends uvm_sequence #(scr1_mem_txn);
    `uvm_object_utils(scr1_mem_delay_seq)

    // delay window entries (parallel queues); add via add_delay()
    protected ahb_addr_t     m_lo   [$];
    protected ahb_addr_t     m_hi   [$];
    protected int unsigned   m_dmin [$];
    protected int unsigned   m_dmax [$];
    protected mem_delay_ch_t m_ch   [$];  // DELAY_CH_DMEM / IMEM / BOTH
    protected int unsigned   m_count[$];  // 0 = unlimited

    function new(string name = "scr1_mem_delay_seq");
      super.new(name);
    endfunction : new

    // arm a window on [lo,hi] byte addresses, inclusive (single word:
    // lo = addr & AHB_WORD_MASK, hi = lo | ~AHB_WORD_MASK; whole space:
    // lo=0, hi='1); ch: "dmem"|"imem"|"both"; count: 0 = unlimited
    virtual function void add_delay(ahb_addr_t lo, ahb_addr_t hi,
                                    int unsigned dmin, int unsigned dmax,
                                    string ch = "dmem",
                                    int unsigned count = 0);
      m_lo.push_back(lo);
      m_hi.push_back(hi);
      m_dmin.push_back(dmin);
      m_dmax.push_back(dmax);
      m_ch.push_back((ch == "imem") ? DELAY_CH_IMEM :
                     ((ch == "both") ? DELAY_CH_BOTH : DELAY_CH_DMEM));
      m_count.push_back(count);
    endfunction : add_delay

    virtual task body();
      scr1_mem_txn item;
      if (m_lo.size() == 0) begin
        `uvm_warning({get_type_name(), ".EMPTY"},
                     "no delay windows armed, nothing to send")
        return;
      end
      foreach (m_lo[i]) begin
        item = scr1_mem_txn::type_id::create($sformatf("dly%0d", i));
        start_item(item);
        item.delay_mod   = 1'b1;
        item.addr        = m_lo[i];
        item.addr_hi     = m_hi[i];
        item.delay_ch    = m_ch[i];
        item.rdelay      = m_dmin[i];
        item.rdelay_max  = m_dmax[i];
        item.delay_count = m_count[i];
        finish_item(item);
        `uvm_info({get_type_name(), ".ARM"},
            $sformatf({"armed delay window: ch=%s range 0x%08h..0x%08h ",
                       "delay %0d..%0d count=%0d (0 = unlimited)"},
                      (m_ch[i] == DELAY_CH_IMEM) ? "imem" :
                      ((m_ch[i] == DELAY_CH_BOTH) ? "both" : "dmem"),
                      m_lo[i], m_hi[i], m_dmin[i], m_dmax[i], m_count[i]),
            UVM_LOW)
      end
    endtask : body

  endclass : scr1_mem_delay_seq
