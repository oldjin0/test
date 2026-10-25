# 01 — Flutter / Dart AOT Static Analysis

> The foundational layer: how to turn a stripped `libapp.so` (Dart AOT machine code)
> into something you can read and search. **This is the layer to spend the most time on**
> — almost every Flutter-RE question is answered here.
>
> Run `scripts/analyze_apk.py` first to get your bearings; this doc explains what it
> found and how to go deeper.

## Table of contents
1. The 4-symbol ELF map
2. blutter (primary tool) — setup, run, fallbacks
3. Custom-engine failure mode (when blutter dies)
4. Dart string encoding (UTF-8 vs UTF-16LE)
5. The object pool & the VLE/slot → `.text` xref bridge
6. Platform channels (Java ↔ Dart)
7. The anti-tamper "expected values" pattern
8. The 5-step investigation loop

---

## 1. The 4-symbol ELF map (memorize this)

Every Flutter `libapp.so` exports 4 dynamic symbols. This map is the foundation of every offset:

| Symbol | Role |
|---|---|
| `_kDartVmSnapshotData` | VM snapshot data (small, ~KB): header + features |
| `_kDartIsolateSnapshotData` | **Isolate data = the object pool / strings / class metadata** ← main analysis target |
| `_kDartVmSnapshotInstructions` | VM stub code |
| `_kDartIsolateSnapshotInstructions` | **Business machine code = `.text`** ← disassembly target |

```bash
# Confirm with the skill's tool (auto-detects, no deps):
python3 scripts/analyze_apk.py path/to/libapp.so
```

**Verify `file_offset == vaddr`** for each symbol on YOUR binary before trusting any
offset read elsewhere. For many Flutter builds they are equal (no PIE, no per-section
alignment padding). The ppcat build had this property; not all do.

**Snapshot magic + features:** at the start of `_kDartVmSnapshotData` you'll find the
raw bytes `f5 f5 dc dc` (the Dart snapshot magic `0xf5f5dcdc`, stored byte-wise — **not**
little-endian u32). Followed by count fields, `kind` (u32 = 3 = kFullAOT), a 32-byte
hash, then a NUL-terminated ASCII **features** string. Decode the features for version hints:

| Feature flag | Meaning |
|---|---|
| `no-null-safety` | Dart **2.x** (3.0+ forces null safety) |
| `compressed-pointers` | ≥ 2.15 |
| `use_bare_instructions` | ≥ 2.16 |
| `dedup_instructions` / `no-lazy_dispatchers` | ≥ 2.17 |
| `lazy_async_stacks` / `dwarf_stack_traces_mode` | ≥ 2.18 |
| `arm64-sysv` (instead of `arm64 android`) | **CUSTOM engine** — blutter will likely fail |

## 2. blutter (primary tool)

[blutter](https://github.com/worawit/blutter) is the strongest Dart-AOT tool: disassembles
into symbol-annotated assembly and dumps the full object pool. Linux only, C++20.

```bash
# Environment (Ubuntu 24.04 / Debian 13 ship a new-enough gcc)
sudo apt install -y build-essential git cmake ninja-build pkg-config \
    python3 python3-pip libicu-dev libcapstone-dev gcc-13 g++-13 clang-16 clang++-16
python3 -m pip install pyelftools requests

git clone https://github.com/worawit/blutter.git && cd blutter
git submodule update --init --recursive
# blutter.py takes a DIRECTORY containing both libapp.so + libflutter.so
python3 blutter.py ../lib/arm64-v8a ../out_arm64
```

First run: detects Dart version from `libflutter.so` → clones & compiles the Dart SDK
runtime (10–40 min) → disassembles. **Outputs** (`out_arm64/`):

| Output | Value |
|---|---|
| `pp.txt` | ★ Object-pool dump — every Dart object (strings/constants/class+method names). **The single most useful artifact.** |
| `objs.txt` | Nested object dump |
| `asm/*.S` | Symbol-annotated disassembly, one file per function |
| `blutter_frida.js` | Frida hook template |

## 3. Custom-engine failure mode (when blutter dies)

blutter hard-asserts the target engine matches an **official** Dart SDK release. Real apps
(especially with custom `libflutter.so`) violate this. Three recurring failure points
(patches documented in the source campaign under `analysis_workdir/blutter_patches/`):

1. **`SnapshotHeaderReader::VerifyFeatures`** (`app_snapshot.cc`) — the custom features string
   matches no official build. Patch: still call `ReadFeatures` (to advance the stream cursor
   — **critical**, else later reads desync) but skip the comparison.
2. **`ImageReader::VerifyAlignment`** (`image_snapshot.cc`) — snapshot data not 64-byte aligned
   (`kObjectStartAlignment`). Patch: `return ApiError::null();`.
3. **Base-object count off-by-one** (`Deserializer::Deserialize`) — custom VM's class table
   differs. Convert the `FATAL` to a warning.

**But even with all 3 patches, blutter often still dies at `No cluster defined for cid N`** —
the custom VM's class-ID table is structurally rearranged. **This is unfixable at the header
level.** Symptom: zero output / empty `pp.txt`.

**The lesson:** for a custom engine, **blutter is dead**. Don't waste rounds re-patching it.
Fall back to the manual path: unflutter (for the VM structure + ref→string table) + capstone
disassembly + the manual VLE/slot bridge below. The skill's `scripts/` implement this path.

## 4. Dart string encoding

Dart snapshots store strings two ways:

| Encoding | CID | Stores | How to find |
|---|---|---|---|
| **OneByteString** | 85 | Latin-1 / UTF-8 bytes | plain `grep` / `strings` |
| **TwoByteString** | 86 | **UTF-16LE** | UTF-16LE byte search (CJK!) |

**Chinese / CJK / emoji are TwoByteString.** Plain `strings libapp.so` will NOT find them.

```bash
python3 scripts/find_strings.py libapp.so "应用已被非法篡改"   # auto-searches both
python3 scripts/find_strings.py libapp.so --dump-utf16 > cjk.txt
```

**Proximity heuristic:** in the object pool, a function's `Code` comment and the strings it
loads sit **adjacent**. Use pool adjacency to guess string↔function ownership when no
symbols exist.

## 5. The object pool & the VLE/slot → `.text` xref bridge

The Dart AOT object pool is an array of tagged entries; **X27 holds its base**; every
`LDR Xn,[X27,#off]` loads entry `off/8`. Recovering `ref → slot → string → accessor-function`
is the highest-leverage analysis step. Recipe:

1. **Recover the string list** (`ref → string`): from blutter's `pp.txt`, or unflutter's
   `strings.txt` (`[ref=N] (1b/2b) "..."`), or `scripts/find_strings.py --dump-utf16`.
   Refs start at 1 (`kFirstReference`).
2. **Deserialize the pool** (`ref → slot → byte_offset`): `scripts/deserialize_pool.py`.
   Format (Dart 2.x compressed pointers): fill region starts with a VLE `length`; each entry
   = 1 byte (`TypeBits = eb & 0x7f`, `PatchableBit = 0x80`); type 0 (kTaggedObject) → VLE ref;
   **type 1 (kImmediate) → VLE value (NOT fixed-width — common gotcha)**; types 2/3/4 → no
   payload. `slot_offset = idx × 8`. Validate with 2–4 anchors before trusting.
3. **Build the pool→`.text` xref**: `scripts/pool_xref.py` scans for both idioms
   (`ADD xR,x27,#page,LSL#12; LDR xD,[xR,#off]` and direct `LDR xD,[x27,#off]`) and maps each
   to its function. **Strings loaded by exactly ONE function are feature-dedicated** — a dead
   giveaway for a feature's UI builder.
4. **Join**: for any string of interest → ref → slot → all PCs → functions.

**Unsigned VLE encoding** (refs in pool fill data; 7 data bits/byte, high bit SET = last byte):
```
5 → 0x85 ; 25 → 0x99 ; 27673 → 19 58 81  (= 25 | 11264<<7 ... )
```

## 6. Platform channels (Java ↔ Dart)

Flutter plugins bridge Dart ↔ Java via `MethodChannel` (name conventionally
`plugins.flutter.io/<name>` or custom). Dart calls `invokeMethod("foo")`; a Java handler
dispatches on the method name. **The method-name strings are Dart-side pool strings** — so
you can reconstruct the entire channel API by grepping the pool.

A typical anti-tamper app collects environment info via a channel and aggregates it:
`getAll getAppInfo getApplication getPMProxy getMaps getClassLoader …` → a function reads
several of these, compares to hardcoded baselines, and branches to `showDialog`.

**How to recognize the aggregation function in asm:** one function referencing **many**
method-name strings + comparisons/boolean ops + ending in conditional branch → dialog.
`scripts/function_triage.py` ranks functions by `cmp*3 + cond_branches` to surface these.

## 7. The anti-tamper "expected values" pattern

Many Flutter anti-tamper checks compare **runtime-detected values against hardcoded baseline
strings** in the pool — any mismatch trips the alarm. Recognize the pattern: a pool full of
Android framework classnames / packer names / marker strings string-compared against channel
results. Examples (these are app-specific — recognize the *pattern*):

- expected `ApplicationInfo.className` (e.g. a packer stub class like `com.stub.StubApp`)
- packer lib names (`libjiagu*`), emulator/xposed markers
- the app's own Application class & its superclass
- a hardcoded signature fingerprint

The original app doesn't trip because its detected values happen to match the baselines.

## 8. The 5-step investigation loop

```
1. dump the object pool (pp.txt / unflutter / find_strings --dump-utf16)
2. grep key strings (CJK as UTF-16LE, English as UTF-8); record offset+encoding+count
3. map string → pool slot → .text PC  (deserialize_pool.py → pool_xref.py)
4. locate function + aggregator + dialog/branch  (function_triage.py + BL walk-up)
5. record exact patch target: vaddr + file offset + machine-code bytes
```

> ⚠️ **Callers = 0 is normal for Dart `build`/virtual methods** — invoked via **cid virtual
> dispatch** (`blr` through a table at the dispatch stub), not `BL`. Static xref will *never*
> find these. Use dynamic backtrace. See [03-frida-dynamic.md](03-frida-dynamic.md) §3.
