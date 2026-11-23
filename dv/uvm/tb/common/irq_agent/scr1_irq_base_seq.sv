// ============================================================
// File    : scr1_irq_base_seq.sv
// Author  : M.Yaroslove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// IRQ agent base sequence: owns the interrupt-pin clock grid
// (wait_clks on the core clk) and the joint stimulus state. One
// item carries the FULL joint state (ext mask + soft level) and a
// body is a SINGLE replay thread - the channels can never clobber
// each other. Timing contract: every raise/clear is sent right
// after a core-clk posedge; the driver applies items with zero
// sim time, pins are driven on the clocking edge.
// ============================================================
  class scr1_irq_base_seq extends uvm_sequence #(scr1_irq_seq_item);
    `uvm_object_utils(scr1_irq_base_seq)

    // IRQ interface (the clock grid + the lines the agent owns)
    scr1_irq_vif vif;

    // joint stimulus state as last published to the driver
    protected irq_lines_t cur_ext;
    protected bit                     cur_soft;

    function new(string name = "scr1_irq_base_seq");
      super.new(name);
      cur_ext  = '0;
      cur_soft = 1'b0;
    endfunction : new

    virtual task pre_body();
      if (!uvm_config_db#(scr1_irq_vif)::get(null, "*", "irq_vif", vif)) begin
        `uvm_fatal({get_type_name(), ".NOVIF"},
            "irq_vif not found in uvm_config_db (IRQ sequence timing)")
      end
    endtask : pre_body

    // publish a new joint line state (one item per change); the driver
    // holds it until the next item (level semantics), delay/width stay 0
    virtual task send_state(irq_lines_t ext_mask,
                            bit soft_level);
      scr1_irq_seq_item item;
      cur_ext  = ext_mask;
      cur_soft = soft_level;
      item = scr1_irq_seq_item::type_id::create("irq_item");
      item.ext_mask         = ext_mask;
      item.soft_irq         = soft_level;
      item.delay            = 0;
      item.width            = 0;
      item.num_of_interrupt = $countones({ext_mask, soft_level});
      start_item(item);
      finish_item(item);
    endtask : send_state

    // per-channel conveniences (the other channel keeps its state)
    virtual task raise_ext(irq_lines_t mask);
      send_state(mask, cur_soft);
    endtask : raise_ext

    virtual task clear_ext();
      send_state('0, cur_soft);
    endtask : clear_ext

    virtual task raise_soft();
      send_state(cur_ext, 1'b1);
    endtask : raise_soft

    virtual task clear_soft();
      send_state(cur_ext, 1'b0);
    endtask : clear_soft

  endclass : scr1_irq_base_seq
