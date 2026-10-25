# reverse-skills — scripts

Generic, portable Python tools for analyzing and patching a Flutter/Dart-AOT
`libapp.so`. Each script takes a `libapp.so` (or a whole `.apk`) path and
auto-detects what it can. Optional deps (`capstone`, `pyelftools`) degrade
gracefully — the core detection needs only the Python standard library.

> Install recommended deps once: `python3 -m pip install capstone pyelftools`

## Data-flow pipeline

```
                       ┌──────────────────┐
   libapp.so / .apk →  │ analyze_apk.py   │  detect symbols, snapshot magic/version, .text
                       └────────┬─────────┘
                                │
            ┌───────────────────┼─────────────────────┐
            ▼                   ▼                     ▼
   find_strings.py    deserialize_pool.py    disasm_functions.py
   (UTF-8/UTF-16LE)   (ref → slot map)       (function table + call graph)
            │                   │                     │
            │                   ▼                     │
            │           pool_xref.py  ←───────────────┘
            │           (slot → PC → function)
            │                   │
            └──────► function_triage.py
                      (rank by feature vector; find gates/aggregators)
                                │
                                ▼
                       patch_libapp.py   (entry-null / nop / branch / return-null)
                                │
                                ▼
                       verify_bytes.py   (byte-check patches inside the installed APK)
```

## Per-script usage

### `analyze_apk.py` — the entry point
```bash
python3 analyze_apk.py path/to/libapp.so
python3 analyze_apk.py path/to/app.apk app.apk   # 2nd arg = same apk for libflutter version probe
```
Prints ELF symbol layout, snapshot magic + feature flags (Dart version hints),
`.text` range, string census, and recommended next steps.

### `find_strings.py` — locate a string (both encodings)
```bash
python3 find_strings.py libapp.so "应用已被非法篡改"   # CJK → UTF-16LE
python3 find_strings.py libapp.so "isVip" --all       # ASCII → UTF-8, +context
python3 find_strings.py libapp.so --dump-utf16 > cjk_strings.txt
```
**Critical:** Dart CJK strings are TwoByteString (UTF-16LE) — plain `strings`/grep
will NOT find them.

### `disasm_functions.py` — capstone disasm + call graph
```bash
python3 disasm_functions.py libapp.so                 # full .text → functions/bl_targets/bl_calls
python3 disasm_functions.py libapp.so --func 0x8e1dd0 # disasm one function
```
Writes `functions.txt`, `bl_targets.txt` (hot callees = showDialog/allocators),
`bl_calls.txt` (caller→callee edges). Requires `capstone`.

### `deserialize_pool.py` — object-pool deserializer (when blutter fails)
```bash
python3 deserialize_pool.py libapp.so --out pool.json
python3 deserialize_pool.py libapp.so --anchors 26842:0x15b1,27673:0x278d
```
Auto-locates the pool fill region and decodes entries (VLE + entry-type table).
Validates with anchors. **The highest-leverage artifact** when blutter can't run.

### `pool_xref.py` — pool slot → PC → function
```bash
python3 pool_xref.py libapp.so --pool pool.json
```
Raw byte-pattern scan (no capstone). Strings loaded by exactly ONE function =
feature-dedicated builders. Joins with `pool.json` to give ref→loaders.

### `function_triage.py` — rank functions by feature vector
```bash
python3 function_triage.py libapp.so --top 50          # aggregator-score ranking
python3 function_triage.py libapp.so --keyword "vip,签到" --strings strings.txt --pool pool.json
```
HIGH cmp+cond_branches = integrity-gate / aggregation-predicate candidate.

### `patch_libapp.py` — apply patches with safe primitives
```bash
python3 patch_libapp.py libapp_orig.so libapp_patched.so \
    --entry-null 0x8e1dd0 --entry-null 0x8ef2b8 \
    --nop 0xbc1058 --set 0x466e28:c0820091

# or a reproducible JSON spec:
python3 patch_libapp.py libapp_orig.so libapp_patched.so --spec patches.json
```
`entry-null` verifies the Dart prologue before patching. Always patch from a
pristine original. See `references/02-arm64-patching.md`.

### `verify_bytes.py` — confirm patches survived repack/install
```bash
python3 verify_bytes.py installed.apk 0x8e1dd0:e00316aac0035fd6 0xbc1058:1f2003d5
```
Reads libapp straight out of the APK. Run AFTER `adb pull`-ing the installed APK.
Catches the classic "same versionCode → libapp not replaced" trap.

## Notes

- All offsets are **file offsets**. For many Flutter builds file_offset == vaddr, but
  **always confirm** (`analyze_apk.py` flags this) before trusting offsets you read
  elsewhere.
- The pool deserializer's auto-locate is heuristic. If anchors mismatch, narrow the
  scan window with `--scan-start`/`--scan-end` around the real fill region.
- These tools are detection/analysis only. They never phone home.
