// ============================================================
// File    : scr1_report_server.sv
// Author  : M.YarosLove <yoruk91@gmail.com>
// Project : UVM verification environment for the SCR1 core (Verilator)
// ------------------------------------------------------------
// Custom UVM report server (SNUG 2013 Cookbook pattern,
// G. McGregor): extends uvm_default_report_server.
// process_report_message accounts ERROR/FATAL per message ID
// (first text/time/location kept for triage) and histograms all
// messages by verbosity; summarize appends an "SCR1 Report Server
// Summary" section: run info, scr1_cfg_pkg config, SCR1_RESULT
// verdict counters, verbosity histogram, error-by-ID table and
// the final verdict (PASS iff no UVM_ERROR/FATAL and no failed
// runs / diff / CSR mismatches). Installed by
// scr1_base_test::build_phase; plain text only (logs must stay
// greppable). The console SCR1_RESULT line belongs to
// scr1_base_test::final_phase and is NOT duplicated here (the
// Makefile grep contract stays single-sourced).
// Optional XML log (+SCR1_XML_LOG[=<path>], SNUG 2013 §5-6): every
// message becomes a <msg> element with full meta-data, summarize
// appends <summary>; consumed by tools/scr1_log_viewer.py.
// $fopen/$fdisplay serve the FILE log only - console reporting
// goes exclusively through the UVM macros.
// ============================================================

  class scr1_report_server extends uvm_default_report_server;

    // error triage tables (string keys iterate lexicographically ->
    // deterministic summary output)
    protected int    err_id_count[string];
    protected string err_id_first[string];
    protected string err_id_time[string];
    protected string err_id_loc[string];

    // message histogram by verbosity (all severities)
    protected int    verb_count[int];

    // optional structured XML log (SNUG 2013): 0 = disabled
    protected int    xml_handle = 0;

    // characters that are invalid XML data and have to be encoded
    protected string xml_replacements[string] = '{
        "<" : "&lt;", "&" : "&amp;", ">" : "&gt;",
        "'" : "&apos;", "\"" : "&quot;"
    };

    function new(string name = "scr1_report_server");
      string xml_path;
      super.new(name);
      if ($value$plusargs("SCR1_XML_LOG=%s", xml_path)) begin
        open_xml_log(xml_path);
      end else if ($test$plusargs("SCR1_XML_LOG")) begin
        open_xml_log("logs/scr1_log.xml");
      end
    endfunction : new

    // open the XML log + document header (the file is server-private)
    protected function void open_xml_log(string path);
      xml_handle = $fopen(path, "w");
      if (xml_handle == 0) begin
        `uvm_warning("SCR1/REPORT/SERVER",
            $sformatf("cannot open XML log '%s' - XML logging disabled", path))
        return;
      end
      f_display(xml_handle,
          "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<log>\n");
    endfunction : open_xml_log

    // replace reserved XML characters (backwards scan keeps inserted
    // entities intact; SNUG 2013 sanitize pattern)
    protected function string xml_sanitize(string data);
      string ch;
      for (int i = data.len()-1; i >= 0; i--) begin
        ch = data.substr(i, i);
        if (xml_replacements.exists(ch)) begin
          data = {data.substr(0, i-1), xml_replacements[ch],
                  data.substr(i+1, data.len()-1)};
        end
      end
      xml_sanitize = data;
    endfunction : xml_sanitize

    // XML attribute: tag="data" (empty data -> no attribute)
    protected function string xla(string tag, string data);
      xla = "";
      if (data != "") begin
        xla = {" ", tag, "=\"", xml_sanitize(data), "\""};
      end
    endfunction : xla

    // XML element: <tag attributes>data</tag>
    protected function string xle(string tag, string data,
        string attributes = "");
      xle = "";
      if (data != "") begin
        xle = {"<", tag, attributes, ">", xml_sanitize(data),
               "</", tag, ">\n"};
      end
    endfunction : xle

    // One <msg> element with the full message meta-data
    protected function void write_xml_message(uvm_report_message rm);
      string time_str;
      string context_str;
      uvm_report_handler rh;
      time_str = $sformatf("%0t", $realtime);
      rh = rm.get_report_handler();
      context_str = (rh != null) ? rh.get_full_name() : "";
      f_display(xml_handle, xle("msg", rm.get_message(),
          {xla("verbosity", $sformatf("%0d", rm.get_verbosity())),
           xla("severity", rm.get_severity().name()),
           xla("file", rm.get_filename()),
           xla("line", $sformatf("%0d", rm.get_line())),
           xla("id", rm.get_id()),
           xla("time", time_str),
           xla("context", context_str)}));
    endfunction : write_xml_message

    // account error/fatal per ID + histogram verbosities, then hand over to
    // the default server (severity/quit counting, actions)
    virtual function void process_report_message(
        uvm_report_message report_message);
      string       id;
      uvm_severity sev;
      int          verb;
      sev  = report_message.get_severity();
      id   = report_message.get_id();
      verb = report_message.get_verbosity();
      if (verb_count.exists(verb)) begin
        verb_count[verb]++;
      end else begin
        verb_count[verb] = 1;
      end
      if (sev == UVM_ERROR || sev == UVM_FATAL) begin
        if (err_id_count.exists(id)) begin
          err_id_count[id]++;
        end else begin
          err_id_count[id] = 1;
          err_id_first[id] = report_message.get_message();
          err_id_time[id]  = $sformatf("%0t", $realtime);
          if (report_message.get_filename() != "") begin
            err_id_loc[id] = $sformatf("%s(%0d)",
                report_message.get_filename(), report_message.get_line());
          end else begin
            err_id_loc[id] = "n/a";
          end
        end
      end
      super.process_report_message(report_message);
      if (xml_handle != 0) begin
        write_xml_message(report_message);
      end
    endfunction : process_report_message

    // verbosity -> enum name, or number for intermediate/custom levels
    protected function string verbosity_name(int verbosity);
      uvm_verbosity v;
      if ($cast(v, verbosity)) begin
        verbosity_name = v.name();
      end else begin
        verbosity_name = $sformatf("%0d", verbosity);
      end
    endfunction : verbosity_name

    // <summary> element: severity + SCR1_RESULT counters + verdict line;
    // the caller closes the document
    protected function void write_xml_summary(string test_name,
        bit verdict_ok);
      uvm_severity sevs[4] = '{UVM_FATAL, UVM_ERROR, UVM_WARNING,
                               UVM_INFO};
      f_display(xml_handle, {"<summary",
          xla("time", $sformatf("%0t", $realtime)),
          xla("test", test_name),
          xla("seed", $sformatf("%0d", $get_initial_random_seed)),
          xla("verdict", verdict_ok ? "PASS" : "FAIL"), ">\n"});
      foreach (sevs[i]) begin
        f_display(xml_handle, xle("sev",
            $sformatf("%0d", get_severity_count(sevs[i])),
            xla("name", sevs[i].name())));
      end
      f_display(xml_handle, {"<counters",
          xla("runs_checked", $sformatf("%0d", g_runs_checked)),
          xla("runs_passed", $sformatf("%0d", g_runs_passed)),
          xla("runs_failed", $sformatf("%0d", g_runs_failed)),
          xla("diff_checked", $sformatf("%0d", g_diff_checked)),
          xla("diff_mismatches", $sformatf("%0d", g_diff_mismatches)),
          xla("trap_checked", $sformatf("%0d", g_diff_traps)),
          xla("csr_checked", $sformatf("%0d", g_csr_checked)),
          xla("csr_live", $sformatf("%0d", g_csr_live)),
          xla("csr_mismatches", $sformatf("%0d", g_csr_mismatches)),
          " />\n"});
      f_display(xml_handle, xle("verdict",
          $sformatf({"SCR1_RESULT: %s (UVM_ERROR=%0d UVM_FATAL=%0d ",
                     "runs_failed=%0d diff_mismatches=%0d ",
                     "csr_mismatches=%0d)"},
              verdict_ok ? "PASS" : "FAIL",
              get_severity_count(UVM_ERROR),
              get_severity_count(UVM_FATAL), g_runs_failed,
              g_diff_mismatches, g_csr_mismatches),
          xla("result", verdict_ok ? "PASS" : "FAIL")));
      f_display(xml_handle, "</summary>\n");
    endfunction : write_xml_summary

    // standard UVM summary first, then the env section
    virtual function void summarize(UVM_FILE file = UVM_STDOUT);
      string q[$];
      uvm_component test_h;
      string test_name;
      bit    verdict_ok;
      int    std_verbs[6] = '{UVM_NONE, UVM_LOW, UVM_MEDIUM,
                              UVM_HIGH, UVM_FULL, UVM_DEBUG};
      int    other_cnt;
      bit    is_std;
      super.summarize(file);

      q.push_back("\n--- SCR1 Report Server Summary ---\n");

      // ---- run info ----
      test_h    = uvm_root::get().get_child("uvm_test_top");
      test_name = (test_h != null) ? test_h.get_type_name() : "unknown";
      q.push_back("** Run info\n");
      q.push_back($sformatf("test          : %s\n", test_name));
      q.push_back($sformatf("UVM           : %s\n", uvm_revision_string()));
      q.push_back($sformatf("sim time      : %0.0f ns (%0t)\n",
          $realtime, $realtime));
      q.push_back($sformatf("verbosity     : %s\n",
          verbosity_name(uvm_top.get_report_verbosity_level(UVM_INFO))));
      q.push_back($sformatf({"seed          : %0d ",
          "(reproduce: +verilator+seed+%0d)\n"},
          $get_initial_random_seed, $get_initial_random_seed));
      q.push_back($sformatf({"DUT           : scr1_top_ahb ",
          "(RST_CYCLES=%0d TIMEOUT_CYCLES=%0d NUM_RUNS=%0d)\n"},
          RST_CYCLES, TIMEOUT_CYCLES, NUM_RUNS));

      // ---- compile-time configuration ----
      q.push_back("** Config (scr1_cfg_pkg)\n");
      q.push_back($sformatf({"XLEN=%0d IPIC_EN=%0b MEPC_PAD=%0d ",
          "SPIKE_ISA=%s\n"}, XLEN, IPIC_EN, MEPC_PAD, SPIKE_ISA));
`ifdef SCR1_MEM_AGENT
      q.push_back("memory path   : reactive UVM AHB agent (MEM_AGENT=1)\n");
`else
      q.push_back("memory path   : legacy scr1_memory_tb_ahb (MEM_AGENT=0)\n");
`endif

      // ---- SCR1_RESULT verdict counters ----
      q.push_back("** Verdict counters (SCR1_RESULT inputs)\n");
      q.push_back($sformatf({"runs          : checked=%0d passed=%0d ",
          "failed=%0d console_chars=%0d\n"},
          g_runs_checked, g_runs_passed, g_runs_failed,
          g_console_chars));
      q.push_back($sformatf({"diff lockstep : checked=%0d matched=%0d ",
          "mismatches=%0d skipped=%0d traps=%0d\n"},
          g_diff_checked, g_diff_matched, g_diff_mismatches,
          g_diff_skipped, g_diff_traps));
      q.push_back($sformatf("csr           : checked=%0d live=%0d mismatches=%0d\n",
          g_csr_checked, g_csr_live, g_csr_mismatches));

      // ---- verbosity histogram (the meta-data the default summary hides) ----
      q.push_back("** Report counts by verbosity\n");
      foreach (std_verbs[i]) begin
        q.push_back($sformatf("%-10s : %0d\n", verbosity_name(std_verbs[i]),
            verb_count.exists(std_verbs[i]) ? verb_count[std_verbs[i]] : 0));
      end
      other_cnt = 0;
      foreach (verb_count[k]) begin
        is_std = 0;
        foreach (std_verbs[i]) begin
          if (k == std_verbs[i]) begin
            is_std = 1;
          end
        end
        if (!is_std) begin
          other_cnt += verb_count[k];
        end
      end
      if (other_cnt > 0) begin
        q.push_back($sformatf("%-10s : %0d\n", "other", other_cnt));
      end

      // ---- error/fatal triage ----
      if (err_id_count.size() == 0) begin
        q.push_back("** Error/fatal messages by id: none\n");
      end else begin
        q.push_back("** Error/fatal messages by id (first occurrence kept for triage)\n");
        foreach (err_id_count[id]) begin
          q.push_back($sformatf("[%s] %5d : @ %s %s : %s\n",
              id, err_id_count[id], err_id_time[id], err_id_loc[id],
              err_id_first[id]));
        end
      end

      // ---- final verdict (SCR1_RESULT-equivalent; the console SCR1_RESULT
      // line is emitted by scr1_base_test - the grep contract is single-sourced) ----
      verdict_ok = (get_severity_count(UVM_ERROR) == 0) &&
                   (get_severity_count(UVM_FATAL) == 0) &&
                   (g_runs_failed == 0) &&
                   (g_diff_mismatches == 0) &&
                   (g_csr_mismatches == 0);
      q.push_back("** Verdict (report server)\n");
      q.push_back($sformatf({"verdict       : %s (UVM_ERROR=%0d ",
          "UVM_FATAL=%0d runs_failed=%0d diff_mismatches=%0d ",
          "csr_mismatches=%0d)\n"},
          verdict_ok ? "PASS" : "FAIL",
          get_severity_count(UVM_ERROR), get_severity_count(UVM_FATAL),
          g_runs_failed, g_diff_mismatches, g_csr_mismatches));

      if (file == UVM_STDOUT) begin
        `uvm_info("SCR1/REPORT/SERVER",
            `UVM_STRING_QUEUE_STREAMING_PACK(q), UVM_NONE)
      end else begin
        foreach (q[i]) begin
          f_display(file, q[i]);
        end
      end

      // close the XML document last so the summary messages are captured too
      if (xml_handle != 0) begin
        write_xml_summary(test_name, verdict_ok);
        f_display(xml_handle, "</log>\n");
        $fclose(xml_handle);
        xml_handle = 0;
      end
    endfunction : summarize

  endclass : scr1_report_server
