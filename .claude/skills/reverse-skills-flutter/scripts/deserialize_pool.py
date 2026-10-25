#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
deserialize_pool.py — generic Dart (2.x, arm64, compressed-pointers) object-pool
deserializer for libapp.so.

The Dart AOT object pool is an array of tagged entries indexed by X27.
Every `LDR Xn,[X27,#off]` loads pool entry off/8. Recovering the
`ref → slot_index → byte_offset` map is the highest-leverage static-analysis step
when blutter fails on a custom engine.

Entry format (stable across Dart 2.x compressed-pointer builds; from Dart's
object_pool_layout.h / app_snapshot.cc ObjectPoolDeserializationCluster::ReadFill):
  - fill region starts with a VLE `length`
  - each entry = 1 raw byte: TypeBits = eb & 0x7f, PatchableBit = 0x80
    * type 0 (kTaggedObject): VLE ref follows
    * type 1 (kImmediate)   : VLE value follows   ← NOT fixed-width (common gotcha)
    * type 2/3/4            : no payload
  - slot byte_offset = slot_index × 8

This script AUTO-LOCATES the pool fill region by scanning the isolate snapshot
data for a plausible VLE length followed by a stream of entry-type bytes, then
emits pool_deserialized.json. Provide --anchors to validate (ref -> expected slot).

Usage:
    python3 deserialize_pool.py <libapp.so|apk> [--out pool.json]
    python3 deserialize_pool.py <libapp.so|apk> --anchors 26842:0x15b1,27673:0x278d

NOTE: auto-location is heuristic. If anchors fail, narrow the search with
--scan-start / --scan-end (hex offsets inside the isolate data region).
"""
import sys, os, json, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk


def deserialize_from(data, fill_start, max_entries=200000):
    """Try to deserialize `length` entries starting at fill_start. Returns list or None."""
    try:
        length, pos = dk.read_vle_unsigned(data, fill_start)
    except Exception:
        return None
    if length <= 0 or length > max_entries:
        return None
    entries = []
    p = pos
    try:
        for idx in range(length):
            eb_off = p
            eb = data[p]; p += 1
            etype = eb & 0x7f
            val = None
            if etype == 0:
                val, p = dk.read_vle_unsigned(data, p)
            elif etype == 1:
                val, p = dk.read_vle_unsigned(data, p)
            elif etype in (2, 3, 4):
                pass
            else:
                return None  # unknown type → wrong location
            entries.append({"idx": idx, "type": etype, "val": val, "eb": eb, "off": eb_off})
    except IndexError:
        return None
    return entries


def auto_locate_and_deserialize(data, region_start, region_end):
    """Scan the isolate data region for a plausible pool fill start."""
    best = None
    # Heuristic: a fill start is where read_vle gives a large-but-sane length, and the
    # following bytes decode cleanly as entries. Step in 1-byte increments over a window.
    # To keep it fast, sample candidate starts where the byte looks like a VLE length.
    for start in range(region_start, min(region_start + 0x400000, region_end)):
        if start & 0x1fff and data[start] <= 0x7f:
            continue  # skip unlikely starts occasionally to keep runtime bounded
        entries = deserialize_from(data, start)
        if entries and 1000 < len(entries) < 200000:
            # sanity: fraction of type-0 entries should be substantial
            t0 = sum(1 for e in entries if e["type"] == 0)
            if t0 > len(entries) * 0.1:
                if best is None or len(entries) > len(best[1]):
                    best = (start, entries)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--out", default="pool_deserialized.json")
    ap.add_argument("--anchors", default="", help="ref:slot,ref:slot  to validate")
    ap.add_argument("--scan-start", default=None, help="hex; restrict auto-locate start")
    ap.add_argument("--scan-end", default=None)
    args = ap.parse_args()

    data, src = dk.load_libapp(args.target)
    syms = dk.dart_symbols(data)
    iso = syms.get("_kDartIsolateSnapshotData")
    if not iso:
        print("no _kDartIsolateSnapshotData symbol — cannot locate pool region"); sys.exit(1)
    rstart = iso[0]
    rend = iso[0] + iso[1]
    if args.scan_start: rstart = max(rstart, int(args.scan_start, 0))
    if args.scan_end: rend = min(rend, int(args.scan_end, 0))

    print("# scanning isolate data 0x%x..0x%x for pool fill start…" % (rstart, rend), file=sys.stderr)
    found = auto_locate_and_deserialize(data, rstart, rend)
    if not found:
        print("auto-locate failed. Try --scan-start near the pool (often ~mid isolate data),")
        print("or supply known anchors and a narrow scan window."); sys.exit(2)
    fill_start, entries = found
    print("# fill_start = 0x%x  entries = %d" % (fill_start, len(entries)))

    by_ref = {}
    for e in entries:
        if e["type"] == 0 and e["val"] is not None:
            by_ref.setdefault(e["val"], e["idx"])

    # validate anchors
    if args.anchors:
        ok = True
        for pair in args.anchors.split(","):
            ref, slot = pair.split(":")
            ref = int(ref); slot = int(slot, 0)
            got = by_ref.get(ref)
            status = "OK" if got == slot else "** MISMATCH **"
            if got != slot: ok = False
            print("  anchor ref %d -> slot 0x%x : got %s  %s" % (ref, slot, (hex(got) if got is not None else None), status))
        print("# anchors: %s" % ("all OK" if ok else "MISMATCH — fill_start may be wrong"))

    out = {"fill_start": fill_start, "length": len(entries),
           "by_ref": {str(k): v for k, v in by_ref.items()},
           "entries": entries}
    with open(args.out, "w") as f:
        json.dump(out, f)
    print("wrote %s  (%d entries, %d distinct refs)" % (args.out, len(entries), len(by_ref)))
    print("Next: pool_xref.py to map each ref's slot to the .text PCs that load it.")


if __name__ == "__main__":
    main()
