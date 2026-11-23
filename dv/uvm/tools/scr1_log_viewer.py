#!/usr/bin/env python3
# ============================================================
# File    : scr1_log_viewer.py
# Author  : M.YarosLove <yoruk91@gmail.com>
# Project : UVM verification environment for the SCR1 core (Verilator)
# ------------------------------------------------------------
# Viewer for the structured XML logs produced by the env report
# server (tb/env/environment/scr1_report_server.sv, +SCR1_XML_LOG=<path>), after
# "Applications of Custom UVM Report Servers", G. McGregor,
# SNUG 2013 (sections 7, 8, 16).
#
# All message meta-data (verbosity/severity/file/line/id/time/
# context) is stored in the XML log, so the visible format and
# the filters are chosen at view time - no re-simulation needed:
#   - collapse to UVM_LOW/UVM_NONE for the high-level test flow,
#     expand to UVM_HIGH/UVM_DEBUG for details;
#   - filter by severity, message id, component or source file;
#   - reformat messages with a ${...} template on the fly.
#
# Usage:
#   GUI : python3 tools/scr1_log_viewer.py logs/scr1_log.xml
#         (or: make viewer XML_LOG=logs/scr1_log.xml)
#   CLI : python3 tools/scr1_log_viewer.py logs/scr1_log.xml --text \
#             [--verbosity UVM_LOW] [--severity UVM_ERROR] \
#             [--id ID] [--context COMP] [--file SRC] [--format FMT]
#
# The CLI mode is headless (no tkinter required) and suits CI
# summaries / log checkers; the GUI mode needs python3-tk.
# ============================================================

import argparse
import string
import sys
import xml.etree.ElementTree as ET

UVM_VERBOSITIES = {
    "UVM_NONE": 0, "UVM_LOW": 100, "UVM_MEDIUM": 200,
    "UVM_HIGH": 300, "UVM_FULL": 400, "UVM_DEBUG": 500,
}
VERBOSITY_NAMES = {v: k for k, v in UVM_VERBOSITIES.items()}

# ${...} placeholders: any <msg> attribute plus verbosity_str/msg
DEFAULT_FORMATS = (
    "${severity}(${verbosity_str}) ${file}(${line}) @ ${time} : "
    "${context} [${id}] ${msg}",
    "${verbosity_str} @ ${time} : ${context} [${id}] ${msg}",
    "${severity} @ ${time} : ${context} [${id}] ${msg}",
    "${time} : ${context} ${msg}",
)

ALL = "ALL"  # filter sentinel: no restriction


def verbosity_str(value):
    """Numeric verbosity -> enum name, or the number itself for
    intermediate/custom levels (SNUG 2013 pattern)."""
    try:
        v = int(value)
    except (TypeError, ValueError):
        return str(value)
    return VERBOSITY_NAMES.get(v, str(v))


def load_log(path):
    """Parse the XML log into a list of message dicts (DOM style,
    like the paper). A log truncated by an aborted simulation is
    recovered by cutting back to the last complete </msg>."""
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        with open(path, encoding="utf-8", errors="replace") as f:
            raw = f.read()
        cut = raw.rfind("</msg>")
        if "</log>" in raw or cut < 0:
            raise
        root = ET.fromstring(raw[:cut + len("</msg>")] + "\n</log>")
    msgs = []
    for el in root:
        if el.tag != "msg":
            continue  # non-UVM sources are not produced by the env
        m = {k: "" for k in
             ("verbosity", "severity", "file", "line", "id", "time",
              "context")}
        m.update(el.attrib)
        m["msg"] = el.text or ""
        msgs.append(m)
    return msgs


def render(m, fmt):
    """Apply a ${...} format template to one message."""
    fields = dict(m)
    fields["verbosity_str"] = verbosity_str(m.get("verbosity", "0"))
    return string.Template(fmt).safe_substitute(fields)


def filter_msgs(msgs, verbosity=None, severity=None, msg_id=None,
                context=None, src_file=None):
    """Verbosity filter keeps levels <= the selected one (UVM_LOW
    shows UVM_NONE + UVM_LOW); the rest are exact matches."""
    limit = UVM_VERBOSITIES.get(verbosity) if verbosity else None
    out = []
    for m in msgs:
        if limit is not None:
            try:
                if int(m["verbosity"]) > limit:
                    continue
            except (TypeError, ValueError):
                continue
        if severity and m["severity"] != severity:
            continue
        if msg_id and m["id"] != msg_id:
            continue
        if context and m["context"] != context:
            continue
        if src_file and m["file"] != src_file:
            continue
        out.append(m)
    return out


def unique_values(msgs, key):
    return sorted({m[key] for m in msgs if m.get(key)})


# ------------------------------------------------------------
# CLI mode (paper section 7: scripted log reconstruction)
# ------------------------------------------------------------
def run_cli(args):
    msgs = load_log(args.log)
    shown = filter_msgs(msgs, args.verbosity, args.severity, args.id,
                        args.context, args.file)
    fmt = args.format or DEFAULT_FORMATS[0]
    for m in shown:
        print(render(m, fmt))
    print(f"-- shown {len(shown)} / {len(msgs)} messages "
          f"({args.log})", file=sys.stderr)
    return 0


# ------------------------------------------------------------
# GUI mode (paper section 16: interactive filtering)
# ------------------------------------------------------------
def run_gui(args):
    import tkinter as tk
    from tkinter import ttk, simpledialog, filedialog, messagebox

    class Scr1LogViewer(tk.Tk):
        def __init__(self, path=None):
            super().__init__()
            self.msgs = []
            self.path = None
            self.title("SCR1 XML Log Viewer")
            self.geometry("1200x700")
            self._build_toolbar()
            self._build_text()
            self._build_status()
            if path:
                self.open_log(path)
            else:
                self.choose_log()

        # ---- widgets ----
        def _build_toolbar(self):
            bar = ttk.Frame(self)
            bar.pack(fill=tk.X, padx=4, pady=2)

            ttk.Label(bar, text="Format:").pack(side=tk.LEFT)
            self.format = tk.StringVar(value=DEFAULT_FORMATS[0])
            fmt = ttk.Combobox(bar, textvariable=self.format,
                               values=DEFAULT_FORMATS, width=90)
            fmt.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=2)
            fmt.bind("<Return>", self.refresh)
            fmt.bind("<<ComboboxSelected>>", self.refresh)

            row = ttk.Frame(self)
            row.pack(fill=tk.X, padx=4, pady=2)
            self.filters = {}
            for name, values in (
                    ("verbosity", [ALL] + list(UVM_VERBOSITIES)),
                    ("severity", [ALL]),
                    ("context", [ALL]),
                    ("id", [ALL]),
                    ("file", [ALL])):
                ttk.Label(row, text=name + ":").pack(side=tk.LEFT)
                var = tk.StringVar(value=ALL)
                cb = ttk.Combobox(row, textvariable=var, width=18,
                                  state="readonly", values=values)
                cb.pack(side=tk.LEFT, padx=(0, 6))
                cb.bind("<<ComboboxSelected>>", self.refresh)
                self.filters[name] = (var, cb)

            ttk.Button(row, text="Find", command=self.on_find).pack(
                side=tk.LEFT, padx=2)
            ttk.Button(row, text="Open", command=self.choose_log).pack(
                side=tk.LEFT, padx=2)
            ttk.Button(row, text="Quit", command=self.destroy).pack(
                side=tk.RIGHT, padx=2)

        def _build_text(self):
            frame = ttk.Frame(self)
            frame.pack(fill=tk.BOTH, expand=True, padx=4, pady=2)
            sbar = ttk.Scrollbar(frame)
            sbar.pack(side=tk.RIGHT, fill=tk.Y)
            self.text = tk.Text(frame, wrap=tk.NONE, font=("Courier", 10),
                                yscrollcommand=sbar.set)
            self.text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
            sbar.config(command=self.text.yview)
            # severity highlighting (paper: future work, kept simple)
            self.text.tag_configure("UVM_FATAL", foreground="#c00000",
                                    font=("Courier", 10, "bold"))
            self.text.tag_configure("UVM_ERROR", foreground="#c00000")
            self.text.tag_configure("UVM_WARNING", foreground="#b25000")
            self.text.tag_configure("UVM_INFO", foreground="#000000")
            self.text.tag_configure("found", background="#fff2a8")

        def _build_status(self):
            self.status = tk.StringVar(value="no log loaded")
            ttk.Label(self, textvariable=self.status,
                      relief=tk.SUNKEN).pack(fill=tk.X, side=tk.BOTTOM)

        # ---- data ----
        def choose_log(self):
            path = filedialog.askopenfilename(
                title="Open SCR1 XML log",
                filetypes=[("XML logs", "*.xml"), ("All files", "*")])
            if path:
                self.open_log(path)

        def open_log(self, path):
            try:
                self.msgs = load_log(path)
            except (ET.ParseError, OSError) as exc:
                messagebox.showerror("SCR1 XML Log Viewer",
                                     f"Cannot parse {path}:\n{exc}")
                return
            self.path = path
            self.title(f"SCR1 XML Log Viewer - {path}")
            for name, key in (("severity", "severity"),
                              ("context", "context"),
                              ("id", "id"), ("file", "file")):
                var, cb = self.filters[name]
                cb["values"] = [ALL] + unique_values(self.msgs, key)
                var.set(ALL)
            self.refresh()

        def selected(self, name):
            value = self.filters[name][0].get()
            return None if value == ALL else value

        # ---- view ----
        def refresh(self, *_):
            if not self.msgs:
                return
            shown = filter_msgs(
                self.msgs,
                verbosity=self.selected("verbosity"),
                severity=self.selected("severity"),
                msg_id=self.selected("id"),
                context=self.selected("context"),
                src_file=self.selected("file"))
            fmt = self.format.get() or DEFAULT_FORMATS[0]
            self.text.config(state=tk.NORMAL)
            self.text.delete("1.0", tk.END)
            for m in shown:
                tag = m["severity"] if m["severity"] in (
                    "UVM_FATAL", "UVM_ERROR", "UVM_WARNING") else "UVM_INFO"
                self.text.insert(tk.END, render(m, fmt) + "\n", tag)
            self.text.config(state=tk.DISABLED)
            self.status.set(f"shown {len(shown)} / {len(self.msgs)} "
                            f"messages - {self.path}")

        def on_find(self):
            target = simpledialog.askstring("Find", "Search string:",
                                            parent=self)
            if not target:
                return
            self.text.tag_remove("found", "1.0", tk.END)
            pos = self.text.search(target, tk.INSERT, tk.END,
                                   nocase=True)
            if not pos:  # wrap around
                pos = self.text.search(target, "1.0", tk.END, nocase=True)
            if pos:
                end = f"{pos}+{len(target)}c"
                self.text.tag_add("found", pos, end)
                self.text.tag_add(tk.SEL, pos, end)
                self.text.mark_set(tk.INSERT, end)
                self.text.see(pos)
            self.text.focus_set()

    app = Scr1LogViewer(args.log)
    app.mainloop()
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Viewer for SCR1 env XML logs (SNUG 2013 pattern)")
    ap.add_argument("log", nargs="?", help="XML log file "
                    "(+SCR1_XML_LOG=<path> simulation output)")
    ap.add_argument("--text", action="store_true",
                    help="headless mode: print filtered log to stdout")
    ap.add_argument("--verbosity", choices=list(UVM_VERBOSITIES),
                    help="keep messages at this level or lower")
    ap.add_argument("--severity", help="exact severity (UVM_ERROR...)")
    ap.add_argument("--id", help="exact message id")
    ap.add_argument("--context", help="exact component full name")
    ap.add_argument("--file", help="exact source file name")
    ap.add_argument("--format", help="${...} message template")
    args = ap.parse_args()

    if args.text:
        if not args.log:
            ap.error("--text requires the log file argument")
        return run_cli(args)
    return run_gui(args)


if __name__ == "__main__":
    sys.exit(main())
