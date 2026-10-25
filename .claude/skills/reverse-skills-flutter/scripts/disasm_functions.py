#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
disasm_functions.py — full capstone disassembly of the .text section; build a
function table (via Dart AOT prologue signature) and a BL call graph.

Outputs:
  functions.txt    — one function start address per line
  bl_targets.txt   — <target_hex> <call_count>  (hot callees = libraries/showDialog)
  bl_calls.txt     — <from_hex> <to_hex>         (caller→callee edges)
  summary          — printed to stdout

Requires capstone. Install: python3 -m pip install capstone

Usage:
    python3 disasm_functions.py <libapp.so|apk> [--start 0xADDR] [--end 0xADDR]
    python3 disasm_functions.py <libapp.so|apk> --func 0xADDR   # disasm one function
"""
import sys, os, argparse, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk

PROLOGUE = dk.PATCH_PROLOGUE  # fd79bfa9 fd030faa (stp x29,x30,[x15,#-16]! ; mov x29,x15)
# Alternate Dart prologue using SP: stp x29,x30,[sp,#-N]!  → word & 0xFFC00000-ish; we detect via capstone below.


def scan_functions(data, start, end):
    """Find Dart function entries by the prologue byte signature (backward-safe)."""
    funcs = []
    i = start
    while i + 8 <= end:
        if data[i:i + 8] == PROLOGUE:
            funcs.append(i)
            i += 8
            continue
        i += 4
    return funcs


def func_of(addr, funcs):
    """Largest func start <= addr."""
    import bisect
    if not funcs: return None
    i = bisect.bisect_right(funcs, addr) - 1
    return funcs[i] if i >= 0 else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--start", default=None, help="hex .text start (default: auto from symbols)")
    ap.add_argument("--end", default=None)
    ap.add_argument("--func", default=None, help="disassemble a single function at this hex addr")
    ap.add_argument("--len", type=lambda x: int(x, 0), default=0x800, help="bytes to show with --func")
    args = ap.parse_args()

    if not dk.has_capstone():
        dk.warn_no_capstone(); sys.exit(2)
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

    data, src = dk.load_libapp(args.target)
    syms = dk.dart_symbols(data)
    tr = dk.text_range(syms)
    start = int(args.start, 0) if args.start else (tr[0] if tr else 0x460000)
    end = int(args.end, 0) if args.end else (tr[1] if tr else len(data))

    if args.func:
        f = int(args.func, 0)
        md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = False
        for ins in md.disasm(data[f:f + args.len], f):
            print("0x%07x  %08x  %s  %s" % (ins.address, ins.id and 0 or 0, ins.mnemonic, ins.op_str))
        return

    print("# disassembling 0x%x..0x%x (%d bytes) — this may take a moment" % (start, end, end - start), file=sys.stderr)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = False

    funcs = scan_functions(data, start, end)
    bl_targets = {}
    bl_calls = []
    insn_count = 0
    for ins in md.disasm(data[start:end], start):
        insn_count += 1
        if ins.mnemonic == "bl":
            try:
                tgt = int(ins.op_str.lstrip("#"), 16)
            except ValueError:
                continue
            bl_targets[tgt] = bl_targets.get(tgt, 0) + 1
            bl_calls.append((ins.address, tgt))

    with open("functions.txt", "w") as f:
        for a in funcs: f.write("0x%x\n" % a)
    with open("bl_targets.txt", "w") as f:
        for tgt, c in sorted(bl_targets.items(), key=lambda x: -x[1]):
            f.write("0x%x\t%d\n" % (tgt, c))
    with open("bl_calls.txt", "w") as f:
        for frm, to in bl_calls:
            f.write("0x%x\t0x%x\n" % (frm, to))

    print("functions found   : %d" % len(funcs))
    print("instructions      : %d" % insn_count)
    print("BL call sites     : %d" % len(bl_calls))
    print("distinct BL tgts  : %d" % len(bl_targets))
    print("\nTop 15 hottest BL targets (often: showDialog helpers, allocators, libraries):")
    for tgt, c in sorted(bl_targets.items(), key=lambda x: -x[1])[:15]:
        print("  0x%07x  called %d times" % (tgt, c))
    print("\nWrote: functions.txt, bl_targets.txt, bl_calls.txt")
    print("Next: function_triage.py to rank functions by feature vector.")


if __name__ == "__main__":
    main()
