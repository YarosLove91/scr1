#!/usr/bin/env python3
"""patch_asm.py — adapt a riscv-dv (pygen) program for the SCR1 UVM flow.

Transformations of the generated .S:

1. EXIT EPILOGUE. riscv-dv ends the program with
       test_done: li gp, 1; ecall
       write_tohost: sw gp, tohost, t5 ; _exit: j write_tohost
   The SCR1 testbench convention is different: a run finishes when the PC
   reaches 0xF8 (SCR1_SIM_EXIT_ADDR) and a0 (x10) == 0 means PASS. The
   write_tohost block is therefore replaced with:
       gp == 1 (riscv-dv pass) -> a0 = 0; otherwise a0 = gp (fail code);
       then jump to 0xF8.

2. STACK SHRINK. pygen emits `.rept 4999` (user) / `.rept 3999` (kernel)
   stack fills = 36 KB; together with the text they overflow the 64 KB SCR1
   RAM window. Every `.rept N` with N > --stack-max is capped.

3. MTVEC ALIGNMENT. SCR1 hardwires mtvec.BASE[5:0] to zero (64-byte
   granularity, see scr1_csr.svh "bits [5:0] are always zero"): a handler
   base that is not 64-byte aligned is silently truncated by the core, so
   traps land mid-instruction (illegal-instruction trap loop), while Spike
   honors the full base and diverges. Found by the seed regression
   (seed 1140580336: mtvec_handler at 0xfd0 -> SCR1 trapped to 0xfc0).
   Fix: force `.balign 64` before the mtvec_handler label.

4. CSR INJECTION (--csr-inject N, --csr-seed S). pygen master NEVER emits
   CSR instructions in the random body - two independent bugs in
   build_basic_instruction_list() (riscv_instr.py:199-205):
     a) the CSR category is gated on `init_privileged_mode ==
        "MACHINE_MODE"`, but init_privileged_mode is the ENUM
        privileged_mode_t.MACHINE_MODE - the string compare is always
        False (the same compare in create_csr_filter leaves include_reg
        empty);
     b) category lists (SYNCH/CSR) are appended to basic_instr as NESTED
        lists and selection uses random.randrange(0, len-1) - the LAST
        element is never picked; with the defaults no_wfi/no_ebreak/
        no_dret=1 the SYNCH list is last whenever +no_fence is dropped
        (=> riscv_fence_test silently generates NO fences either).
   Until upstream is fixed, N random CSR instructions are injected here
   into the body region (between `main:` and `test_done:`), deterministic
   per --csr-seed.

   CSR whitelist (SCR1-vs-Spike lockstep safety, full WARL analysis):
     mepc 0x341, mtval 0x343 - ALL forms (csrrw/csrrs/csrrc + i-variants
       + csrr): architecturally identical storage (mepc bit0 masked by
       RVC on both models) so read-backs compare equal; hardware
       overwrites both on trap entry; no mret exists in the body (the
       CSR category is dead in pygen);
     mscratch 0x340 - READ form only (csrr): it is the trap handler's
       swap scratch (csrrw xB, 0x340, xB); the swap is symmetric so its
       pre-trap value does not matter, but writes buy nothing - the
       handler already covers the cp_csr bin;
     mcause 0x342 - WRITE-only forms (rd=x0): WARL read-back diverges
       (SCR1 stores {i,25'b0,ec[5:0]}, Spike wider); the stored value is
       never cross-compared (RAL snapshot is DUT-side, the next trap
       overwrites it identically on both models);
     mstatus 0x300 - rd=x0 csrrsi/csrrci ONLY (uimm touches bits 0-4):
       MPP bits [12:11] must stay 11 - Spike HONORS MPP at mret (SCR1
       hardwires 11), so a random full-width write would send the golden
       model to another privilege mode at the terminal ecall's mret.
       MIE (bit 3) cannot raise an IRQ: mie stays 0.
   Excluded on purpose: mtvec 0x305 (SCR1 64B BASE granularity vs Spike
     4B - handler-base divergence, see transform 3), misa 0x301 (SCR1 RO
     vs Spike writable), mie/mip (unalignable IRQ risk / RO), counters
     B00/B02/B80/B82/C00-C02/C80-C82 (timing by nature), mcounten 0x7E0
     + IPIC 0xBF0-0xBF7 + TDU 0x7A0-0x7A7 (SCR1-only: Spike takes an
     illegal-instruction trap - stream divergence), mvendorid/marchid/
     mimpid/mhartid F11-F14 (different constants per model).

   Register pool for rd/rs1: x5-x31 minus STATIC contracts (x10 a0
   verdict, x27/x29 observed handler regs, x1-x4 ra/sp/gp/tp) minus the
   kernel/user STACK BASE registers, parsed dynamically: pygen randomizes
   per seed which register holds `la xR, kernel_stack_end` (observed x29
   AND x31), and the trap handler reads it BEFORE writing (`add xB, xR`).
   Other handler registers are safe to clobber: the save/restore sequence
   (sw/lw x1..x31 around the handler body) is symmetric, so any body value
   at trap time is restored identically on both models; dispatch temps
   (csrr/li/la targets) are rewritten by the handler before use.
   Clobbering the stack base sends the handler's save sequence to a
   garbage address, where the SCR1 memory tb WRAPS the store while Spike
   FAULTS (store access fault) - caught by the seed regression (seed
   601266182: injected `csrrc x31, ...` destroyed `la x31,
   kernel_stack_end`; mcause=7 divergence at the terminal ecall).

Usage: patch_asm.py --in gen.S --out patched.S [--stack-max 1000]
       [--csr-inject 12 --csr-seed 42]
"""
import argparse
import random
import re
import sys

EPILOGUE = """write_tohost:
                  # SCR1 exit epilogue (dv/fuzz/tools/patch_asm.py):
                  # riscv-dv pass (gp==1) -> a0=0, otherwise a0=gp; then 0xF8
                  li   a0, 1
                  beq  gp, a0, scr1_pass
                  mv   a0, gp
                  j    scr1_exit
scr1_pass:
                  li   a0, 0
scr1_exit:
                  li   t0, 0xF8
                  jr   t0
_exit:
                  j    scr1_exit

"""

# Endless loop placed at 0xF8 (link.ld .exit_vec): the SCR1 tb convention
# expects a legal spin instruction at the exit marker (the native crt does
# the same); zeros there trap forever with mcause=2 after the run verdict.
EXIT_VEC = """.section .exit_vec,"ax"
.align 2
_exit_vec:
                  j .
.text
"""

RE_REPT = re.compile(r"^(\s*\.rept\s+)(\d+)(\s*)$")
RE_MTVEC_HANDLER = re.compile(r"^\s*mtvec_handler\s*:")
RE_MAIN = re.compile(r"^main\s*:")
RE_TEST_DONE = re.compile(r"^test_done\s*:")
RE_BODY_INSTR = re.compile(r"^\s+\S")

# CSR-injection whitelist (WARL analysis in the module docstring)
CSR_RW_FORMS = (0x341, 0x343)     # mepc, mtval: all forms, read-backs equal
CSR_READ_ONLY = (0x340,)          # mscratch: csrr read only (handler scratch)
CSR_WRITE_ONLY = (0x342,)         # mcause: rd=x0 writes only (WARL read-back)
CSR_LOWBITS = (0x300,)            # mstatus: rd=x0 csrrsi/csrrci (bits 0-4)

# static rd/rs1 contract exclusions; per-seed handler/boot registers are
# parsed dynamically from the asm (pygen randomizes them per seed)
INJECT_EXCLUDE_STATIC = frozenset((1, 2, 3, 4, 10, 27, 29))

RE_INSTR_DST = re.compile(r"^\s*(?:\d+:)?\s*[a-z][a-z0-9.]*\s+([A-Za-z0-9]+)")
RE_STACK_LA = re.compile(r"^\s*(?:\d+:)?\s*la\s+([A-Za-z0-9]+)\s*,\s*\S*stack",
                         re.IGNORECASE)
ABI_REG_NUMS = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
                "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
                "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14,
                "a5": 15, "a6": 16, "a7": 17, "s2": 18, "s3": 19,
                "s4": 20, "s5": 21, "s6": 22, "s7": 23, "s8": 24,
                "s9": 25, "s10": 26, "s11": 27, "t3": 28, "t4": 29,
                "t5": 30, "t6": 31}


def _reg_num(tok):
    tok = tok.strip().rstrip(",")
    m = re.fullmatch(r"x(\d{1,2})", tok)
    if m:
        n = int(m.group(1))
        return n if n <= 31 else None
    return ABI_REG_NUMS.get(tok)


def collect_stack_base_regs(lines):
    """Destinations of `la xR, <...stack...>` (the kernel/user stack base
    registers - randomized per seed by pygen, read by the trap handler
    before being written; the injection must not clobber them)."""
    regs = set()
    for line in lines:
        m = RE_STACK_LA.match(line)
        if m:
            n = _reg_num(m.group(1))
            if n is not None:
                regs.add(n)
    return regs


def make_csr_insn(rng, pool):
    """One random CSR instruction safe for SCR1-vs-Spike lockstep."""
    rd = rng.choice(pool)
    r = rng.random()
    if r < 0.50:
        # mepc/mtval: every form (read-backs architecturally identical)
        csr = rng.choice(CSR_RW_FORMS)
        form = rng.randrange(7)
        if form == 0:
            return "csrrw {}, {:#x}, {}".format(rd, csr, rng.choice(pool))
        if form == 1:
            return "csrrs {}, {:#x}, {}".format(rd, csr, rng.choice(pool))
        if form == 2:
            return "csrrc {}, {:#x}, {}".format(rd, csr, rng.choice(pool))
        if form == 3:
            return "csrrwi {}, {:#x}, {}".format(rd, csr, rng.randrange(32))
        if form == 4:
            return "csrrsi {}, {:#x}, {}".format(rd, csr, rng.randrange(32))
        if form == 5:
            return "csrrci {}, {:#x}, {}".format(rd, csr, rng.randrange(32))
        return "csrr {}, {:#x}".format(rd, csr)
    if r < 0.65:
        # mscratch: read only (handler swap scratch - writes buy nothing)
        return "csrr {}, {:#x}".format(rd, CSR_READ_ONLY[0])
    if r < 0.80:
        # mcause: write-only (WARL EC truncation diverges on read-back)
        csr = CSR_WRITE_ONLY[0]
        if rng.random() < 0.5:
            return "csrrw x0, {:#x}, {}".format(csr, rng.choice(pool))
        return "csrrwi x0, {:#x}, {}".format(csr, rng.randrange(32))
    # mstatus: set/clear bits 0-4 with rd=x0 (MPP bits [12:11] untouched -
    # Spike honors MPP at mret, SCR1 hardwires 11)
    op = rng.choice(("csrrsi", "csrrci"))
    return "{} x0, {:#x}, {}".format(op, CSR_LOWBITS[0], rng.randrange(32))


def inject_csr(out, count, seed):
    """Insert `count` random CSR instructions into the body region
    (between the `main:` and `test_done:` labels), after instruction-like
    lines (indented, never labels/directives). Deterministic per seed.
    `out` is mutated; returns the number of inserted instructions."""
    if count <= 0:
        return 0
    # flatten multi-line blobs (epilogue/exit_vec are appended as single
    # strings) so every element is one line
    flat = []
    for chunk in out:
        if "\n" in chunk[:-1]:
            flat.extend(chunk.splitlines(keepends=True))
        else:
            flat.append(chunk)
    out.clear()
    out.extend(flat)

    start = end = None
    for i, line in enumerate(out):
        if start is None and RE_MAIN.match(line):
            start = i
        elif start is not None and RE_TEST_DONE.match(line):
            end = i
            break
    if start is None or end is None:
        print("WARNING: main:/test_done: not found - CSR injection skipped",
              file=sys.stderr)
        return 0

    forbidden = INJECT_EXCLUDE_STATIC | collect_stack_base_regs(out)
    pool = tuple("x{}".format(i) for i in range(5, 32) if i not in forbidden)
    if len(pool) < 8:
        print("WARNING: injection register pool too small ({}) - skipped"
              .format(len(pool)), file=sys.stderr)
        return 0

    slots = [i for i in range(start + 1, end) if RE_BODY_INSTR.match(out[i])]
    if not slots:
        return 0
    rng = random.Random(seed ^ 0xC5BA0)
    picks = sorted(rng.choice(slots) for _ in range(count))
    inserted = 0
    for pos in reversed(picks):  # back to front: earlier indexes stay valid
        out.insert(pos + 1,
                   "                  {}  # csr-inject\n".format(make_csr_insn(rng, pool)))
        inserted += 1
    return inserted


def patch(src_lines, stack_max):
    out = []
    in_tohost = False
    patched_exit = False
    rept_capped = 0
    aligned_mtvec = False
    for line in src_lines:
        if line.startswith("write_tohost:"):
            in_tohost = True
            out.append(EPILOGUE)
            patched_exit = True
            continue
        if in_tohost:
            # skip the original block up to (excluding) instr_end:
            if line.startswith("instr_end:"):
                in_tohost = False
                out.append(line)
            continue
        # SCR1 truncates mtvec.BASE[5:0]: the trap table must be 64B aligned
        if RE_MTVEC_HANDLER.match(line):
            out.append(".balign 64\n")
            aligned_mtvec = True
        m = RE_REPT.match(line)
        if m and int(m.group(2)) > stack_max:
            out.append(f"{m.group(1)}{stack_max}{m.group(3)}\n")
            rept_capped += 1
            continue
        out.append(line)
    # endless legal spin at 0xF8 (.exit_vec section, link.ld)
    out.append(EXIT_VEC)
    return out, patched_exit, rept_capped, aligned_mtvec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--stack-max", type=int, default=1000)
    ap.add_argument("--csr-inject", type=int, default=0)
    ap.add_argument("--csr-seed", type=int, default=0)
    args = ap.parse_args()

    with open(args.inp) as f:
        src = f.readlines()
    out, patched_exit, rept_capped, aligned_mtvec = patch(src, args.stack_max)
    if not patched_exit:
        print("ERROR: write_tohost: label not found - exit not patched",
              file=sys.stderr)
        sys.exit(2)
    if not aligned_mtvec:
        print("WARNING: mtvec_handler label not found - alignment not applied",
              file=sys.stderr)
    csr_inserted = inject_csr(out, args.csr_inject, args.csr_seed)
    if args.csr_inject > 0 and csr_inserted == 0:
        print("ERROR: CSR injection requested but nothing inserted",
              file=sys.stderr)
        sys.exit(2)
    with open(args.out, "w") as f:
        f.writelines(out)
    print(f"patched: exit epilogue -> 0xF8/a0, .rept capped to "
          f"{args.stack_max} ({rept_capped} section(s)), mtvec_handler "
          f"balign64={aligned_mtvec}, csr injected={csr_inserted}: {args.out}")


if __name__ == "__main__":
    main()
