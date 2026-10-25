#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pool_xref.py — build the object-pool slot → .text PC → function cross-reference
for a Flutter libapp.so, using RAW BYTE PATTERN scanning (no capstone needed).

Dart AOT pool-access idioms (X27 = pool base):
  (1) ADD xRd, x27, #page, LSL #12   ; then LDR xD,[xRd,#off]   → offset = (page<<12)+off
  (2) direct LDR xD, [x27, #off]      (page==0)                 → offset = off
  slot_index = offset / 8

For each pool offset hit, record (pc, func_start). func_start is found by
backwards-scanning for the Dart prologue signature (fd79bfa9 fd030faa).

Inputs: libapp.so, and optionally pool_deserialized.json (from deserialize_pool.py)
        to map slot→ref so the output can be joined with strings.
Output: pool_xref.txt   "pool_offset<TAB>pc<TAB>func_start"
        pool_by_ref.txt "ref<TAB>pool_offset<TAB>num_loaders<TAB>func_starts..."

Usage:
    python3 pool_xref.py <libapp.so|apk> [--pool pool_deserialized.json]
"""
import sys, os, json, struct, argparse, bisect
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk

PROLOGUE = dk.PATCH_PROLOGUE


def scan_function_starts(data, start, end):
    funcs = []
    i = start
    while i + 8 <= end:
        if data[i:i + 8] == PROLOGUE:
            funcs.append(i); i += 8; continue
        i += 4
    return funcs


def func_of(addr, funcs):
    if not funcs: return None
    i = bisect.bisect_right(funcs, addr) - 1
    return funcs[i] if i >= 0 else None


def scan_pool_accesses(data, start, end):
    """Yield (pc, pool_offset) for ADD+LDR and direct-LDR pool accesses."""
    a = start
    n = len(data)
    while a + 8 <= end:
        w1 = struct.unpack_from("<I", data, a)[0]
        # ADD (imm64): opcode bits 0x91000000, with shift bit (22) and Rn field
        if (w1 & 0xFF800000) == 0x91000000:
            sh = (w1 >> 22) & 1
            imm12 = (w1 >> 10) & 0xFFF
            Rn = (w1 >> 5) & 0x1F
            Rd = w1 & 0x1F
            if Rn == dk.REG_POOL and sh == 1:
                page = imm12 << 12
                # look ahead up to 5 insns for LDR xD,[xRd,#off]
                for k in range(1, 6):
                    if a + 4 * k + 4 > n: break
                    w2 = struct.unpack_from("<I", data, a + 4 * k)[0]
                    if (w2 & 0xFFC00000) == 0xF9400000:  # LDR (imm, 64-bit)
                        imm12b = (w2 >> 10) & 0xFFF
                        Rn2 = (w2 >> 5) & 0x1F
                        if Rn2 == Rd:
                            off = imm12b << 3
                            yield (a + 4 * k, page + off)
                            break
        # direct LDR xD,[x27,#off]
        elif (w1 & 0xFFC00000) == 0xF9400000:
            imm12b = (w1 >> 10) & 0xFFF
            Rn = (w1 >> 5) & 0x1F
            if Rn == dk.REG_POOL:
                yield (a, imm12b << 3)
        a += 4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--pool", default="pool_deserialized.json", help="from deserialize_pool.py (optional)")
    args = ap.parse_args()

    data, src = dk.load_libapp(args.target)
    syms = dk.dart_symbols(data)
    tr = dk.text_range(syms)
    start = tr[0] if tr else 0x460000
    end = tr[1] if tr else len(data)
    print("# scanning .text 0x%x..0x%x for pool accesses…" % (start, end), file=sys.stderr)

    funcs = scan_function_starts(data, start, end)
    print("# %d function starts found" % len(funcs), file=sys.stderr)

    by_offset = {}   # offset -> [(pc, func)]
    npc = 0
    for pc, off in scan_pool_accesses(data, start, end):
        f = func_of(pc, funcs)
        by_offset.setdefault(off, []).append((pc, f))
        npc += 1
    print("# %d pool-access instructions" % npc, file=sys.stderr)

    # load pool map if present (offset -> ref)
    off2ref = {}
    if os.path.exists(args.pool):
        pj = json.load(open(args.pool))
        for e in pj.get("entries", []):
            if e["type"] == 0 and e["val"] is not None:
                off2ref[e["idx"] * 8] = e["val"]
        print("# joined with %s (%d refs)" % (args.pool, len(off2ref)), file=sys.stderr)

    with open("pool_xref.txt", "w") as f:
        for off in sorted(by_offset):
            for pc, fn in by_offset[off]:
                f.write("0x%x\t0x%x\t%s\n" % (off, pc, ("0x%x" % fn) if fn else "-"))

    with open("pool_by_ref.txt", "w") as f:
        for off, hits in sorted(by_offset.items()):
            funcs_hit = sorted({("0x%x" % fn) if fn else "-" for _, fn in hits})
            ref = off2ref.get(off)
            f.write("%s\t0x%x\t%d\t%s\n" % (ref if ref is not None else "-", off, len(hits), ",".join(funcs_hit)))

    print("wrote pool_xref.txt (per-instruction) and pool_by_ref.txt (per-ref summary)")
    print("\nStrings loaded by EXACTLY ONE function are feature-dedicated — dead giveaway")
    print("for a feature's UI builder. Cross with a string table to find them.")


if __name__ == "__main__":
    main()
