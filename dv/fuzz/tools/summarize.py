#!/usr/bin/env python3
"""summarize.py — SCR1 fuzz regression summary table.

Scans work/seed_*/run.log, extracts the SCR1_RESULT verdict line and the
diff/CSR/run scoreboard summaries, prints a per-seed table and the totals.
Exit code: 0 = all PASS, 1 = at least one FAIL/missing verdict.

Usage: summarize.py [--work-dir DIR] [--test NAME]
"""
import argparse
import glob
import os
import re
import sys

RE_RESULT = re.compile(
    r"SCR1_RESULT:\s+(PASS|FAIL).*?runs_checked=(\d+).*?"
    r"diff_checked=(\d+)\s+diff_mismatches=(\d+)(?:\s+trap_checked=(\d+))?")
RE_CSR = re.compile(
    r"CSR snapshots checked:\s+(\d+)\s+\|"
    r"(?: live CSR events golden-checked:\s+\d+\s+\|)?"
    r"\s*mismatches:\s+(\d+)")
RE_DIFF = re.compile(
    r"commits checked (\d+) \| matched (\d+) \| mismatches (\d+) \|"
    r"(?: traps compared (\d+) \|)? skipped (\d+)")
RE_UVM_ERR = re.compile(r"UVM_ERROR :\s+(\d+)")
RE_TIMEOUT = re.compile(r"\.TIMEOUT\]")
# driver CFG_RANDOM banner: "random wait states: AGENT_RANDOM_STALL=<max> ..."
RE_STALL = re.compile(r"AGENT_RANDOM_STALL=(\d+)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work-dir", default="work")
    ap.add_argument("--test", default=None, help="filter by test name")
    args = ap.parse_args()

    rows = []
    n_pass = n_fail = 0
    # only well-formed seed_<digits> dirs (work/ may hold scratch dirs)
    logs = [p for p in glob.glob(os.path.join(args.work_dir, "seed_*", "run.log"))
            if re.search(r"seed_(\d+)", p)]
    for log in sorted(logs,
                      key=lambda p: int(re.search(r"seed_(\d+)", p).group(1))):
        seed = re.search(r"seed_(\d+)", log).group(1)
        with open(log, errors="ignore") as f:
            text = f.read()
        if args.test and f"TEST={args.test}" not in text and args.test not in text:
            continue
        m = RE_RESULT.search(text)
        csr = RE_CSR.search(text)
        diff = RE_DIFF.search(text)
        err = RE_UVM_ERR.search(text)
        stall = RE_STALL.search(text)
        timeout = bool(RE_TIMEOUT.search(text))
        if m:
            verdict = m.group(1)
            runs, dchk, dmis = m.group(2), m.group(3), m.group(4)
            traps = m.group(5) if m.group(5) is not None else "?"
        else:
            verdict, runs, dchk, dmis, traps = "NO_VERDICT", "?", "?", "?", "?"
        if diff and diff.group(4) is not None:
            traps = diff.group(4)
        rows.append((
            seed,
            verdict + (" (TIMEOUT)" if timeout else ""),
            stall.group(1) if stall else "-",
            runs,
            f"{diff.group(1)}" if diff else dchk,
            f"{diff.group(3)}" if diff else dmis,
            traps,
            f"{csr.group(2)}" if csr else "?",
            err.group(1) if err else "?",
        ))
        if verdict == "PASS" and not timeout:
            n_pass += 1
        else:
            n_fail += 1

    hdr = ("seed", "verdict", "stall", "runs", "commits", "diff_mm", "traps",
           "csr_mm", "uvm_err")
    widths = [max(len(str(r[i])) for r in rows + [hdr]) if rows else len(hdr[i])
              for i in range(len(hdr))]
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(hdr))
    print(line)
    print("-" * len(line))
    for r in rows:
        print("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(r)))
    print()
    print(f"TOTAL: {len(rows)} seeds | PASS {n_pass} | FAIL {n_fail}")
    sys.exit(0 if n_fail == 0 and rows else 1)


if __name__ == "__main__":
    main()
