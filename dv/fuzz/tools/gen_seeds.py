#!/usr/bin/env python3
"""gen_seeds.py — random seed list for the SCR1 fuzz regression.

Usage: gen_seeds.py <count> [--seed-file PATH] [--max-bits N]
Prints the seeds to stdout (one per line) and, when --seed-file is
given, writes them there. Pattern: riscv-core-dv-uvm scripts/gen_seeds.py.
"""
import argparse
import random


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("count", type=int)
    ap.add_argument("--seed-file", default=None)
    ap.add_argument("--max-bits", type=int, default=31)
    args = ap.parse_args()

    seeds = [random.getrandbits(args.max_bits) for _ in range(args.count)]
    text = "\n".join(str(s) for s in seeds) + "\n"
    if args.seed_file:
        with open(args.seed_file, "w") as f:
            f.write(text)
    print(text, end="")


if __name__ == "__main__":
    main()
