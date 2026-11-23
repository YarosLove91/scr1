// ============================================================
// File    : scr1_irq_random_seq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Random multi-pulse IRQ scenario (opt-in +IRQ_RANDOM > 0, pair
// vector sim/tests/irq_stress). Fully deterministic plan: every
// value is drawn in ONE single-threaded pass after a single
// rng_seed(seed) -> same seed = same stimulus log. Ext pulses are
// non-overlapping; the first soft pulse is forced inside ext[0]'s
// window (guaranteed ext+soft overlap -> IPIC priority
// arbitration). With soft_guar the concurrent pulse spans the
// expected first ext-quiescent window (est_first_quiet(), pure
// arithmetic), so MSI is still pending when the ext queue drains:
// >= 1 soft trap guaranteed per run. Scenario bounds and the drain
// model constants live in scr1_irq_cfg_pkg. Details:
// dv/uvm/README.md (milestone 6, irq_stress).
// ============================================================
  class scr1_irq_random_seq extends scr1_irq_base_seq;
    `uvm_object_utils(scr1_irq_random_seq)

    // ---- pulse descriptors of the pre-computed schedule ----
    typedef struct {
      int unsigned start;                  // cycle offset from t0 (post setup)
      irq_lines_t  mask;                   // external IRQ line mask
      int unsigned width;                  // pulse width, cycles
    } irq_ext_pulse_s;
    typedef struct {
      int unsigned start;
      int unsigned width;
    } irq_soft_pulse_s;

    // ---- merged replay timeline: one joint-state event per cycle
    //      at which any channel changes ----
    typedef struct {
      int unsigned cycle;
      irq_lines_t ext;
      bit soft_level;
    } irq_event_s;

    // scenario controls (set by scr1_irq_run_vseq from the test)
    int unsigned random_count;    // number of ext pulses in the series
    int unsigned run_seed;        // seed of THIS run (vseq: seed+run_index)
    string       mask_mode;       // "fixed9" | "random16" | "all16"
    bit          soft_guar;       // guaranteed-service concurrent soft pulse

    // pre-computed pulse schedules
    irq_ext_pulse_s  ext_q[$];
    irq_soft_pulse_s soft_q[$];
    int unsigned     concurrent_start;  // cycle of the forced ext+soft overlap

    // merged event timeline (built from the schedules, consumed by replay)
    irq_event_s      events[$];

    // Self-contained LCG PRNG (Numerical Recipes constants, mod 2**32),
    // used instead of $urandom: the seeded $urandom of the host simulator
    // does NOT re-seed the subsequent $urandom_range stream (identical
    // schedules for different seeds). LCG = deterministic on every tool.
    int unsigned rng_state;

    function new(string name = "scr1_irq_random_seq");
      super.new(name);
      random_count     = IRQ_RANDOM_DFLT;
      run_seed         = IRQ_SEED_DFLT;
      mask_mode        = IRQ_MASK_MODE_DFLT;
      soft_guar        = IRQ_SOFT_GUAR_DFLT;
      concurrent_start = IRQ_CONCURRENT_START_DFLT;
    endfunction : new

    function void rng_seed(int unsigned s);
      rng_state = s;
    endfunction : rng_seed

    function int unsigned rng_next();
      rng_state = rng_state * 32'd1664525 + 32'd1013904223;
      return rng_state;
    endfunction : rng_next

    // inclusive range [lo, hi]
    function int unsigned rng_range(int unsigned lo, int unsigned hi);
      int unsigned span;
      span = hi - lo + 1;
      return lo + (rng_next() % span);
    endfunction : rng_range

    virtual task body();
      string smsg;
      build_random_schedule(run_seed);

      // let the program install its handler and enable ALL ext lines + soft
      vif.wait_clks(RAND_SETUP_DELAY);

      smsg = $sformatf(
          {"schedule (seed=%0d soft_guar=%0d): ext_pulses=%0d ",
           "soft_pulses=%0d (concurrent ext+soft at cycle %0d)"},
          run_seed, soft_guar, ext_q.size(), soft_q.size(), concurrent_start);
      `uvm_info({get_type_name(), ".IRQ_RAND"}, smsg, UVM_LOW)

      build_event_timeline();
      replay_events();

      // make sure nothing is left asserted after the series
      if ((cur_ext != '0) || (cur_soft != 1'b0)) begin
        send_state('0, 1'b0);
      end
    endtask : body

    // one ext-line mask per mask_mode; irq_stress enables every IPIC line,
    // so random16/all16 exercise multi-line arbitration (k bits -> k traps)
    protected function irq_lines_t gen_ext_mask(
        int unsigned full_mask);
      irq_lines_t fixed;
      case (mask_mode)
        "all16"   : return irq_lines_t'(full_mask);
        "random16": return rng_range(1, full_mask);  // non-zero subset
        default   : begin                            // fixed9 / fallback
          fixed = '0;
          fixed[EXT_IRQ_LINE] = 1'b1;
          return fixed;
        end
      endcase
    endfunction : gen_ext_mask

    // expected first ext-quiescent cycle (drain model): each mask line
    // costs ~SOFT_GUAR_PER_LINE cycles to drain (IPIC SOI/EOI + trap
    // overhead, ~15 measured), chained across pulses; pure arithmetic,
    // no RNG draws
    protected function int unsigned est_first_quiet();
      int unsigned busy_until;
      busy_until = 0;
      foreach (ext_q[i]) begin
        if ((i > 0) && (busy_until <= ext_q[i].start)) begin
          return busy_until;   // the drain caught up before pulse i
        end
        if (busy_until < ext_q[i].start) begin
          busy_until = ext_q[i].start;
        end
        busy_until += $countones(ext_q[i].mask) * SOFT_GUAR_PER_LINE;
      end
      return busy_until;       // quiet only after the whole series drains
    endfunction : est_first_quiet

    // build the whole schedule in ONE single-threaded pass; the draw order
    // is fixed: per ext pulse gap/width/mask, free-soft count, per soft
    // pulse gap/width
    protected function void build_random_schedule(int unsigned seed);
      int unsigned n;
      int unsigned m_free;
      int unsigned i;
      int unsigned cur_e;
      int unsigned cur_s;
      int unsigned gap;
      int unsigned w;
      int unsigned full_mask;
      irq_ext_pulse_s  ep;
      irq_soft_pulse_s sp;

      rng_seed(seed);                // single seed -> deterministic draw stream
      ext_q.delete();
      soft_q.delete();
      full_mask = (1 << IRQ_LINES_NUM) - 1;  // 0x0000FFFF for 16 lines

      // external pulse series
      n     = random_count;
      cur_e = 0;
      for (i = 0; i < n; i++) begin
        gap     = rng_range(EXT_GAP_MIN, EXT_GAP_MAX);
        w       = rng_range(EXT_W_MIN, EXT_W_MAX);
        cur_e  += gap;
        ep.start = cur_e;
        ep.width = w;
        ep.mask  = gen_ext_mask(full_mask);
        ext_q.push_back(ep);
        cur_e   += w;   // keep external pulses non-overlapping
      end

      // forced concurrent software pulse inside ext[0]'s window
      if (ext_q.size() > 0) begin
        sp.start = ext_q[0].start + 1;
        if (soft_guar) begin
          // guaranteed service: span the expected first ext-quiescent cycle
          // + margin (drain model) - MSI still pending when ext drains; the
          // pulse still STARTS inside ext[0]'s window (overlap preserved)
          sp.width = (est_first_quiet() + SOFT_GUAR_MARGIN) - sp.start;
        end else begin
          sp.width = ext_q[0].width;
          if (sp.width > SOFT_W_MAX) sp.width = SOFT_W_MAX;
          if (sp.width < SOFT_W_MIN) sp.width = SOFT_W_MIN;
        end
        soft_q.push_back(sp);
        concurrent_start = sp.start;
        // free software pulses start clear of the concurrent one
        if (soft_guar) begin
          cur_s = sp.start + sp.width + SOFT_GAP_MIN;
        end else begin
          cur_s = ext_q[0].start + ext_q[0].width + SOFT_GAP_MIN;
        end
      end else begin
        concurrent_start = 0;
        cur_s = 0;
      end

      // free (independent) software pulses: total soft >= SOFT_MIN_PULSES
      m_free = (SOFT_MIN_PULSES - 1) + rng_range(0, SOFT_EXTRA_MAX);
      for (i = 0; i < m_free; i++) begin
        gap     = rng_range(SOFT_GAP_MIN, SOFT_GAP_MAX);
        w       = rng_range(SOFT_W_MIN, SOFT_W_MAX);
        cur_s  += gap;
        sp.start = cur_s;
        sp.width = w;
        soft_q.push_back(sp);
        cur_s   += w;   // keep software pulses non-overlapping
      end
    endfunction : build_random_schedule

    // Merge both queues' pulse boundaries into ONE sorted, deduped
    // event timeline; each event carries the joint state from that
    // cycle on (a pulse covers [start, start+width)). Insertion sort
    // + linear dedup via the boundary_q class field (no ref args -
    // the known simulator limit); the timeline is tiny (~2 x pulses).
    protected int unsigned boundary_q[$];

    protected function void build_event_timeline();
      irq_event_s ev;
      int unsigned c;

      events.delete();
      boundary_q.delete();

      // collect every pulse boundary (ordered unique insert)
      foreach (ext_q[i]) begin
        push_cycle(ext_q[i].start);
        push_cycle(ext_q[i].start + ext_q[i].width);
      end
      foreach (soft_q[i]) begin
        push_cycle(soft_q[i].start);
        push_cycle(soft_q[i].start + soft_q[i].width);
      end

      // joint state at each boundary
      foreach (boundary_q[j]) begin
        c = boundary_q[j];
        ev.cycle      = c;
        ev.ext        = '0;
        ev.soft_level = 1'b0;
        foreach (ext_q[i]) begin
          if ((c >= ext_q[i].start) &&
              (c < ext_q[i].start + ext_q[i].width)) begin
            ev.ext |= ext_q[i].mask;
          end
        end
        foreach (soft_q[i]) begin
          if ((c >= soft_q[i].start) &&
              (c < soft_q[i].start + soft_q[i].width)) begin
            ev.soft_level = 1'b1;
          end
        end
        events.push_back(ev);
      end
    endfunction : build_event_timeline

    // ordered unique insert into the boundary list
    protected function void push_cycle(int unsigned c);
      foreach (boundary_q[i]) begin
        if (boundary_q[i] == c) return;              // duplicate boundary
        if (boundary_q[i] > c) begin
          boundary_q.insert(i, c);
          return;
        end
      end
      boundary_q.push_back(c);
    endfunction : push_cycle

    // Single-thread replay on the core clk grid (t0 = after
    // RAND_SETUP_DELAY): publish the joint state at each event
    // cycle, log the pulses starting there.
    protected task replay_events();
      int unsigned elapsed;
      string msg;
      elapsed = 0;
      foreach (events[i]) begin
        if (events[i].cycle > elapsed) begin
          vif.wait_clks(events[i].cycle - elapsed);
          elapsed = events[i].cycle;
        end
        foreach (ext_q[j]) begin
          if (ext_q[j].start == events[i].cycle) begin
            msg = $sformatf("ext pulse[%0d] mask=0x%04h start_cycle=%0d width=%0d",
                            j, ext_q[j].mask, ext_q[j].start, ext_q[j].width);
            `uvm_info({get_type_name(), ".IRQ_RAND_EXT"}, msg, UVM_LOW)
          end
        end
        foreach (soft_q[j]) begin
          if (soft_q[j].start == events[i].cycle) begin
            msg = $sformatf("soft pulse[%0d] start_cycle=%0d width=%0d",
                            j, soft_q[j].start, soft_q[j].width);
            `uvm_info({get_type_name(), ".IRQ_RAND_SOFT"}, msg, UVM_LOW)
          end
        end
        send_state(events[i].ext, events[i].soft_level);
      end
    endtask : replay_events

  endclass : scr1_irq_random_seq
