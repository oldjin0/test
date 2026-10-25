#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
function_triage.py — rank Dart AOT functions by a per-function feature vector to
triage which function does what, WITHOUT symbol names.

For each function (boundaries from the Dart prologue signature), count:
  pool_loads  — LDR ..,[x27,#..]   (X27 = pool base)   → how many constants it uses
  bl_count    — outgoing calls
  cond_branches — b.eq/cbz/tbz/…    (decision points)
  cmps        — cmp                 (comparisons)
  insn_count  — size proxy

Then rank:
  HIGH cmp + cond_branches  → "aggregation predicate" / integrity-gate candidate
  HIGH pool_loads + bl      → orchestrator
  HIGH bl + few branches    → leaf dispatcher

Requires capstone. Outputs function_triage.txt sorted by an aggregator score.

Usage:
    python3 function_triage.py <libapp.so|apk> [--top 50]
    python3 function_triage.py <libapp.so|apk> --keyword "vip,广告,签到" [--strings unflutter_strings.txt]
"""
import sys, os, argparse, bisect, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk

PROLOGUE = dk.PATCH_PROLOGUE
COND_BRANCH = {"b.eq","b.ne","b.gt","b.lt","b.ge","b.le","b.cs","b.cc","b.hi","b.ls",
               "b.mi","b.pl","b.vs","b.vc","cbz","cbnz","tbz","tbnz"}


def scan_function_starts(data, start, end):
    funcs = []
    i = start
    while i + 8 <= end:
        if data[i:i + 8] == PROLOGUE:
            funcs.append(i); i += 8; continue
        i += 4
    return funcs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--keyword", default="", help="comma-sep keywords; rank functions whose pool-strings match")
    ap.add_argument("--strings", default="", help="string table: lines 'ref<TAB>string' or '[ref=N] string'")
    ap.add_argument("--pool", default="pool_deserialized.json")
    args = ap.parse_args()

    if not dk.has_capstone():
        dk.warn_no_capstone(); sys.exit(2)
    from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

    data, src = dk.load_libapp(args.target)
    syms = dk.dart_symbols(data)
    tr = dk.text_range(syms)
    start = tr[0] if tr else 0x460000
    end = tr[1] if tr else len(data)

    funcs = scan_function_starts(data, start, end)
    # function end = next prologue (or end)
    bounds = []
    for i, fs in enumerate(funcs):
        fe = funcs[i + 1] if i + 1 < len(funcs) else end
        bounds.append((fs, fe))

    # keyword mode: which functions load matching strings?
    kws = [k.strip() for k in args.keyword.split(",") if k.strip()] if args.keyword else []
    off2kw = {}   # pool_offset -> set(keywords)
    if kws and os.path.exists(args.pool):
        import json
        pj = json.load(open(args.pool))
        # need a string table: parse --strings into ref->string
        ref2str = {}
        if args.strings and os.path.exists(args.strings):
            for line in open(args.strings, encoding="utf8", errors="replace"):
                line = line.rstrip("\n")
                m = re.search(r"\[ref=(\d+)\]", line) or re.match(r"^(\d+)\t(.+)", line)
                if m:
                    ref2str[int(m.group(1))] = line
        for e in pj.get("entries", []):
            if e["type"] == 0 and e["val"] is not None:
                s = ref2str.get(e["val"], "")
                hits = {kw for kw in kws if kw and kw in s}
                if hits:
                    off2kw.setdefault(e["idx"] * 8, set()).update(hits)

    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM); md.detail = False
    results = []
    for fs, fe in bounds:
        pool_loads = bl_count = cond = cmps = 0
        kw_hits = 0
        for ins in md.disasm(data[fs:fe], fs):
            m = ins.mnemonic
            if m == "ldr" and "[x27" in ins.op_str:
                pool_loads += 1
                # crude keyword match on the offset if in keyword mode
            elif m == "bl":
                bl_count += 1
            elif m in COND_BRANCH:
                cond += 1
            elif m == "cmp":
                cmps += 1
        n = (fe - fs) // 4
        agg_score = (cmps * 3) + cond  # integrity-gate / aggregator heuristic
        results.append((fs, fe, pool_loads, bl_count, cond, cmps, n, agg_score, kw_hits))

    if kws:
        results.sort(key=lambda r: -r[8])
        print("# ranked by keyword hits (functions loading strings containing: %s)" % ", ".join(kws))
        print("func_start  kw_hits  pool_loads  bl   cond  cmp  insns")
        for r in results[:args.top]:
            if r[8] == 0: break
            print("0x%07x   %5d    %5d      %4d  %4d  %4d  %6d" % (r[0], r[8], r[2], r[3], r[4], r[5], r[6]))
    else:
        results.sort(key=lambda r: -r[7])
        print("# ranked by aggregator score (cmp*3 + cond_branches) — integrity-gate candidates first")
        print("func_start  score  pool_loads  bl   cond  cmp  insns")
        for r in results[:args.top]:
            print("0x%07x   %5d  %5d      %4d  %4d  %4d  %6d" % (r[0], r[7], r[2], r[3], r[4], r[5], r[6]))

    print("\nTip: HIGH cmp+cond = aggregation predicate (integrity gate).")
    print("     Cross-reference a candidate's pool loads with pool_by_ref.txt to see which")
    print("     strings/check-methods it references.")


if __name__ == "__main__":
    main()
