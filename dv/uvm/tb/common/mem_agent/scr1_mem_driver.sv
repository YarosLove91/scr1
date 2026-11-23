// ============================================================
// File    : scr1_mem_driver.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Reactive AHB memory slave driver (stage B; donor: ibex
// ibex_mem_intf_response_driver - the bus is answered autonomously
// every clock through drv_cb, NOT by seq_items). A non-blocking
// sequencer side-channel arms ERROR injection and delay windows
// without ever stalling the bus FSM on get_next_item.
// The FSM mirrors the legacy scr1_memory_tb_ahb NO-DELAY mode
// (run-length parity: hello 16990 / isr_sample 457 / a5_1 17184):
// address + 1-clock data phase per transfer, idle cycles drive
// hready=1, pipelined NONSEQ accepted in the completing data
// cycle, legacy response asymmetry (imem OKAY always, dmem ERROR
// when no data phase completes), dmem write commit BEFORE the
// same-clock read latches (w_hazard forwarding), rst_n clears
// FSMs and device registers.
// Wait states land in the ADDRESS phase of idle-started transfers
// only (htrans!=IDLE keeps them visible to the fcov stall bins -
// the core bridges drop htrans to IDLE on a stalled data phase).
// Knobs: fixed +AGENT_IMEM/DMEM_STALL; random +AGENT_RANDOM_STALL/
// _SEED/_CH via a local xorshift32 (NOT $urandom - run length must
// be bit-reproducible); sequence delay windows override both
// (dedicated PRNG stream, see win_delay). Error injection:
// +AGENT_*_ERROR_ADDR plusargs or sequence-armed maps; imem ERROR
// = instruction access fault (mcause 1, EC1, fetch_fault vector).
// Unmapped dmem answers ERROR by design (stage-B deviation, see
// scr1_mem_model). Device/register semantics live in
// scr1_mem_model; program-driven IRQ registers are mirrored to the
// core here, the async TB stimulus is owned by the IRQ agent
// (scr1_irq_if OR-merge). Details: dv/uvm/README.md (milestone 5).
// ============================================================
  class scr1_mem_driver extends uvm_driver #(scr1_mem_txn);
    `uvm_component_utils(scr1_mem_driver)

    // channel indexes of the per-channel state arrays
    const int CH_IMEM = 0;
    const int CH_DMEM = 1;

    scr1_mem_vif   vif;
    scr1_mem_model model;

    // per-channel reactive FSM state
    bit          in_data   [AHB_CH_NUM];  // previous cycle completed a data phase
    int unsigned wcnt      [AHB_CH_NUM];  // address-phase wait counter
    bit          hrdy_prev [AHB_CH_NUM];  // hready driven during the sampled cycle
    ahb_addr_t   addr_l    [AHB_CH_NUM];  // latched transfer address
    bit          wr_l      [AHB_CH_NUM];  // latched write (dmem only)
    ahb_be_t     be_l      [AHB_CH_NUM];  // latched byte enables (dmem only)
    ahb_data_t   rdata_l   [AHB_CH_NUM];  // latched read response
    bit          err_l     [AHB_CH_NUM];  // respond ERROR to the latched transfer

    // knobs (+AGENT_* plusargs; runtime, no rebuild needed)
    int unsigned stall_n [AHB_CH_NUM];
    ahb_addr_t   err_addr;        // dmem ERROR injection word address
    bit          err_en;
    ahb_addr_t   imem_err_addr;   // imem ERROR injection word address
    bit          imem_err_en;     // (instruction access fault, EC1)

    // ---- random wait states (+AGENT_RANDOM_STALL=<max>, 0 = off = DEFAULT;
    //      +AGENT_STALL_SEED=<n>, default 1; +AGENT_RANDOM_STALL_CH=imem|dmem|
    //      both). max>0: per-transfer address-phase delay = deterministic
    //      pseudo-random 1..max (xorshift32 local state, NOT $urandom - run
    //      length reproducible from the seed); OVERRIDES the per-channel
    //      fixed stall; max=0: PRNG never advanced, timing bit-identical.
    int unsigned rand_max;        // AGENT_RANDOM_STALL max wait states (0 = off)
    int unsigned rand_seed;       // AGENT_STALL_SEED (default 1)
    bit          rand_ch   [AHB_CH_NUM]; // per-channel random enable (STALL_CH)
    int unsigned prng_state;      // xorshift32 state (local, deterministic)
    bit          use_random[AHB_CH_NUM]; // random active for this channel
    int unsigned eff_max   [AHB_CH_NUM]; // effective stall bound (random ? rand_max : stall_n)
    int unsigned stall_tgt [AHB_CH_NUM]; // per-transfer wait-state target

    // ---- sequencer-driven ERROR injection (side channel, non-blocking) ----
    // {word-aligned address -> remaining fire count}, filled by a process
    // SEPARATE from the bus FSM (get_next_item never blocks a bus cycle);
    // NOT cleared on reset - arming before reset release still fires.
    int unsigned inj_err_dmem [ahb_addr_t];
    int unsigned inj_err_imem [ahb_addr_t];

    // ---- sequencer-driven DELAY modulation (rdelay side channel) ----
    // Window queue filled by the same side-channel process, consulted
    // non-blockingly at the stall-target pick; an armed window OVERRIDES the
    // plusarg knobs, queue order = priority (first match wins). remain counts
    // modulated transfers (0 = unlimited). delay_prng_state is a DEDICATED
    // xorshift32 stream (window draws never perturb the random-knob stream).
    typedef struct packed {
      ahb_addr_t   lo;        // window lower bound (byte address, inclusive)
      ahb_addr_t   hi;        // window upper bound (byte address, inclusive)
      bit          ch_imem;   // window applies to the imem channel
      bit          ch_dmem;   // window applies to the dmem channel
      int unsigned dmin;      // minimum wait states (item rdelay)
      int unsigned dmax;      // maximum wait states (item rdelay_max)
      int unsigned remain;    // remaining modulated transfers (0 = unlimited)
    } delay_win_s;
    delay_win_s  delay_wins [$];
    int unsigned delay_prng_state;   // dedicated xorshift32 state (window draws)
    int unsigned delay_draws;        // statistic: window-modulated transfers

    function new(string name = "scr1_mem_driver", uvm_component parent = null);
      super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(scr1_mem_vif)::get(this, "", "mem_vif", vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "mem_vif not found in uvm_config_db (MEM_AGENT build?)")
      end
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
      super.run_phase(phase);

      // ---- knobs ----
      stall_n[CH_IMEM] = 0;
      stall_n[CH_DMEM] = 0;
      err_addr         = '0;
      imem_err_addr    = '0;
      void'($value$plusargs("AGENT_IMEM_STALL=%d",      stall_n[CH_IMEM]));
      void'($value$plusargs("AGENT_DMEM_STALL=%d",      stall_n[CH_DMEM]));
      err_en = $value$plusargs("AGENT_DMEM_ERROR_ADDR=%h", err_addr);
      imem_err_en = $value$plusargs("AGENT_IMEM_ERROR_ADDR=%h", imem_err_addr);

      // ---- random wait-state knobs (0 = off = deterministic, bit-identical) ----
      rand_max  = 0;
      rand_seed = 1;
      void'($value$plusargs("AGENT_RANDOM_STALL=%d", rand_max));
      void'($value$plusargs("AGENT_STALL_SEED=%d",   rand_seed));
      begin
        string ch;
        rand_ch[CH_IMEM] = 1'b1;
        rand_ch[CH_DMEM] = 1'b1;
        if ($value$plusargs("AGENT_RANDOM_STALL_CH=%s", ch)) begin
          rand_ch[CH_IMEM] = (ch == "imem") || (ch == "both");
          rand_ch[CH_DMEM] = (ch == "dmem") || (ch == "both");
        end
      end
      // xorshift32 must never see a zero state
      prng_state             = (rand_seed != 0) ? rand_seed : 1;
      // dedicated window-draw stream (same seed, separate state)
      delay_prng_state       = (rand_seed != 0) ? rand_seed : 1;
      delay_draws            = 0;
      use_random[CH_IMEM]    = rand_ch[CH_IMEM] && (rand_max > 0);
      use_random[CH_DMEM]    = rand_ch[CH_DMEM] && (rand_max > 0);
      eff_max[CH_IMEM]       = use_random[CH_IMEM] ? rand_max : stall_n[CH_IMEM];
      eff_max[CH_DMEM]       = use_random[CH_DMEM] ? rand_max : stall_n[CH_DMEM];
      stall_tgt[CH_IMEM]     = 0;
      stall_tgt[CH_DMEM]     = 0;

      `uvm_info({get_type_name(), ".CFG"},
          $sformatf({"reactive memory agent: AGENT_IMEM_STALL=%0d ",
                     "AGENT_DMEM_STALL=%0d AGENT_DMEM_ERROR_ADDR=%s ",
                     "AGENT_IMEM_ERROR_ADDR=%s"},
              stall_n[CH_IMEM], stall_n[CH_DMEM],
              err_en ? $sformatf("0x%08h", err_addr) : "<off>",
              imem_err_en ? $sformatf("0x%08h", imem_err_addr) : "<off>"),
          UVM_LOW)
      `uvm_info({get_type_name(), ".CFG_RANDOM"},
          $sformatf({"random wait states: AGENT_RANDOM_STALL=%0d ",
                     "AGENT_STALL_SEED=%0d channels=%s (prng=xorshift32)"},
              rand_max, rand_seed,
              (use_random[CH_IMEM] && use_random[CH_DMEM]) ? "both" :
              (use_random[CH_IMEM] ? "imem" :
              (use_random[CH_DMEM] ? "dmem" : "none"))),
          UVM_LOW)

      model = g_mem_model;
      if (model == null) begin
        `uvm_fatal({get_type_name(), ".NOMODEL"},
            "scr1_tb_pkg::g_mem_model is null (agent build_phase order?)")
      end

      // Two independent processes: (a) the reactive per-clock bus FSM (never
      // blocked); (b) the sequencer side-channel updating the injection maps
      // / window queue. With no sequence, (b) parks on get_next_item and the
      // FSM is bit-identical to the reactive-only agent.
      fork
        forever begin
          @(vif.drv_cb);
          step();
        end
        forever begin
          seq_item_port.get_next_item(req);
          apply_injection(req);
          seq_item_port.item_done();
        end
      join
    endtask : run_phase

    virtual function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      // delay statistics (silent unless a window was armed - parity logs intact)
      if ((delay_draws > 0) || (delay_wins.size() > 0)) begin
        `uvm_info({get_type_name(), ".DELAY_SUMMARY"},
            $sformatf({"seq delay modulation: %0d transfer(s) modulated, ",
                       "%0d window(s) still armed at run end"},
                delay_draws, delay_wins.size()),
            UVM_LOW)
      end
    endfunction : report_phase

    // side-channel: one item -> injection maps or delay-window queue; runs
    // OFF the bus FSM critical path (separate process), never stalls a cycle
    protected function void apply_injection(scr1_mem_txn item);
      ahb_addr_t wkey;
      if (item == null) return;
      if (item.delay_mod) begin
        apply_delay_window(item);
        return;
      end
      if (item.err_count == 0) begin
        `uvm_warning({get_type_name(), ".INJ_NOOP"},
            "injection item with err_count=0 ignored (nothing armed)")
        return;
      end
      wkey = item.addr & AHB_WORD_MASK;
      if (item.is_imem) begin
        if (inj_err_imem.exists(wkey)) inj_err_imem[wkey] += item.err_count;
        else                           inj_err_imem[wkey]  = item.err_count;
      end else begin
        if (inj_err_dmem.exists(wkey)) inj_err_dmem[wkey] += item.err_count;
        else                           inj_err_dmem[wkey]  = item.err_count;
      end
      `uvm_info({get_type_name(), ".INJ_ARM"},
          $sformatf("sequence armed %s ERROR x%0d on word addr 0x%08h",
                    item.is_imem ? "IMEM" : "DMEM", item.err_count, wkey),
          UVM_LOW)
    endfunction : apply_injection

    // non-blocking consume of one armed ERROR; 1 = hit (count decremented)
    protected function bit take_injection(int ch, ahb_addr_t ha);
      ahb_addr_t wkey;
      wkey = ha & AHB_WORD_MASK;
      if (ch == CH_IMEM) begin
        if (inj_err_imem.exists(wkey) && (inj_err_imem[wkey] > 0)) begin
          inj_err_imem[wkey] = inj_err_imem[wkey] - 1;
          return 1'b1;
        end
      end else begin
        if (inj_err_dmem.exists(wkey) && (inj_err_dmem[wkey] > 0)) begin
          inj_err_dmem[wkey] = inj_err_dmem[wkey] - 1;
          return 1'b1;
        end
      end
      return 1'b0;
    endfunction : take_injection

    // side-channel: append one delay window to the FSM queue; queue order =
    // priority (first match wins); min/max normalized (swapped range still
    // arms a valid window)
    protected function void apply_delay_window(scr1_mem_txn item);
      delay_win_s w;
      w.lo      = item.addr;
      w.hi      = item.addr_hi;
      w.ch_imem = (item.delay_ch == DELAY_CH_IMEM) ||
                  (item.delay_ch == DELAY_CH_BOTH);
      w.ch_dmem = (item.delay_ch == DELAY_CH_DMEM) ||
                  (item.delay_ch == DELAY_CH_BOTH);
      if (item.rdelay_max < item.rdelay) begin
        `uvm_warning({get_type_name(), ".DELAY_SWAP"},
            $sformatf({"delay window rdelay_max=%0d < rdelay=%0d - ",
                       "the range is swapped"},
                item.rdelay_max, item.rdelay))
        w.dmin = item.rdelay_max;
        w.dmax = item.rdelay;
      end else begin
        w.dmin    = item.rdelay;
        w.dmax    = item.rdelay_max;
      end
      w.remain  = item.delay_count;
      if (w.hi < w.lo) begin
        `uvm_warning({get_type_name(), ".DELAY_EMPTY"},
            $sformatf({"delay window range 0x%08h..0x%08h is empty ",
                       "(hi < lo) - armed anyway, it can never match"},
                w.lo, w.hi))
      end
      delay_wins.push_back(w);
      `uvm_info({get_type_name(), ".DELAY_ARM"},
          $sformatf({"sequence armed delay window: ch=%s range ",
                     "0x%08h..0x%08h delay %0d..%0d count=%s"},
               w.ch_imem ? (w.ch_dmem ? "both" : "imem") : "dmem",
               w.lo, w.hi, w.dmin, w.dmax,
               (w.remain == 0) ? "unlimited" : $sformatf("%0d", w.remain)),
          UVM_LOW)
    endfunction : apply_delay_window

    // dedicated xorshift32 stream for window draws (NOT the AGENT_RANDOM_STALL
    // prng_state - enabling windows never changes the random-knob stream)
    protected function int unsigned delay_xorshift32();
      int unsigned x;
      x = delay_prng_state;
      x ^= (x << 13);
      x ^= (x >> 17);
      x ^= (x << 5);
      delay_prng_state = x;
      return x;
    endfunction : delay_xorshift32

    // non-blocking window lookup at the stall-target pick: first armed window
    // covering (channel, address) wins; remain decremented (0 = unlimited);
    // delay drawn in [dmin,dmax] (dmin==dmax: fixed value, no PRNG advance).
    // 1 = window matched, 0 = knobs stay in charge
    protected function bit win_delay(int ch, ahb_addr_t ha,
                                     output int unsigned tgt);
      for (int i = 0; i < delay_wins.size(); i++) begin
        if (((ch == CH_IMEM) ? delay_wins[i].ch_imem : delay_wins[i].ch_dmem) &&
            (ha >= delay_wins[i].lo) && (ha <= delay_wins[i].hi)) begin
          if (delay_wins[i].dmax > delay_wins[i].dmin) begin
            tgt = delay_wins[i].dmin +
                  (delay_xorshift32() %
                   (delay_wins[i].dmax - delay_wins[i].dmin + 1));
          end else begin
            tgt = delay_wins[i].dmin;
          end
          if (delay_wins[i].remain > 0) begin
            delay_wins[i].remain = delay_wins[i].remain - 1;
            if (delay_wins[i].remain == 0) delay_wins.delete(i);
          end
          delay_draws++;
          return 1'b1;
        end
      end
      return 1'b0;
    endfunction : win_delay

    // any delay window armed on the channel? While armed the channel leaves
    // the parity fast path: idle cycles hold hready=0 (ack gating - hready of
    // cycle X must be driven before the master's address of X is known), so
    // EVERY idle-started transfer costs one extra cycle even when the draw
    // is 0. Pipelined accepts are never modulated
    protected function bit win_armed(int ch);
      foreach (delay_wins[i]) begin
        if ((ch == CH_IMEM) ? delay_wins[i].ch_imem : delay_wins[i].ch_dmem)
          return 1'b1;
      end
      return 1'b0;
    endfunction : win_armed

    // stall machinery active: knob wait state OR armed window; with neither
    // the FSM is bit-identical to the reactive-only parity agent
    protected function bit stall_gate(int ch);
      return (eff_max[ch] != 0) || win_armed(ch);
    endfunction : stall_gate

    // deterministic xorshift32 PRNG (reproducible per AGENT_STALL_SEED; NOT
    // $urandom - run length must be bit-reproducible). Advanced ONLY when the
    // random knob is active, so AGENT_RANDOM_STALL=0 leaves timing untouched
    protected function int unsigned xorshift32();
      int unsigned x;
      x = prng_state;
      x ^= (x << 13);
      x ^= (x >> 17);
      x ^= (x << 5);
      prng_state = x;
      return x;
    endfunction : xorshift32

    // per-transfer address-phase wait-state target. PRIORITY: armed delay
    // window > random 1..rand_max (1..max, not 0..max: an enabled channel
    // always inserts >= 1 wait state, mirrors the knob stalling EVERY
    // transfer) > fixed stall_n. A window draw may be 0 (sequence-controlled)
    protected function int unsigned pick_stall(int ch, ahb_addr_t ha);
      int unsigned wtgt;
      if (win_delay(ch, ha, wtgt)) begin
        return wtgt;
      end
      if (use_random[ch]) begin
        return 1 + (xorshift32() % rand_max);
      end
      return eff_max[ch];
    endfunction : pick_stall

    // one reactive-FSM clock: drv_cb inputs are the bus values of the ended
    // cycle, driven outputs are visible during the starting cycle
    // (registered-output semantics, like the legacy always_ff+always_comb)
    protected task step();
      if (vif.drv_cb.rst_n !== 1'b1) begin
        // reset: idle FSMs, cleared devices, legacy idle levels
        model.reset_devices();
        for (int ch = 0; ch < AHB_CH_NUM; ch++) begin
          in_data[ch]   = 1'b0;
          wcnt[ch]      = 0;
          stall_tgt[ch] = 0;
          wr_l[ch]      = 1'b0;
          err_l[ch]     = 1'b0;
          rdata_l[ch]   = '0;
          hrdy_prev[ch] = !stall_gate(ch);
        end
        vif.drv_cb.imem_hready <= !stall_gate(CH_IMEM);
        vif.drv_cb.imem_hresp  <= HRESP_OKAY;
        vif.drv_cb.imem_hrdata <= '0;
        vif.drv_cb.dmem_hready <= !stall_gate(CH_DMEM);
        vif.drv_cb.dmem_hresp  <= HRESP_ERROR;
        vif.drv_cb.dmem_hrdata <= '0;
        vif.drv_cb.irq_lines   <= '0;
        vif.drv_cb.soft_irq    <= 1'b0;
        return;
      end

      // DMEM first: its write commit must land in the model before this
      // clock's IMEM/DMEM read latches (legacy w_hazard store->fetch fwd)
      step_dmem();
      // device lines follow the committed register values (program-driven;
      // async TB stimulus is owned by the IRQ agent - scr1_irq_if OR-merge)
      vif.drv_cb.irq_lines <= model.irq_lines;
      vif.drv_cb.soft_irq  <= model.soft_irq;
      step_imem();
    endtask : step

    // DMEM channel
    protected task step_dmem();
      ahb_htrans_t ht;
      ahb_addr_t   ha;
      logic        hw;
      ahb_hsize_t  hs;
      ahb_data_t   hd;
      logic        nready;
      logic        nresp;
      ahb_data_t   nrdata;

      ht = vif.drv_cb.dmem_htrans;
      ha = vif.drv_cb.dmem_haddr;
      hw = vif.drv_cb.dmem_hwrite;
      hs = vif.drv_cb.dmem_hsize;
      hd = vif.drv_cb.dmem_hwdata;
      // legacy idle defaults: hresp ERROR, no read data
      nresp  = HRESP_ERROR;
      nrdata = '0;

      if (in_data[CH_DMEM]) begin
        // sampled cycle = data-phase completion: commit a write at its edge
        if (wr_l[CH_DMEM] && !err_l[CH_DMEM]) begin
          commit_write(addr_l[CH_DMEM], be_l[CH_DMEM], hd);
        end
        if ((ht == HTRANS_NONSEQ) && hrdy_prev[CH_DMEM]) begin
          // pipelined accept in the completing data cycle (legacy DATA->DATA)
          accept_dmem(ha, hw, hs);
          nready = 1'b1;
          nresp  = err_l[CH_DMEM] ? HRESP_ERROR : HRESP_OKAY;
          nrdata = rdata_l[CH_DMEM];
        end else begin
          // bus idle (or core waits): back to the address state
          in_data[CH_DMEM] = 1'b0;
          wcnt[CH_DMEM]    = 0;
          nready           = !stall_gate(CH_DMEM);
        end
      end else begin
        if ((ht == HTRANS_NONSEQ) && hrdy_prev[CH_DMEM]) begin
          // the accept window closed: address phase completed
          accept_dmem(ha, hw, hs);
          in_data[CH_DMEM] = 1'b1;
          wcnt[CH_DMEM]    = 0;
          nready           = 1'b1;
          nresp            = err_l[CH_DMEM] ? HRESP_ERROR : HRESP_OKAY;
          nrdata           = rdata_l[CH_DMEM];
        end else begin
          // idle / address-phase wait states
          in_data[CH_DMEM] = 1'b0;
          if (!stall_gate(CH_DMEM)) begin
            nready = 1'b1;  // parity mode: always accepting
          end else if (ht == HTRANS_NONSEQ) begin
            // new transfer: latch wait-state target (window overrides knob)
            if (wcnt[CH_DMEM] == 0) stall_tgt[CH_DMEM] = pick_stall(CH_DMEM, ha);
            if (wcnt[CH_DMEM] >= stall_tgt[CH_DMEM]) begin
              nready = 1'b1;  // stalled enough: open the accept window
            end else begin
              nready = 1'b0;
              wcnt[CH_DMEM]++;
            end
          end else begin
            nready        = 1'b0;
            wcnt[CH_DMEM] = 0;
          end
        end
      end

      hrdy_prev[CH_DMEM]   = nready;
      vif.drv_cb.dmem_hready <= nready;
      vif.drv_cb.dmem_hresp  <= nresp;
      vif.drv_cb.dmem_hrdata <= nrdata;
    endtask : step_dmem

    // IMEM channel (reads only; hresp OKAY by default, ERROR only
    // via injection - instruction access fault, mcause=1 / EC1)
    protected task step_imem();
      ahb_htrans_t ht;
      ahb_addr_t   ha;
      ahb_hsize_t  hs;
      logic        nready;
      ahb_data_t   nrdata;
      logic        nresp;

      ht = vif.drv_cb.imem_htrans;
      ha = vif.drv_cb.imem_haddr;
      hs = vif.drv_cb.imem_hsize;
      nrdata = '0;
      nresp  = HRESP_OKAY;

      if (in_data[CH_IMEM]) begin
        if ((ht == HTRANS_NONSEQ) && hrdy_prev[CH_IMEM]) begin
          // pipelined fetch accept
          accept_imem(ha, hs);
          nready           = 1'b1;
          nresp            = err_l[CH_IMEM] ? HRESP_ERROR : HRESP_OKAY;
          nrdata           = rdata_l[CH_IMEM];
        end else begin
          in_data[CH_IMEM] = 1'b0;
          wcnt[CH_IMEM]    = 0;
          nready           = !stall_gate(CH_IMEM);
        end
      end else begin
        if ((ht == HTRANS_NONSEQ) && hrdy_prev[CH_IMEM]) begin
          accept_imem(ha, hs);
          in_data[CH_IMEM] = 1'b1;
          wcnt[CH_IMEM]    = 0;
          nready           = 1'b1;
          nresp            = err_l[CH_IMEM] ? HRESP_ERROR : HRESP_OKAY;
          nrdata           = rdata_l[CH_IMEM];
        end else begin
          in_data[CH_IMEM] = 1'b0;
          if (!stall_gate(CH_IMEM)) begin
            nready = 1'b1;
          end else if (ht == HTRANS_NONSEQ) begin
            // new transfer: latch wait-state target (window overrides knob)
            if (wcnt[CH_IMEM] == 0) stall_tgt[CH_IMEM] = pick_stall(CH_IMEM, ha);
            if (wcnt[CH_IMEM] >= stall_tgt[CH_IMEM]) begin
              nready = 1'b1;
            end else begin
              nready = 1'b0;
              wcnt[CH_IMEM]++;
            end
          end else begin
            nready        = 1'b0;
            wcnt[CH_IMEM] = 0;
          end
        end
      end

      hrdy_prev[CH_IMEM]   = nready;
      vif.drv_cb.imem_hready <= nready;
      vif.drv_cb.imem_hresp  <= nresp;  // OKAY unless the injected ERROR
      vif.drv_cb.imem_hrdata <= nrdata;
    endtask : step_imem

    // Address-phase accept (dmem): latch + response compute. Runs
    // AFTER the pending write commit, so a back-to-back store->load
    // of the same word reads the new data (w_hazard fwd parity).
    protected function void accept_dmem(ahb_addr_t ha, logic hw,
                                        ahb_hsize_t hs);
      scr1_mem_model::scr1_mem_win_e win;
      addr_l[CH_DMEM] = ha;
      wr_l[CH_DMEM]   = hw;
      be_l[CH_DMEM]   = model.be_form(ahb_byte_offs_t'(ha), hs);
      win             = model.decode(ha);
      err_l[CH_DMEM]  = (win == scr1_mem_model::WIN_UNMAPPED) ||
                        (err_en &&
                         ((ha & AHB_WORD_MASK) == (err_addr & AHB_WORD_MASK)));
      // sequence-armed ERROR injection (non-blocking consume, one per transfer)
      if (take_injection(CH_DMEM, ha)) err_l[CH_DMEM] = 1'b1;
      // record injected ERRORs only (not the unmapped deviation) so the mem
      // scoreboard can tell a legitimate ERROR from a spurious one
      if (err_l[CH_DMEM] && (win != scr1_mem_model::WIN_UNMAPPED)) begin
        model.note_err_injection(ha & AHB_WORD_MASK);
      end
      rdata_l[CH_DMEM] = '0;
      if (!hw && !err_l[CH_DMEM]) begin
        case (win)
          scr1_mem_model::WIN_RAM : begin
            rdata_l[CH_DMEM] = model.read_word(ha, be_l[CH_DMEM]);
          end
          scr1_mem_model::WIN_CONSOLE,
          scr1_mem_model::WIN_EXT_IRQ,
          scr1_mem_model::WIN_SOFT_IRQ : begin
            rdata_l[CH_DMEM] = model.device_read(ha);
          end
          default : ;
        endcase
      end
    endfunction : accept_dmem

    // Address-phase accept (imem): latch + response compute. hresp
    // OKAY by design; ERROR only from +AGENT_IMEM_ERROR_ADDR or a
    // sequence injection (instruction access fault, mcause=1/EC1).
    protected function void accept_imem(ahb_addr_t ha, ahb_hsize_t hs);
      addr_l[CH_IMEM]  = ha;
      err_l[CH_IMEM]   = imem_err_en &&
                         ((ha & AHB_WORD_MASK) == (imem_err_addr & AHB_WORD_MASK));
      if (take_injection(CH_IMEM, ha)) err_l[CH_IMEM] = 1'b1;
      // imem hresp is OKAY by design - any ERROR here is an injection
      if (err_l[CH_IMEM]) model.note_err_injection(ha & AHB_WORD_MASK);
      rdata_l[CH_IMEM] = err_l[CH_IMEM] ? '0
                         : model.read_word(ha, model.be_form('0, hs));
    endfunction : accept_imem

    // data-phase write commit (dmem): devices take hwdata as-is (byte enables
    // ignored, legacy semantics); RAM written through the latched enables
    protected function void commit_write(ahb_addr_t addr, ahb_be_t be,
                                         ahb_data_t hwdata);
      case (model.decode(addr))
        scr1_mem_model::WIN_RAM : begin
          model.write_word(addr, be, hwdata);
        end
        scr1_mem_model::WIN_CONSOLE,
        scr1_mem_model::WIN_EXT_IRQ,
        scr1_mem_model::WIN_SOFT_IRQ : begin
          model.device_write(addr, hwdata);
        end
        default : ;  // unmapped: excluded by err_l (no commit on ERROR)
      endcase
    endfunction : commit_write

  endclass : scr1_mem_driver
