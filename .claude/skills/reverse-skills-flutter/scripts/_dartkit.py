#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_dartkit.py — shared helpers for the reverse-skills scripts.
Generic, dependency-light utilities for analyzing a Flutter/Dart-AOT libapp.so.

No third-party deps required for the core (ELF parse, VLE, snapshot probe).
capstone / pyelftools are used opportunistically when present.
"""
import struct, re, sys, zipfile, io

# Make console output robust on Windows (GBK/cp936) and other non-UTF-8 terminals,
# so emoji/special glyphs (⚠ → ✓) never crash a print. Applied once at import.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ---------- Dart AOT ABI constants (arm64) ----------
# These are the register roles for arm64 Dart AOT. Re-verify per binary, but
# this is the overwhelming default for Dart 2.x compressed-pointer builds.
REG_POOL = 27          # X27 = object-pool pointer (PP)
REG_NULL = 22          # X22 = null sentinel
REG_THREAD = 26        # X26 = Thread
REG_SHADOW_SP = 15     # X15 = shadow-call-stack pointer
REG_HEAPBASE = 28      # X28 = heap base (compressed pointers)

# Dart canonical bools: pointers derived from the null/heap base.
#   True  = null_base + 0x30   (low half ...8071 on ppcat)
#   False = null_base + 0x20   (low half ...8061 on ppcat)
BOOL_TRUE_OFF = 0x30
BOOL_FALSE_OFF = 0x20

# Patch primitives (little-endian ARM64 instruction words)
PATCH_RETURN_NULL = bytes.fromhex("e00316aac0035fd6")  # mov x0,x22 ; ret
PATCH_ENTRY_NULL = bytes.fromhex(
    "e00316aa"   # mov  x0, x22        (null)
    "ef031daa"   # mov  x15, x29
    "fd79c1a8"   # ldp  x29, x30, [x15], #0x10
    "c0035fd6"   # ret
)
PATCH_NOP = bytes.fromhex("1f2003d5")  # nop
PATCH_PROLOGUE = bytes.fromhex("fd79bfa9fd030faa")  # stp x29,x30,[x15,#-16]! ; mov x29,x15

DART_SNAPSHOT_MAGIC = 0xf5f5dcdc  # kMagic in vm/app_snapshot.cc
# The magic is stored as the raw byte sequence f5 f5 dc dc (NOT little-endian u32),
# so compare bytes directly. Read as LE u32 it would be 0xdcdcf5f5 — a common trap.
DART_SNAPSHOT_MAGIC_BYTES = bytes.fromhex("f5f5dcdc")

# ---------- low-level readers ----------
def u8(d, o):  return d[o]
def u16(d, o): return struct.unpack_from("<H", d, o)[0]
def u32(d, o): return struct.unpack_from("<I", d, o)[0]
def u64(d, o): return struct.unpack_from("<Q", d, o)[0]

def read_vle_unsigned(d, pos):
    """Dart ReadUnsigned (7 data bits/byte; high bit SET = last byte).
    Returns (value, new_pos)."""
    r = 0; sh = 0
    while True:
        b = d[pos]; pos += 1
        if b > 0x7f:
            r |= (b - 0x80) << sh
            return r, pos
        r |= b << sh; sh += 7

def write_vle_unsigned(value):
    out = bytearray()
    while True:
        b = value & 0x7f
        if value < 0x80:
            out.append(b | 0x80); return bytes(out)
        out.append(b); value >>= 7

# ---------- APK / file loading ----------
def load_libapp(path):
    """Return (libapp_bytes, source_desc). Accepts a libapp.so OR an apk (extracts
    lib/arm64-v8a/libapp.so, falling back to armeabi-v7a)."""
    if path.lower().endswith((".apk", ".zip", ".apks", ".xapk")):
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            for cand in ("lib/arm64-v8a/libapp.so",):
                if cand in names:
                    return z.read(cand), cand + " (from " + path + ")"
            # fall back: any libapp.so
            for cand in names:
                if cand.endswith("/libapp.so"):
                    return z.read(cand), cand + " (from " + path + ")"
        raise SystemExit("no libapp.so found inside " + path)
    return open(path, "rb").read(), path

def load_libflutter(path):
    """If path is an apk, extract libflutter.so; else read directly. Returns bytes or None."""
    if path.lower().endswith((".apk", ".zip", ".apks", ".xapk")):
        with zipfile.ZipFile(path) as z:
            for cand in ("lib/arm64-v8a/libflutter.so",):
                if cand in z.namelist():
                    return z.read(cand)
            for cand in z.namelist():
                if cand.endswith("/libflutter.so"):
                    return z.read(cand)
        return None
    return open(path, "rb").read()

# ---------- Minimal ELF64 dynamic-symbol parser (no deps) ----------
def elf64_dynamic_symbols(data):
    """Parse an ELF64 little-endian file and return {name: (st_value, st_size)} for
    dynamic symbols. Works for the standard _kDart* exports of libapp.so."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[4] != 2: raise ValueError("not ELF64")
    if data[5] != 1: raise ValueError("not little-endian")
    e_shoff = u64(data, 0x28)
    e_shentsize = u16(data, 0x3a)
    e_shnum = u16(data, 0x3c)
    if not e_shoff or not e_shnum: return {}
    syms = {}
    for i in range(e_shnum):
        sh = e_shoff + i * e_shentsize
        sh_type = u32(data, sh + 4)
        sh_offset = u64(data, sh + 24)
        sh_size = u64(data, sh + 32)
        sh_link = u32(data, sh + 40)
        sh_entsize = u64(data, sh + 56)
        if sh_type != 11:  # SHT_DYNSYM
            continue
        # linked strtab section
        str_sh = e_shoff + sh_link * e_shentsize
        str_offset = u64(data, str_sh + 24)
        n = sh_size // (sh_entsize or 24)
        for s in range(n):
            so = sh_offset + s * (sh_entsize or 24)
            st_name = u32(data, so)
            st_value = u64(data, so + 8)
            st_size = u64(data, so + 16)
            if st_name == 0 or st_value == 0:
                continue
            end = data.index(b"\x00", str_offset + st_name)
            name = data[str_offset + st_name:end].decode("latin1")
            syms[name] = (st_value, st_size)
    return syms

def dart_symbols(data):
    """Return the 4 _kDart* symbols that matter: {name:(vaddr,size)}."""
    allsyms = elf64_dynamic_symbols(data)
    return {k: v for k, v in allsyms.items() if "_kDart" in k}

def text_range(dart_syms):
    """Business machine code range. Prefer _kDartIsolateSnapshotInstructions;
    fall back to _kDartVmSnapshotInstructions..+size."""
    iso = dart_syms.get("_kDartIsolateSnapshotInstructions")
    if iso:
        return iso[0], iso[0] + iso[1]
    vm = dart_syms.get("_kDartVmSnapshotInstructions")
    if vm:
        return vm[0], vm[0] + vm[1]
    return None

# ---------- snapshot header probe ----------
def probe_snapshot(data, data_vaddr):
    """Look for the Dart snapshot magic near data_vaddr and extract the features
    string (carries version/ABI hints). Returns dict or None.

    Layout (Dart app_snapshot): magic(4B raw f5f5dcdc) + length/count fields +
    kind(u32, =3 kFullAOT) + 32-byte hash + NUL-terminated features ASCII string.
    """
    window = data[data_vaddr:data_vaddr + 0x600]
    # magic may be at the very start (vm/isolate) or a few bytes in
    for off in range(0, min(len(window) - 4, 0x40)):
        if window[off:off + 4] == DART_SNAPSHOT_MAGIC_BYTES:
            kind = u32(window, off + 0x0c) if off + 0x10 < len(window) else None
            features = ""
            # features string sits after the 32-byte hash; scan a region for a long ASCII run
            scan = window[off + 0x14:off + 0x600]
            m = re.search(rb"[ -~]{20,}", scan)
            if m: features = m.group().decode("latin1", "replace")
            return {"magic_off": data_vaddr + off, "kind": kind, "features": features}
    return None

def features_to_version_hints(features):
    """Heuristic: map snapshot feature flags to a Dart version floor."""
    hints = []
    if not features: return hints
    if "no-null-safety" in features: hints.append("Dart 2.x (no-null-safety)")
    if "compressed-pointers" in features: hints.append(">= 2.15 compressed-pointers")
    if "use_bare_instructions" in features: hints.append(">= 2.16 bare-instructions")
    if "dedup_instructions" in features or "no-lazy_dispatchers" in features: hints.append(">= 2.17")
    if "dwarf_stack_traces_mode" in features or "lazy_async_stacks" in features: hints.append(">= 2.18")
    if "arm64-sysv" in features: hints.append("CUSTOM engine (arm64-sysv) — blutter may FAIL")
    if "arm64" in features and "arm64-sysv" not in features: hints.append("standard arm64 android")
    return hints

def detect_dart_version(libflutter_bytes):
    """Grep libflutter.so for a Dart version string and snapshot hashes."""
    if not libflutter_bytes: return None
    m = re.search(rb"[Dd]art[^0-9]{0,8}([0-9]+\.[0-9]+\.[0-9]+)", libflutter_bytes)
    ver = m.group(1).decode() if m else None
    hashes = re.findall(rb"[0-9a-f]{40}", libflutter_bytes)[:4]
    return {"version": ver, "snapshot_hashes": [h.decode() for h in hashes]}

# ---------- string scanning ----------
def find_utf8(data, needle, base=0):
    nb = needle.encode("utf-8")
    return [base + m.start() for m in re.finditer(re.escape(nb), data)]

def find_utf16le(data, needle, base=0):
    nb = needle.encode("utf-16-le")
    return [base + m.start() for m in re.finditer(re.escape(nb), data)]

def count_printable_runs(data, region_start, region_end, minlen=4):
    """Count ASCII runs in a region (rough object-pool string census)."""
    region = data[region_start:region_end]
    return len(re.findall(rb"[\x20-\x7e]{%d,}" % minlen, region))

def has_capstone():
    try:
        import capstone  # noqa
        return True
    except ImportError:
        return False

def warn_no_capstone():
    sys.stderr.write(
        "[!] capstone not installed — disassembly features disabled.\n"
        "    Fix: python3 -m pip install capstone\n")
