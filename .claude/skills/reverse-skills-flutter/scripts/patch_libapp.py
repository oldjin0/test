#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_libapp.py — apply binary patches to a Dart AOT libapp.so with safe
primitives and a reproducible config system.

Always patches from a PRISTINE original; prints old->new for every byte change.

Primitives (the reusable ARM64 Dart-AOT patch toolkit):
  entry-null   <hex>     make a function return null (verified prologue first)
  return-null  <hex>     8-byte `mov x0,x22 ; ret` at an offset (no epilogue restore)
  nop          <hex>     NOP one instruction (1f2003d5) — for disabling a BL
  set          <hex>:<hexbytes>  write arbitrary bytes

Usage:
    # CLI primitives
    python3 patch_libapp.py orig.so out.so \\
        --entry-null 0x8e1dd0 --entry-null 0x8ef2b8 \\
        --nop 0xbc1058 --nop 0xbc1134

    # JSON spec (reproducible configs; see below)
    python3 patch_libapp.py orig.so out.so --spec patches.json

patches.json format:
    {"patches": [
        {"op": "entry-null", "offset": "0x8e1dd0"},
        {"op": "nop", "offset": "0xbc1058"},
        {"op": "set", "offset": "0x466e28", "bytes": "c0820091"},
        {"op": "return-null", "offset": "0x920d90"}
    ]}

See references/02-arm64-patching.md for WHEN each primitive is safe and the
prologue-verification rules.
"""
import sys, os, json, argparse, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk


def verify_entry_patchable(data, addr):
    """Check the standard Dart prologue (stp x29,x30,[x15,#-16]!; mov x29,x15)
    is present at addr, and find the first conditional branch in +0x8..+0x44.
    Returns (ok, patch_offset). entry-null is safest applied at the first
    conditional branch (frame still balanced there)."""
    if data[addr:addr + 8] != dk.PATCH_PROLOGUE:
        return False, None
    for o in range(0x8, 0x44, 4):
        w = struct.unpack_from("<I", data, addr + o)[0]
        if (w & 0xFF000000) == 0x54000000:  # conditional branch (b.cond)
            return True, addr + o
    # fall back: patch at entry+8 (still inside prologue, usually safe)
    return True, addr + 8


def apply(data, patches, verbose=True):
    for p in patches:
        off = int(p["offset"], 0) if isinstance(p["offset"], str) else p["offset"]
        op = p["op"]
        if op == "entry-null":
            ok, target = verify_entry_patchable(data, off)
            if not ok:
                print("  ⚠ 0x%x: prologue mismatch — entry-null may be unsafe (skipping)" % off)
                continue
            b = dk.PATCH_ENTRY_NULL
            old = data[target:target + len(b)].hex()
            data[target:target + len(b)] = b
            if verbose: print("  0x%07x entry-null @+0x%x: %s -> %s" % (off, target - off, old, b.hex()))
        elif op == "return-null":
            b = dk.PATCH_RETURN_NULL
            old = data[off:off + len(b)].hex()
            data[off:off + len(b)] = b
            if verbose: print("  0x%07x return-null: %s -> %s" % (off, old, b.hex()))
        elif op == "nop":
            b = dk.PATCH_NOP
            old = data[off:off + 4].hex()
            data[off:off + 4] = b
            if verbose: print("  0x%07x nop: %s -> %s" % (off, old, b.hex()))
        elif op == "set":
            b = bytes.fromhex(p["bytes"])
            old = data[off:off + len(b)].hex()
            data[off:off + len(b)] = b
            if verbose: print("  0x%07x set: %s -> %s" % (off, old, b.hex()))
        else:
            print("  ⚠ unknown op '%s' at 0x%x (skipping)" % (op, off))


def main():
    ap = argparse.ArgumentParser(description="Patch a Dart AOT libapp.so with safe primitives.")
    ap.add_argument("orig", help="original libapp.so")
    ap.add_argument("out", help="output .so path")
    ap.add_argument("--spec", help="JSON patch spec")
    ap.add_argument("--entry-null", action="append", default=[], help="hex offset (repeatable)")
    ap.add_argument("--nop", action="append", default=[], help="hex offset (repeatable)")
    ap.add_argument("--return-null", action="append", default=[], help="hex offset (repeatable)")
    ap.add_argument("--set", action="append", default=[], help="hexoffset:hexbytes (repeatable)")
    args = ap.parse_args()

    data = bytearray(open(args.orig, "rb").read())
    patches = []
    if args.spec:
        patches.extend(json.load(open(args.spec))["patches"])
    for o in args.entry_null: patches.append({"op": "entry-null", "offset": o})
    for o in args.nop: patches.append({"op": "nop", "offset": o})
    for o in args.return_null: patches.append({"op": "return-null", "offset": o})
    for s in args.set:
        off, b = s.split(":")
        patches.append({"op": "set", "offset": off, "bytes": b})

    if not patches:
        ap.error("no patches given; use --spec or --entry-null/--nop/--set")

    print("applying %d patches from original (%d bytes)…" % (len(patches), len(data)))
    apply(data, patches)
    open(args.out, "wb").write(data)
    print("wrote %s (%d bytes)" % (args.out, len(data)))
    print("\nNext: repack (apktool b, bump versionCode!), sign, install, then verify_bytes.py.")


if __name__ == "__main__":
    main()
