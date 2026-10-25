---
name: reverse-skills
description: Reverse-engineer Android APKs, especially Flutter/Dart AOT apps. Guides static analysis (blutter, object-pool deserialization, capstone disasm), ARM64 libapp.so binary patching, Frida dynamic instrumentation, signature/integrity-bypass, packer (360 jiagu) handling, and test-environment choice. Use when the user wants to analyze, decompile, patch, debug, recover code from, or study an APK — keywords like apk, android app, flutter, dart, libapp.so, libflutter.so, blutter, frida, adb, smali, dex, 逆向, 反编译, 加固, 脱壳, or "how does this app work". Includes ready-to-run Python scripts and reusable playbooks distilled from a real multi-branch campaign.
license: MIT
compatibility: Requires Python 3.9+; optional but recommended: capstone, pyelftools (pip), and standard Android RE tools (apktool, jadx, frida, adb). Scripts degrade gracefully when optional deps are missing. Designed for Claude Code; works in any Agent-Skills-compatible client.
metadata:
  author: inliver233
  version: "1.0.0"
  source_project: ppcat (Flutter/Dart 2.19 AOT reverse-engineering campaign, 173 commits, 5 branches)
allowed-tools: Read Grep Glob Bash(python3 *) Bash(python *) Bash(pip3 *) Bash(adb *) Bash(unzip *) Bash(zipinfo *)
---

# reverse-skills — APK (Flutter/Dart AOT) Reverse Engineering

A battle-tested methodology toolkit for reverse-engineering Android APKs, with deep
specialization in **Flutter / Dart AOT** apps (`libapp.so` + `libflutter.so`). Distilled
from a 173-commit, 5-branch, multi-model campaign that targeted a custom-engine,
360-jiagu-packed Flutter app. Every technique here was paid for in real dead-ends —
learn from them.

## When to use this skill

Activate when the user is working with an **APK** or its internals and wants to:
understand how it works, recover/decompile code, find specific logic (a dialog trigger,
an ad gate, a VIP check, a network call), patch behavior, instrument it dynamically,
remove packer protection, or choose a test environment. Triggers include `apk`,
`flutter`, `dart`, `libapp.so`, `libflutter.so`, `blutter`, `frida`, `smali`, `dex`,
逆向/反编译/加固/脱壳.

## The mental model (read first)

A Flutter APK is **layered**. Pick the right layer before doing anything:

| Layer | File | Logic lives here | Primary tool |
|---|---|---|---|
| Dart business logic | `lib/<abi>/libapp.so` | Dart AOT machine code + **object pool** (strings, constants, class/method refs) | blutter / capstone / custom pool dumper |
| Flutter engine | `lib/<abi>/libflutter.so` | Runtime; carries the **Dart version** | `strings` version probe |
| Java/Kotlin shim | `classes*.dex` → smali | App entry, plugin registration, platform-channel handlers, ad SDKs | apktool / jadx |
| App shell/packer | `libjiagu*.so`, `com.stub.StubApp` | Encrypted DEX loaded at runtime | detect BEFORE repacking |

**First diagnostic question for any "Flutter-rendered" symptom:** is the logic in Dart
(`libapp.so`) or Java (`dex`)? Flutter UI shows up in `uiautomator dump` as
`content-desc`, not native `text=`. Don't hunt Dart logic in smali.

## The master decision tree

```
1. PRE-FLIGHT (always, 2 minutes — saves days)
   ├─ Is the APK PACKED?  (libjiagu*/libshell*/StubApp/single huge classes.dex)
   │   YES → read references/05-packers.md  ⚠ apktool-repack will BLACK-SCREEN it
   │   NO  → normal apktool d / patch / apktool b path is safe
   └─ What engine?  strings libflutter.so | grep dart-version  → references/01

2. STATIC ANALYSIS (do this first, always)
   ├─ Dump the Dart object pool + strings  → references/01 + scripts/
   ├─ Map string refs → pool slots → .text instruction PCs  → references/01 §6
   └─ Locate the target logic (dialog/ad/VIP/URL)  → references/08 (state-chain triage)

3. PATCH or DYNAMIC? (depends on the goal)
   ├─ Goal = understand / find logic    → static analysis (references/01, 08)
   ├─ Goal = change behavior on device  → ARM64 patching (references/02) + scripts/patch_libapp.py
   └─ Goal = find cid-dispatched callers / live-validate a hypothesis
        → Frida dynamic (references/03)  ⚠ needs NATIVE ARM (references/06)

4. BYPASS PROTECTIONS as needed
   ├─ Signature/integrity dialog        → references/04
   ├─ Packer (jiagu)                    → references/05
   └─ Anti-tamper / ad UI               → references/07
```

## The 5-step investigation loop (the heart of the method)

For any feature you want to locate/defeat in `libapp.so`:

1. **Dump the object pool** (`pp.txt`/`unflutter_strings.txt`) — grep it first. This is your
   symbol table. → `scripts/analyze_apk.py`, `scripts/deserialize_pool.py`
2. **Grep key strings** — Chinese/CJK as **UTF-16LE**, English as UTF-8. Record offset +
   encoding + count. → `scripts/find_strings.py`
3. **Map string → pool slot → `.text` PC** via the ADD/LDR pool-access pattern
   (`x27` = pool base, `slot_offset = idx × 8`). → `scripts/pool_xref.py`
4. **Locate the function + aggregator + dialog/branch** — walk BL callers up to the
   orchestrator; find the conditional branch that decides. → `scripts/function_triage.py`
5. **Record the exact patch target** — `vaddr` + `file offset` + the few machine-code
   bytes at the decision. → `scripts/patch_libapp.py`, `scripts/verify_bytes.py`

> ⚠️ **Callers = 0 is normal for Dart `build`/virtual methods** — they're invoked via
> **cid virtual dispatch** (`blr` through a table), not `BL`. Static xref will *never*
> find these. Use dynamic backtrace instead. See references/03 §3.

## The one rule that prevents most failures

> **Before acting on any analysis result, name the precondition it assumes and verify
> it holds for THIS target.** A function looked single-purpose but was shared; a value
> looked like a widget but was a string; `0` looked like `false` but was an illegal tag;
> a 0-xref looked dead but was cid-dispatched; an emulator looked like success but was
> packer-lenient. The full catalog: [references/09-pitfalls.md](references/09-pitfalls.md).

## Quick patches (ARM64 Dart AOT primitives)

| Intent | Bytes | Notes |
|---|---|---|
| Kill a function → return null | `e00316aa ef031daa fd79c1a8 c0035fd6` | `mov x0,x22(null); mov x15,x29; ldp x29,x30,[x15],#0x10; ret`. Verify prologue first. |
| NOP a `showDialog` BL | `1f2003d5` | Only if balanced STP/pop around it & x0 overwritten. |
| Force a branch / skip block | `xx000014` (`0x14000000\|imm26`) | Boolean gate / path selection. |
| Materialize Dart **False** | `add xR,x22,#0x20` → `c0820091` | **Never** `movz w0,#0` (→ SIGILL). True = `+0x30`. |

Dart AOT ABI: `x15`=shadow-stack, `x26`=Thread, `x27`=**Pool(PP)**, `x22`=**null**,
`x28`=heap base; pool `slot_offset = idx × 8`. See references/02.

## Reference library (load on demand — do not read all at once)

- [01-flutter-dart-aot.md](references/01-flutter-dart-aot.md) — blutter setup, ELF layout, Dart-version detection, object-pool deserialization, string encoding, pool→.text xref bridge, platform channels
- [02-arm64-patching.md](references/02-arm64-patching.md) — entry-null / SizedBox / NOP / branch-flip patterns, prologue verification, scan-slot, patch-config system, repack+sign workflow
- [03-frida-dynamic.md](references/03-frida-dynamic.md) — why houdini kills frida, redroid ARM-native setup, ABI cheatsheet, cid wall, backtrace, Stalker, MemoryAccessMonitor, Dart bool format, runtime flip, guard→patch
- [04-signature-integrity.md](references/04-signature-integrity.md) — the signature-check chain, PmsHook, Android-14 fix, runtime spoof, LSPatch, decision tree
- [05-packers.md](references/05-packers.md) — how 360 jiagu works, why apktool-repack black-screens, the 3 correct delivery paths, early detection
- [06-environments.md](references/06-environments.md) — LDPlayer vs redroid vs physical ARM: capability table + decision tree + redroid docker command
- [07-ui-dialogs-ads.md](references/07-ui-dialogs-ads.md) — 3-source dialog triage (showDialog / uncaught-exception / integrity-gate), aggregation hunting, SharedPreferences keys, safe-NOP envelope, ad removal
- [08-state-analysis.md](references/08-state-analysis.md) — business-logic state-chain tracing, ~21k-function triage by feature vector, cross-validation, the round-report structure + template
- [09-pitfalls.md](references/09-pitfalls.md) — the full dead-end catalog: shared-guard white-screen, stack-reload, movz#0, SizedBox-slot, versionCode, emulator false-positive, cid84/blutter, and the meta "wrong weapon for the runtime" trap
- [10-collaboration.md](references/10-collaboration.md) — controller→analyst topology, handoff/task-dispatch templates, **neutral phrasing for safe multi-model collaboration**, cross-branch reconciliation
- [tool-catalog.md](references/tool-catalog.md) — every tool + install command + when-to-use, plus the MCP servers (jshook, chrome-devtools, context7, sequential-thinking)

## Scripts (run them; don't read them)

All scripts are **generic** — pass your `libapp.so` or `.apk` path. They auto-detect what
they can and degrade gracefully when optional deps (`capstone`, `pyelftools`) are missing.

| Script | Purpose |
|---|---|
| `scripts/analyze_apk.py <apk_or_libapp>` | Entry point: detect ELF symbols, snapshot magic/version, .text range, dump strings |
| `scripts/find_strings.py <libapp.so> "needle"` | Find a string (UTF-8 + UTF-16LE) with all offsets |
| `scripts/disasm_functions.py <libapp.so>` | Full capstone disasm → function table (prologue scan) + BL call graph |
| `scripts/deserialize_pool.py <libapp.so>` | Generic Dart object-pool deserializer (VLE + entry-type table), auto-locate fill region |
| `scripts/pool_xref.py <libapp.so>` | Build pool-slot → PC → function cross-reference |
| `scripts/function_triage.py <libapp.so>` | Rank functions by feature vector (pool-loads, BL, branches, cmps) — find aggregators/gates |
| `scripts/patch_libapp.py <orig.so> <out.so> <config>` | Apply named patch configs with entry-null/NOP/branch-flip primitives |
| `scripts/verify_bytes.py <apk> <offset:hex>...` | Byte-verify patches inside an installed APK's libapp |

```bash
# Setup (one time)
python3 -m pip install capstone pyelftools   # optional but recommended
# Typical first run
python3 ${CLAUDE_SKILL_DIR}/scripts/analyze_apk.py path/to/libapp.so
```

See `scripts/README.md` for per-script usage and the data-flow between them.

## Asset templates (copy into the target project)

- [assets/handoff-template.md](assets/handoff-template.md) — cold-start a new agent/session on a long RE task
- [assets/task-dispatch-template.md](assets/task-dispatch-template.md) — dispatch one focused task to an analyst agent
- [assets/round-report-template.md](assets/round-report-template.md) — the conclusion-first, self-correcting round report

## Suggested workflow when you don't know where to start

1. **Pre-flight** — is it packed? what engine? (decision tree above + references/05)
2. Run `scripts/analyze_apk.py` on the libapp — get the lay of the land.
3. If blutter works → use its `pp.txt` + `asm/`. If not (custom engine) → follow
   references/01 §3-4 (unflutter + manual pool deserialization + capstone).
4. Locate the target feature via the 5-step loop. Record exact offsets.
5. If you need dynamic confirmation and callers=0 → references/03 (native ARM required).
6. Patch with the primitives; verify on device every time (bump versionCode!).
7. Keep a [round report](assets/round-report-template.md) — name every dead-end so you
   (or the next agent) never re-walk it.

## Known hard limits (don't waste time re-proving these)

- **blutter dies on custom/patched Dart engines** (cid-table drift, feature mismatch).
  Symptom: zero output or "No cluster defined for cid N". Fall back to manual pool parse.
- **houdini (x86 emulator) makes frida read-only** — hooks/patches silently no-op;
  only memory reads work. Go native ARM for anything execution-dependent.
- **apktool-repack breaks packers (jiagu)** → `MissingPluginException` → black screen
  on real devices (emulator "success" is a false positive).
- **Dart `False ≠ 0`** — materialize via `add xR,x22,#0x20`, never `movz w0,#0`.
- **install -r with unchanged versionCode does NOT replace libapp.so** — always bump it.

## Attribution

Methodology condensed from the `ppcat` reverse-engineering project (Flutter/Dart 2.19 AOT,
custom engine, 360-jiagu packed) — 173 commits across main/backup/test1/test2/test3, built
with multi-model collaboration (human controller + Codex + analyst agents). That campaign
ultimately hit a structural ceiling (shared render functions + cid-typed returns +
check-coupled state flags); its **lessons and tooling** are what this skill packages.
