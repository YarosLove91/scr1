// ============================================================
// File    : scr1_irq_single_seq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Single-pulse IRQ scenario (pair vector sim/tests/irq_ext):
// after the vseq alignment the program gets ext_delay cycles to
// install its handler and enable MEIE+MIE, the ext mask is
// asserted for ext_width, then after soft_delay the soft line is
// asserted for soft_width. Timing defaults: scr1_irq_cfg_pkg,
// overridden by the +IRQ_* plusargs. README.md (milestone 6).
// ============================================================
  class scr1_irq_single_seq extends scr1_irq_base_seq;
    `uvm_object_utils(scr1_irq_single_seq)

    // stimulus timing (cycles)
    int unsigned ext_delay;
    int unsigned ext_width;
    int unsigned soft_delay;
    int unsigned soft_width;

    // external IRQ line mask (EXT_IRQ_LINE: IPIC line 9 / common line 0)
    irq_lines_t ext_mask;

    function new(string name = "scr1_irq_single_seq");
      super.new(name);
      ext_delay  = IRQ_EXT_DELAY_DFLT;
      ext_width  = IRQ_EXT_WIDTH_DFLT;
      soft_delay = IRQ_SOFT_DELAY_DFLT;
      soft_width = IRQ_SOFT_WIDTH_DFLT;
      ext_mask   = '0;
      ext_mask[EXT_IRQ_LINE] = 1'b1;
    endfunction : new

    virtual task body();
      string smsg;
      smsg = $sformatf(
          {"single-pulse stimulus: ext_mask=0x%04h ext_delay=%0d ",
           "ext_width=%0d soft_delay=%0d soft_width=%0d"},
          ext_mask, ext_delay, ext_width, soft_delay, soft_width);
      `uvm_info({get_type_name(), ".CFG"}, smsg, UVM_LOW)

      // let the program install its handler and enable ext + MIE
      vif.wait_clks(ext_delay);
      smsg = $sformatf("assert external IRQ lines=0x%04h for %0d cycles",
                       ext_mask, ext_width);
      `uvm_info({get_type_name(), ".IRQ_EXT"}, smsg, UVM_LOW)
      raise_ext(ext_mask);
      vif.wait_clks(ext_width);
      clear_ext();

      // gap (the program disables ext, enables soft), then soft IRQ
      vif.wait_clks(soft_delay);
      smsg = $sformatf("assert software IRQ for %0d cycles", soft_width);
      `uvm_info({get_type_name(), ".IRQ_SOFT"}, smsg, UVM_LOW)
      raise_soft();
      vif.wait_clks(soft_width);
      clear_soft();
    endtask : body

  endclass : scr1_irq_single_seq
