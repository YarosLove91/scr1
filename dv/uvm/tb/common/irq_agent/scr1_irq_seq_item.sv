// ============================================================
// File    : scr1_irq_seq_item.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ agent sequence item (donor: ibex irq_seq_item). One item
// carries the FULL joint stimulus state (ext IPIC mask + soft
// line); the driver applies it as the new line state and holds it
// (level semantics). delay/width are pulse-scenario metadata for
// logging/knobs - the driver is purely level-driven. Schedules
// are built deterministically (scr1_irq_cfg_pkg bounds + LCG),
// NOT by randomize(); the constraint declares the legal item
// space in ibex style. No rand string fields (known sim limit).
// ============================================================
  class scr1_irq_seq_item extends uvm_sequence_item;

    rand irq_lines_t ext_mask;  // external IPIC line mask
    rand bit                     soft_irq;      // software IRQ line
    rand int unsigned            delay;     // pulse scenario: cycles to assert
    rand int unsigned            width;     // pulse scenario: cycles asserted
    rand int unsigned            num_of_interrupt;  // asserted source count

    // ibex-style count constraint: the number of asserted sources
    constraint num_of_interrupt_c {
      num_of_interrupt == $countones({ext_mask, soft_irq});
      num_of_interrupt inside {[0:IRQ_LINES_NUM]};
    }

    `uvm_object_utils_begin(scr1_irq_seq_item)
      `uvm_field_int(ext_mask,         UVM_DEFAULT | UVM_HEX)
      `uvm_field_int(soft_irq,             UVM_DEFAULT)
      `uvm_field_int(delay,            UVM_DEFAULT | UVM_DEC)
      `uvm_field_int(width,            UVM_DEFAULT | UVM_DEC)
      `uvm_field_int(num_of_interrupt, UVM_DEFAULT | UVM_DEC)
    `uvm_object_utils_end

    function new(string name = "scr1_irq_seq_item");
      super.new(name);
    endfunction : new

    virtual function string convert2string();
      return $sformatf("ext=0x%04h soft=%0b delay=%0d width=%0d srcs=%0d",
                       ext_mask, soft_irq, delay, width, num_of_interrupt);
    endfunction : convert2string

  endclass : scr1_irq_seq_item
