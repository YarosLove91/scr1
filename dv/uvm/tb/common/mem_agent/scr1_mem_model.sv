// ============================================================
// File    : scr1_mem_model.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Memory + simulation-device model of the reactive AHB memory
// agent (stage B, MEM_AGENT=1). Compiled into its own
// scr1_mem_model_pkg BEFORE the RTL; the harness consumes the
// singleton global scr1_tb_pkg::g_mem_model (a class handle
// crosses the module boundary through a package global - the
// g_load_path transport pattern, DESIGN_VS_IBEX.md §7).
// Contents (device semantics mirror src/tb/scr1_memory_tb_ahb.sv):
// 1 MB byte array wrapping at 1 MB, $readmemh-equivalent
// verilog-hex parser (@addr = BYTE addresses), peek32/poke32
// backdoor, console/EXT_IRQ/SOFT_IRQ device registers (stores
// IGNORE byte enables), RAM helpers with byte enables.
// Intentional stage-B deviation: dmem outside the known windows
// is UNMAPPED -> hresp ERROR (closes the EC5/EC7 bins); the
// legacy tb wrapped into the array and answered OKAY (BUG-003).
// ============================================================
  class scr1_mem_model extends uvm_object;
    `uvm_object_utils(scr1_mem_model)

    // address windows of the dmem decode
    typedef enum int {
      WIN_RAM,
      WIN_CONSOLE,
      WIN_EXT_IRQ,
      WIN_SOFT_IRQ,
      WIN_UNMAPPED
    } scr1_mem_win_e;

    // storage / device state
    protected mem_byte_t mem [MEM_BYTES];
    ahb_data_t            irq_lines;    // SCR1_SIM_EXT_IRQ_ADDR register
    bit                   soft_irq;     // SCR1_SIM_SOFT_IRQ_ADDR bit0
    int unsigned          console_chars;// stores to SCR1_SIM_PRINT_ADDR

    // the IRQ device registers are the PROGRAM-driven pin source (isr_sample
    // self-trigger, handler clears); the driver mirrors them to mem_vif and
    // scr1_irq_if ORs them with the IRQ agent's TB stimulus lines

    // ---- ERROR-injection registry (mem scoreboard legitimacy cross-check) ----
    // Word addresses the driver answered ERROR on due to an INJECTION
    // (+AGENT_*_ERROR_ADDR or scr1_mem_err_seq). The scoreboard treats an
    // ERROR as legitimate iff WIN_UNMAPPED or registered here; cleared on
    // reset (per-run whitelist, populated by the driver).
    int unsigned        err_injected [ahb_addr_t];

    // load_verilog_hex parser state (class fields: no ref args)
    protected int unsigned load_addr;
    protected int unsigned load_bytes;
    protected bit          in_block_comment;

    function new(string name = "scr1_mem_model");
      super.new(name);
      clear();
      reset_devices();
    endfunction : new

    // Image management
    function void clear();
      foreach (mem[i]) mem[i] = '0;
      load_addr  = 0;
      load_bytes = 0;
    endfunction : clear

    function void reset_devices();
      irq_lines = '0;
      soft_irq  = 1'b0;
      err_injected.delete();
    endfunction : reset_devices

    // ---- ERROR-injection registry API (called by the mem driver) ----
    // record an injected ERROR so the scoreboard can filter spurious ones
    function void note_err_injection(ahb_addr_t word_addr);
      err_injected[word_addr] = 1;
    endfunction : note_err_injection

    function bit err_was_injected(ahb_addr_t word_addr);
      return err_injected.exists(word_addr);
    endfunction : err_was_injected

    // $readmemh-equivalent load; clears the image first (a stale vector must
    // not survive a reload, NUM_RUNS > 1)
    function void load_verilog_hex(string path);
      int    fd;
      string line;
      int    got;
      clear();
      in_block_comment = 1'b0;
      fd = $fopen(path, "r");
      if (fd == 0) begin
        `uvm_fatal("MEM_MODEL.VECOPEN",
            $sformatf("cannot open vector file '%s'", path))
      end
      got = $fgets(line, fd);
      while (got != 0) begin
        parse_line(line);
        got = $fgets(line, fd);
      end
      $fclose(fd);
      `uvm_info("MEM_MODEL.LOAD",
          $sformatf("loaded '%s': %0d bytes, next addr 0x%08h",
                    path, load_bytes, load_addr),
          UVM_MEDIUM)
    endfunction : load_verilog_hex

    protected function void parse_line(string line);
      int i;
      int len;
      int unsigned tok;
      int c;
      i   = 0;
      len = line.len();
      while (i < len) begin
        c = line[i];
        if (in_block_comment) begin
          // swallow everything up to "*/"
          if ((c == "*") && (i + 1 < len) && (line[i+1] == "/")) begin
            in_block_comment = 1'b0;
            i += 2;
          end else begin
            i++;
          end
          continue;
        end
        if ((c == " ") || (c == "\t") || (c == "\r") || (c == "\n") ||
            (c == "\f") || (c == "\v")) begin
          i++;
          continue;
        end
        if (c == "/") begin
          if ((i + 1 < len) && (line[i+1] == "/")) begin
            i = len;  // line comment: rest of the line
          end else if ((i + 1 < len) && (line[i+1] == "*")) begin
            in_block_comment = 1'b1;
            i += 2;
          end else begin
            i++;
          end
          continue;
        end
        if (c == "@") begin
          // byte-address marker
          i++;
          tok = 0;
          while ((i < len) && is_hex_digit(line[i])) begin
            tok = (tok << 4) | hex_val(line[i]);
            i++;
          end
          load_addr = tok;
          continue;
        end
        if (is_hex_digit(c) || (c == "x") || (c == "X") ||
            (c == "z") || (c == "Z") || (c == "?") || (c == "_")) begin
          // byte token; x/z/? contribute 0 like a 2-state $readmemh target
          tok = 0;
          while ((i < len) && (is_hex_digit(line[i]) || (line[i] == "x") ||
                 (line[i] == "X") || (line[i] == "z") || (line[i] == "Z") ||
                 (line[i] == "?") || (line[i] == "_"))) begin
            if (is_hex_digit(line[i])) begin
              tok = (tok << 4) | hex_val(line[i]);
            end
            i++;
          end
          mem[load_addr & MEM_ADDR_MASK] = mem_byte_t'(tok);
          load_addr++;
          load_bytes++;
          continue;
        end
        i++;  // stray character: ignore
      end
    endfunction : parse_line

    protected function bit is_hex_digit(int c);
      return ((c >= "0") && (c <= "9")) ||
             ((c >= "a") && (c <= "f")) ||
             ((c >= "A") && (c <= "F"));
    endfunction : is_hex_digit

    protected function int unsigned hex_val(int c);
      if ((c >= "0") && (c <= "9")) return c - "0";
      if ((c >= "a") && (c <= "f")) return (c - "a") + 10;
      if ((c >= "A") && (c <= "F")) return (c - "A") + 10;
      return 0;
    endfunction : hex_val

    // Backdoor (stage A driver protocol: 32-bit LE words)
    function xlen_word_t peek32(xlen_word_t addr);
      xlen_word_t w;
      w = '0;
      for (int i = 0; i < $bits(xlen_word_t)/MEM_BYTE_BITS; i++) begin
        w[(i*MEM_BYTE_BITS) +: MEM_BYTE_BITS] =
            mem[(addr + i) & MEM_ADDR_MASK];
      end
      return w;
    endfunction : peek32

    function void poke32(xlen_word_t addr, xlen_word_t data);
      for (int i = 0; i < $bits(xlen_word_t)/MEM_BYTE_BITS; i++) begin
        mem[(addr + i) & MEM_ADDR_MASK] =
            data[(i*MEM_BYTE_BITS) +: MEM_BYTE_BITS];
      end
    endfunction : poke32

    // Address decode / RAM access (legacy function mirrors)
    function scr1_mem_win_e decode(ahb_addr_t addr);
      if (addr < ahb_addr_t'(MEM_BYTES)) return WIN_RAM;
      case (addr)
        PRINT_ADDR    : return WIN_CONSOLE;
        EXT_IRQ_ADDR  : return WIN_EXT_IRQ;
        SOFT_IRQ_ADDR : return WIN_SOFT_IRQ;
        default       : return WIN_UNMAPPED;
      endcase
    endfunction : decode

    // byte-enable form (lane patterns from the cfg_pkg AHB_BE_* constants)
    function ahb_be_t be_form(ahb_byte_offs_t offset, ahb_hsize_t hsize);
      case (hsize)
        HSIZE_8B  : return AHB_BE_BYTE << offset;
        HSIZE_16B : return AHB_BE_HALF << offset;
        HSIZE_32B : return AHB_BE_WORD;
        default   : return AHB_BE_NONE;
      endcase
    endfunction : be_form

    // masked-lane word read (legacy 'x of unselected lanes collapsed to 0;
    // indexes wrap at 1 MB like the legacy 2-state array indexing)
    function ahb_data_t read_word(ahb_addr_t addr, ahb_be_t be);
      ahb_data_t tmp;
      ahb_addr_t al;
      al  = addr & AHB_WORD_MASK;
      tmp = '0;
      for (int i = 0; i < AHB_BYTES; i++) begin
        if (be[i]) tmp[(i*MEM_BYTE_BITS) +: MEM_BYTE_BITS] =
            mem[(al + i) & MEM_ADDR_MASK];
      end
      return tmp;
    endfunction : read_word

    function void write_word(ahb_addr_t addr, ahb_be_t be,
                             ahb_data_t data);
      ahb_addr_t al;
      al = addr & AHB_WORD_MASK;
      for (int i = 0; i < AHB_BYTES; i++) begin
        if (be[i]) mem[(al + i) & MEM_ADDR_MASK] =
            data[(i*MEM_BYTE_BITS) +: MEM_BYTE_BITS];
      end
    endfunction : write_word

    // Devices (legacy scr1_memory_tb_ahb semantics)
    function ahb_data_t device_read(ahb_addr_t addr);
      case (addr)
        // console is write-only; agent returns a clean 0 (legacy aliased it
        // into the wrapped RAM array)
        PRINT_ADDR    : return '0;
        // typed narrowing to the line vector, zero-extended to the bus word
        EXT_IRQ_ADDR  : return ahb_data_t'(irq_lines_t'(irq_lines));
        SOFT_IRQ_ADDR : return ahb_data_t'(soft_irq);
        default       : return '0;
      endcase
    endfunction : device_read

    // device store: byte enables IGNORED (legacy semantics, hwdata as-is)
    function void device_write(ahb_addr_t addr, ahb_data_t hwdata);
      case (addr)
        PRINT_ADDR : begin
          console_chars++;
          $write("%c", mem_byte_t'(hwdata));
        end
        EXT_IRQ_ADDR : begin
          irq_lines = ahb_data_t'(irq_lines_t'(hwdata));
        end
        SOFT_IRQ_ADDR : begin
          soft_irq = hwdata[0];
        end
        default : ;
      endcase
    endfunction : device_write

    function int unsigned get_console_chars();
      return console_chars;
    endfunction : get_console_chars

  endclass : scr1_mem_model
