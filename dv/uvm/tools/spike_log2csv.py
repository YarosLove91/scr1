#!/usr/bin/env python3
"""Spike commit log -> golden CSV for the UVM diff scoreboard (pattern 2A).

Usage:
  spike_log2csv.py --elf prog.elf --out prog.csv [--spike /path/to/spike]
  spike_log2csv.py --log existing_commits.log --out prog.csv

CSV record per committed instruction:
  <pc_hex>,<instr_hex>,<wr 0|1>,<rd_dec>,<rd_data_hex>
Lines starting with '#' are comments (the SV loader skips them).

Parsing rules (Spike --log-commits format):
  - commit lines:  core N: <priv> 0x<PC> (0x<INSTR>) [disasm] [x<R> 0x<VAL>]
                                                           [c<NNN>_<name> 0x<VAL>]
  - plain disasm lines (no priv field) are skipped;
  - GPR writeback  x<R> 0x<VAL>  -> wr=1, rd=R, val;
  - CSR writebacks are attached as comment lines (CSR comparison is a
    later milestone - RAL);
  - exception/trap lines are counted and skipped (trap alignment is not
    part of 2A; the UVM scoreboard skips DUT trap commits too);
  - parsing stops after the commit of EXIT_PC=0xF8 (SCR1 tb convention).

Spike flags replicate docker/scr1-spike/compare_state.py (proven on SCR1
vectors): --no-dm --disable-dtb --pc=0x200 --isa=rv32imc_zicsr_zifencei
-m0x0:0x10000,0x480000:0x10000,0x490000:0x1000,0xf0000000:0x1000 -l
--log-commits.
"""
import argparse
import re
import subprocess
import sys

EXIT_PC = 0xF8

RE_COMMIT = re.compile(r"core\s+\d+:\s+(\d+)\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)")
RE_GPR = re.compile(r"\bx\s*(\d+)\s+0x([0-9a-f]+)")
RE_CSR = re.compile(r"\bc(\d+)_(\w+)\s+0x([0-9a-f]+)")
RE_EXC = re.compile(r"core\s+\d+:\s+exception\s+(\S+)")

SPIKE_FLAGS = [
    "--disable-dtb", "--pc=0x200",
    "--isa=rv32imc_zicsr_zifencei",
    "-m0x0:0x10000,0x480000:0x10000,0x490000:0x1000,0xf0000000:0x1000",
    "-l", "--log-commits",
]


def spike_supports(spike, opt):
    """Newer Spike masters reserve [0x0,0x1000) for the debug module and
    need --no-dm; older ones do not know the option. Detect via --help."""
    try:
        h = subprocess.run([spike, "--help"], capture_output=True, text=True)
        return opt in (h.stdout + h.stderr)
    except OSError:
        return False


def convert(lines, out_path, max_commits=2_000_000):
    n_commits = n_exc = n_csr = 0
    stopped = False
    with open(out_path, "w") as f:
        f.write("# golden commits: pc,instr,wr,rd,rd_data (Spike --log-commits)\n")
        for line in lines:
            m = RE_COMMIT.match(line)
            if not m:
                if RE_EXC.match(line):
                    n_exc += 1
                continue
            n_commits += 1
            if n_commits > max_commits:
                print(f"ERROR: {max_commits} commits without reaching "
                      f"EXIT_PC 0xF8 - runaway program? aborting", file=sys.stderr)
                sys.exit(4)
            pc = int(m.group(2), 16)
            instr = int(m.group(3), 16)
            rest = m.group(4)
            wr, rd, val = 0, 0, 0
            mg = RE_GPR.search(rest)
            if mg:
                wr, rd, val = 1, int(mg.group(1)), int(mg.group(2), 16)
            f.write(f"{pc:08x},{instr:08x},{wr},{rd},{val:08x}\n")
            for mc in RE_CSR.finditer(rest):
                n_csr += 1
                f.write(f"# csr c{mc.group(1)}_{mc.group(2)} = 0x{mc.group(3)}\n")
            if pc == EXIT_PC:
                stopped = True
                break
    return n_commits, n_exc, n_csr, stopped


def main():
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--elf", help="program ELF to run under Spike")
    src.add_argument("--log", help="pre-recorded Spike commit log")
    ap.add_argument("--out", required=True, help="output CSV path")
    ap.add_argument("--spike", default="spike", help="Spike binary (default: spike)")
    ap.add_argument("--keep-log", default=None, help="also save the raw Spike log here")
    args = ap.parse_args()

    if args.log:
        with open(args.log, errors="ignore") as f:
            n, ne, nc, stopped = convert(f, args.out)
    else:
        flags = (["--no-dm"] if spike_supports(args.spike, "--no-dm") else []) + SPIKE_FLAGS
        cmd = [args.spike] + flags + [args.elf]
        print("RUN:", " ".join(cmd), flush=True)
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
        kf = open(args.keep_log, "w") if args.keep_log else None
        try:
            n, ne, nc, stopped = convert(p.stdout, args.out) if kf is None else \
                convert(tee(p.stdout, kf), args.out)
        finally:
            p.kill()
            p.wait()
            if kf:
                kf.close()

    print(f"commits={n} exceptions_skipped={ne} csr_notes={nc} reached_0xF8={stopped}")
    print(f"CSV: {args.out}")
    if not stopped:
        print("WARN: exit PC 0xF8 not reached - golden stream may be incomplete",
              file=sys.stderr)
        sys.exit(3)


def tee(it, f):
    for x in it:
        f.write(x)
        yield x


if __name__ == "__main__":
    main()
