# 07 — UI Dialogs & Ad / Reward Removal

> How to defeat the "tamper detected" / "fault" dialogs and remove ad/reward UI in a
> Flutter app. The **central insight**: a Flutter popup has one of **three sources**, each
> needing a different defeat. Mis-triaging is the biggest time-sink.

## Table of contents
1. The 3-source dialog triage
2. Source (a) — explicit showDialog
3. Source (b) — uncaught-exception dialog (the trap)
4. Source (c) — integrity-gate dialog
5. Ad-removal architecture
6. The SharedPreferences key system
7. The safe-NOP envelope
8. Generic playbooks

---

## 1. The 3-source dialog triage

| Source | Mechanism | Why blind BL-NOP fails | Correct defeat |
|---|---|---|---|
| **(a) explicit showDialog** | App calls a dialog helper directly | It works | NOP the dialog-show `BL` |
| **(b) uncaught-exception** | `MissingPluginException` (no Java channel handler) → `FlutterError.onError` / zone `onError` → **async** dialog | The dialog is NOT reached via any showDialog BL chain | **Truncate the body constructor**; or Java-stub the missing channel |
| **(c) integrity gate** | An aggregation function ORs ~7 checks; any true → dialog | NOP masks one symptom | Neutralize the aggregation function / its branches |

**How to tell them apart:**
1. logcat + Dart stack frames. If you see `MissingPluginException` / `Unhandled Exception` and
   the dialog appears on a ~60s timer → source (b), not (a)/(c).
2. NOP every showDialog orchestrator. If the dialog **still fires** → source (b) or a global
   error path; stop NOP-ing dialogs.
3. Tie the dialog text to a pool ref → find the body builder → trace callers. If callers=0
   (cid dispatch) and no showDialog BL → source (b).

## 2. Source (a) — explicit showDialog

Find the `showDialog` helper (a hot BL target in `scripts/disasm_functions.py`'s
`bl_targets.txt`), then NOP each call site — but only inside the **safe-NOP envelope** (§7).

## 3. Source (b) — uncaught-exception dialog (THE trap)

When ad channels are removed (plugin `registerWith` commented out), a timer invokes ad
methods with no Java handler → each throws `MissingPluginException`. Because these are
**uncaught**, they bubble to the app's global error handler (`FlutterError.onError` /
`runZonedGuarded`), which builds a fault body and shows a dialog **asynchronously — not via
any showDialog BL**.

**Proof it's not showDialog-based:** NOP-ing *all* fault-dialog orchestrators still left the
dialog firing at T+260s.

**The real fix — truncate the fault-body constructor.** The fault body is built by a single
function (loads the fault-body ref). Make it never build the body:
```python
# inside the body builder, flip the conditional build to an unconditional skip
{"op": "set", "offset": "0xBODYDECISION", "bytes": "29000014"}  # b.ls → b  (skip body)
```
Now the global handler has nothing to display. **No need to locate/stub the global handler.**

**Complementary source fix — Java-stub the missing channel:** register a no-op
`MethodCallHandler` on each removed channel. **Critical caveat:** a *uniform* return value
crashes — each Dart method casts `invokeMethod`'s result to a different type (bool / Map /
custom object). A correct stub returns the **exact type each method expects**; for reward
methods, emit `onReward` then `onAdClose` events so the reward flow completes. This is why
the constructor-truncate patch is the lower-risk path for pure popup suppression.

## 4. Source (c) — integrity-gate dialog

Integrity checks are centralized in one **aggregation function** that ORs ~7 checks
(signature, packer-presence, maps-redirect, file-redirect, emulator, LSPatch, Xposed); any
true → dialog. Hunt for **one function referencing many `check*`/`get*` channel-method
strings, ending in conditional→dialog-build**.

The **long-form dialog text reveals which check fired** (e.g. "installed in a third-party
virtual environment" = the emulator/env check). When a tamper patch works on one device but
not another, the dialog text tells you which *new* check category is firing.

Defeat options:
```python
# Option A (preferred, stable): NOP the aggregate fail-branches (CMP W0,W22; B.EQ fail)
{"op": "nop", "offset": "0xFAILBR1"}, {"op":"nop","offset":"0xFAILBR2"}, ...
# Option B (aggressive): entry-null the dialog-constructor helpers
{"op": "entry-null", "offset": "0xDIALOGCTOR"}
```
`scripts/function_triage.py` (cmp*3 + cond_branches ranking) surfaces the aggregation function.

## 5. Ad-removal architecture

| Layer | What | Defeat |
|---|---|---|
| Master bool gate | one flag gating *all* ad decisions | patch the consumer (often SP write-only) |
| Per-feature gates | splash/banner/reward/interstitial each decide | branch-flip / leaf NOP |
| Ad-display popups | the showDialog BLs that render ad UI | safe-NOP envelope |
| SDK registration | Java `registerWith` wiring channels to ad SDKs | comment-out (→ source-b risk) OR Java stub |

Ad SDKs (Pangle/GDT/AdMob/Ksad) register via channels; the **dispatch matrix** lives in pool
slots (a 4-SDK × 4-type table). Disabling registration removes channel strings but every ad
method then throws MissingPluginException → source-(b) fault dialog. Prefer the body-truncate
+ per-feature NOPs.

## 6. The SharedPreferences key system (enumerate first)

**Highest-leverage static attack:** scan the pool for camelCase config strings, classify each
as **READ** (SP write works) vs **WRITE-ONLY** (must patch libapp):
- `showSplashAd` → **read** → `SP=false` disables splash (no patch needed!)
- the master ad-lock flag → often **write-only** → you MUST patch the libapp reader

So always check: can I just write a SharedPreferences value instead of patching? Many UI
gates are SP-read.

## 7. The safe-NOP envelope (the classifier for all ad-UI BLs)

Every safe-to-NOP dialog popup follows this exact envelope:
```
2×STP push → BL <dialog> → ADD X15,#0x20 (pop) → MOV X0,X22 → RET
bytes: fd79bfa9 fd030faa [8-byte BL] ef034191 e00316aa fd79c1a8 c0035fd6
```
**Rule:** any `BL` to a showDialog helper inside this envelope → replace with `1f2003d5`
(NOP), stack-safety guaranteed. This single classifier turns ad-UI removal from guesswork
into a mechanical scan.

## 8. Generic playbooks

1. **Triage any popup** — logcat + Dart frames → tie text to pool ref → find body builder →
   classify (a/b/c) → apply the matching defeat.
2. **Find the integrity aggregator** — one function referencing many check-strings + conditional
   → dialog. Patch aggregate branches, not just orchestrator entries.
3. **Enumerate SP keys** — classify READ vs WRITE-ONLY; prefer SP writes for READ keys.
4. **Classify safe-NOP sites** — the envelope above; any showDialog BL inside it → NOP.
5. **Converge to minimum patch surface** — a guarded block loading exactly one non-VIP/non-login
   string is an ideal branch-flip target (`TBZ→B`), zero collateral. Aim for ~3 patches + 1 SP write.
6. **Verify pool-slot mappings before patching** — a wrong map silently retargets a patch.
   Cross-verify each slot→ref with anchors (see [01-flutter-dart-aot.md](01-flutter-dart-aot.md) §5).
