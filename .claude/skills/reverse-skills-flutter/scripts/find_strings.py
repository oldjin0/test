#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
find_strings.py — find a string in libapp.so in BOTH encodings.

Dart snapshots store strings two ways:
  - OneByteString (cid 85): Latin-1 / UTF-8 bytes  → plain grep finds it
  - TwoByteString (cid 86): UTF-16LE (2 bytes/char) → invisible to plain `strings`

Chinese / CJK / emoji are TwoByteString. Always search UTF-16LE for non-ASCII.

Usage:
    python3 find_strings.py <libapp.so|apk> "needle" [--all]
    python3 find_strings.py <libapp.so|apk> --dump-utf16 > strings_utf16.txt

With --all, also dumps a short context around each hit. With --dump-utf16,
extracts ALL UTF-16LE CJK runs (offset<TAB>string) — useful as a coarse pool dump.
"""
import sys, os, re, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk


def main():
    ap = argparse.ArgumentParser(description="Find strings in a Flutter libapp.so (UTF-8 + UTF-16LE).")
    ap.add_argument("target", help="libapp.so or .apk path")
    ap.add_argument("needle", nargs="?", help="string to search for (omit with --dump-utf16)")
    ap.add_argument("--all", action="store_true", help="show context around each hit")
    ap.add_argument("--dump-utf16", action="store_true", help="dump all CJK UTF-16LE runs and exit")
    args = ap.parse_args()

    data, src = dk.load_libapp(args.target)
    print("# source: %s (%d bytes)" % (src, len(data)), file=sys.stderr)

    if args.dump_utf16:
        # CJK + common punctuation ranges (BMP): high byte 0x4E-0x9F, 0x30-0x4D(punct/kana)
        pat = re.compile(rb"(?:[\x00-\xff][\x30-\x9f]){2,}")
        for m in pat.finditer(data):
            off = m.start()
            try:
                s = m.group().decode("utf-16-le")
            except Exception:
                continue
            if len(s) >= 2 and any("　" <= c <= "鿿" or "＀" <= c <= "￯" for c in s):
                print("0x%07x\t%s" % (off, s))
        return

    if not args.needle:
        ap.error("needle required (or use --dump-utf16)")

    needle = args.needle
    u8 = dk.find_utf8(data, needle)
    u16 = dk.find_utf16le(data, needle)
    print('needle: "%s"' % needle)
    print("  UTF-8   hits: %d  %s" % (len(u8), [hex(x) for x in u8[:8]] + (["..."] if len(u8) > 8 else [])))
    print("  UTF-16LE hits: %d  %s" % (len(u16), [hex(x) for x in u16[:8]] + (["..."] if len(u16) > 8 else [])))

    if args.all:
        for enc, hits in (("UTF-8", u8), ("UTF-16LE", u16)):
            for h in hits:
                lo, hi = max(0, h - 16), min(len(data), h + len(needle.encode("utf-16-le")) + 16)
                print("  [%s] 0x%07x  ctx=%s" % (enc, h, data[lo:hi].hex()))


if __name__ == "__main__":
    main()
