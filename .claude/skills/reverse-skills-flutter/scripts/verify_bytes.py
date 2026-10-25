#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_bytes.py — verify that patches actually landed inside an installed APK's
libapp.so. Reads the libapp straight out of the APK via zipfile (no unpacking).

This closes the loop after: apktool b → sign → install. install -r with an
UNCHANGED versionCode does NOT replace libapp.so — always verify on device.

Usage:
    python3 verify_bytes.py <app.apk|installed.apk> <offset:hexbytes> [<offset:hexbytes> ...]
    python3 verify_bytes.py <apk> 0x8e1dd0:e00316aac0035fd6 0xbc1058:1f2003d5

    # pull the installed APK first:
    #   adb shell pm path com.example.app   → package:/data/app/.../base.apk
    #   adb pull <that path> installed.apk
"""
import sys, os, argparse, zipfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk


def main():
    ap = argparse.ArgumentParser(description="Verify patch bytes inside an APK's libapp.so.")
    ap.add_argument("apk")
    ap.add_argument("checks", nargs="+", help="offset:hexbytes  (offset hex with 0x)")
    args = ap.parse_args()

    data, src = dk.load_libapp(args.apk)
    print("# libapp from: %s (%d bytes)" % (src, len(data)))

    all_ok = True
    for chk in args.checks:
        off_s, hexb = chk.split(":")
        off = int(off_s, 0)
        b = bytes.fromhex(hexb)
        got = data[off:off + len(b)].hex()
        ok = (got == hexb)
        if not ok: all_ok = False
        print("  0x%07x  expect %s  got %s  %s" % (off, hexb, got, "OK" if ok else "** MISMATCH **"))

    if all_ok:
        print("\n✓ all patch bytes verified.")
    else:
        print("\n✗ MISMATCH — did you bump versionCode and reinstall? See references/02 §7.")
        sys.exit(1)


if __name__ == "__main__":
    main()
