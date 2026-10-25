#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze_apk.py — entry point for analyzing a Flutter/Dart-AOT libapp.so.

Usage:
    python3 analyze_apk.py <path/to/libapp.so | path/to/app.apk> [libflutter.so|app.apk]

Prints: ELF symbol layout, snapshot magic + features (version hints), Dart version
(from libflutter if given), the .text business-code range, a string census, and the
recommended next steps. Pure detection — does not modify anything.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _dartkit as dk


def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    libapp_path = sys.argv[1]
    lf_path = sys.argv[2] if len(sys.argv) > 2 else (
        libapp_path if libapp_path.lower().endswith((".apk", ".zip")) else None)

    data, src = dk.load_libapp(libapp_path)
    print("=" * 64)
    print("reverse-skills — analyze_apk")
    print("=" * 64)
    print("libapp.so source : %s" % src)
    print("libapp.so size   : %d bytes (%.1f MB)" % (len(data), len(data) / 1048576))

    # --- ELF symbols ---
    print("\n--- ELF dynamic symbols (_kDart*) ---")
    syms = dk.dart_symbols(data)
    if not syms:
        print("  (no _kDart* symbols found — is this really a Flutter libapp.so?)")
    for name in sorted(syms):
        v, sz = syms[name]
        print("  %-42s vaddr=0x%-8x size=0x%x" % (name, v, sz))

    iso_data = syms.get("_kDartIsolateSnapshotData")
    vm_data = syms.get("_kDartVmSnapshotData")
    tr = dk.text_range(syms)

    # --- file_offset == vaddr check ---
    print("\n--- offset sanity ---")
    if tr:
        # crude check: text bytes should look like ARM64 code (not all zeros/0xff)
        sample = data[tr[0]:tr[0] + 16]
        print("  .text range      : 0x%x .. 0x%x (%d bytes)" % (tr[0], tr[1], tr[1] - tr[0]))
        print("  .text first 16 B : %s" % sample.hex())
        print("  NOTE: verify file_offset == vaddr for THIS binary before trusting any offset.")
        print("        (For many Flutter builds they are equal; confirm via readelf -S vs symbols.)")

    # --- snapshot magic + features ---
    print("\n--- Dart snapshot header ---")
    probe_at = None
    if vm_data: probe_at = vm_data[0]
    elif iso_data: probe_at = iso_data[0]
    if probe_at is not None:
        info = dk.probe_snapshot(data, probe_at)
        if info:
            print("  magic found at   : 0x%x (0xf5f5dcdc)" % info["magic_off"])
            feats = info["features"]
            print("  features string  : %s" % (feats[:200] + ("…" if len(feats) > 200 else "")))
            hints = dk.features_to_version_hints(feats)
            if hints:
                print("  version hints    :")
                for h in hints: print("    - %s" % h)
        else:
            print("  (snapshot magic not found near 0x%x)" % probe_at)

    # --- Dart version from libflutter ---
    if lf_path:
        lf = dk.load_libflutter(lf_path)
        if lf:
            ver = dk.detect_dart_version(lf)
            print("\n--- libflutter.so version probe ---")
            if ver and ver["version"]:
                print("  Dart version     : %s" % ver["version"])
            else:
                print("  Dart version     : (not found via strings grep)")
            if ver and ver["snapshot_hashes"]:
                print("  snapshot hashes  : %s" % ", ".join(ver["snapshot_hashes"][:2]))

    # --- string census ---
    print("\n--- object-pool / string census ---")
    if iso_data:
        start, end = iso_data[0], iso_data[0] + iso_data[1]
        n8 = dk.count_printable_runs(data, start, end, 4)
        print("  isolate data     : 0x%x .. 0x%x" % (start, end))
        print("  ASCII runs (>=4) : %d  (rough string count; CJK is UTF-16LE, not counted here)" % n8)
    else:
        print("  (no isolate data symbol — skipping)")

    # --- next steps ---
    feats_now = ""
    if probe_at is not None:
        p = dk.probe_snapshot(data, probe_at)
        if p: feats_now = p.get("features", "")
    custom = "arm64-sysv" in feats_now
    print("\n--- recommended next steps ---")
    print("  1. If blutter can build for this engine → run it; use its pp.txt + asm/.")
    if custom:
        print("     ⚠ custom engine detected (arm64-sysv) — blutter likely FAILS. Manual path:")
        print("        deserialize_pool.py → pool_xref.py → function_triage.py")
    else:
        print("     Manual path if blutter fails: find_strings.py → deserialize_pool.py")
        print("                                      → pool_xref.py → function_triage.py")
    print("  2. Patch: patch_libapp.py ; verify on device: verify_bytes.py")
    print("  3. PRE-FLIGHT: is the APK packed? (libjiagu/StubApp) — references/05-packers.md")
    print("\nFull docs: references/ .  Skill router: SKILL.md")


if __name__ == "__main__":
    main()
