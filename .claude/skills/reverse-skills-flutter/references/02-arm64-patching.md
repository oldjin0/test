# 02 — ARM64 (libapp.so) Binary Patching

> How to change a Flutter app's behavior by patching `libapp.so` bytes. Four safe,
> reversible primitives + a reproducible config system. All offsets below are
> **examples** (ppcat); the **patterns** and the **verification logic** are universal.
>
> Use `scripts/patch_libapp.py` to apply; `scripts/verify_bytes.py` to confirm on device.

## Table of contents
1. Dart AOT ABI / register convention
2. Pattern A — entry-null (kill a function → return null)
3. Pattern B — `const SizedBox.shrink` return (widget neuter) — and its trap
4. Pattern C — BL NOP (`1f2003d5`)
5. Pattern D — branch flip / unconditional B
6. Pool-slot xref scanning
7. Repack + sign + verify workflow
8. The 7 operational gotchas
9. Generic patching recipe

---

## 1. Dart AOT ABI / register convention

Everything depends on this. Dart AOT (arm64) is register-allocated against a fixed ABI:

| Register | Role |
|---|---|
| **X27** | **PP — object-pool pointer**. Every snapshot constant lives in the pool array. |
| **X22** | **Null sentinel**. `mov x0, x22` returns Dart `null`. |
| X15 | shadow-call-stack pointer |
| X26 | Thread |
| X28 | heap base (compressed pointers) |
| X21 | dispatch table base (cid virtual dispatch) |

A pool constant at **slot index `idx`** is loaded:
```
add  xR, x27, #(idx*8 >> 12), lsl #12   ; page
ldr  xD, [xR, #((idx*8 & 0xFFF))]       ; imm12 in 8-byte units
```
So **slot byte-offset = idx × 8**. Function prologue: `stp x29,x30,[x15,#-16]!; mov x29,x15`
→ bytes `fd 79 bf a9 fd 03 0f aa`.

## 2. Pattern A — entry-null (the 4-word "kill a function" gadget)

```
mov  x0, x22      ; x0 = Null          e00316aa
mov  x15, x29     ; x15 = frame ptr    ef031daa
ldp  x29,x30,[x15],#0x10  ; restore    fd79c1a8
ret                                    c0035fd6
```

**Why it works:** at the first conditional branch (still in the prologue, before further
frame allocation), `x29` points at the saved caller `(x29,x30)` pair. The gadget loads null
into the return register, restores the caller's FP/LR, and returns — **frame-balanced**.
Returning null from a Flutter `build`/orchestrator = the parent renders nothing = widget gone.

**Prologue-verification gate** (`scripts/patch_libapp.py --entry-null` does this): the entry
word must be `0xA9xxxxxx` (STP) — for the Dart shadow-stack prologue, the bytes `fd 79 bf a9
fd 03 0f aa`. Find the first conditional branch (`0x54xxxxxx`) in `+0x8…+0x44` and land the
gadget there. **Never stamp it blindly at offset 0.**

**The trap:** some entries are **poison** to null-out — ad/async state machines, splash
controllers. Nulling them starves the Future/callback graph → stuck splash or piling dialogs.
ppcat untouchables: `0xbc0f40 / 0xbd5a24 / 0x7e1464`. **Rule: patch internal calls/branches,
never a hot entry. Keep an allowlist of untouchable entries.**

## 3. Pattern B — `const SizedBox.shrink` return (5-word) — and its trap

Used to neuter a widget builder by returning a real zero-size widget instead of null:
```
add x0,x27,#0x1c,lsl12   ; 60734091  — x0 = pool page
ldr x0,[x0,#0xba8]       ; 00d445f9  — load const SizedBox slot
mov x15,x29 ; ldp ; ret  ; ef031daa fd79c1a8 c0035fd6
```
**THE TRAP (cost the campaign a SIGSEGV):** a pool slot that *looks* like a widget may be a
**debug/symbol-name String** (e.g. the literal text `"SizedBox.shrink"`), not a widget
instance. Returning a String where a Widget cid is expected → type mismatch → native crash.

> **Rule: to remove a widget, use entry-return-null (Pattern A), NOT an unverified pool slot.**
> Use Pattern B only after deserializing the pool to PROVE the slot is a real `const Widget`.

## 4. Pattern C — BL NOP (`1f2003d5`)

`1f2003d5` = ARM64 `NOP`. Disables a `BL <showDialog>` while leaving the surrounding function intact.

**Safe when** the BL is bracketed by balanced stack bookkeeping (2× STP push before, an
`add x15`/pop after) AND the return value in x0 is overwritten by a later `mov x0,x22`. Then
NOPing leaves sp/fp balanced and no stale x0 leaks.

**Crashes when:** you NOP a hot entry's internal BL that participates in splash teardown, or
the dialog is an **uncaught-exception** dialog (`FlutterError.onError`), NOT a `showDialog` BL.
NOPing `showDialog` BLs **cannot** defeat a global-error-handler dialog — see
[07-ui-dialogs-ads.md](07-ui-dialogs-ads.md). Don't keep NOP-ing hoping it'll work.

## 5. Pattern D — branch flip / unconditional B

- **`xx000014`** (`0x14000000 | imm26`): force a branch / skip a block. Used to force a bool
  gate or skip a reward block.
- **Conditional flip** (`0x54xxxxxx`): redirect which arm fires (e.g. `b.ne` → `b.eq`, or
  change the ad/startup gate target).
- 1-word, low-risk, reversible. For boolean/gate logic; reserve A/B/C for whole-function removal.

## 6. Pool-slot xref scanning

Given a string/const ref, find every function that loads it, **by raw byte pattern** (no
decompiler needed). `scripts/pool_xref.py` implements this:

```
for each ADD xR,x27,#page,lsl12 in .text:
    look ahead ≤5 insns for LDR xD,[xR,#off]  → offset = (page<<12)+off
also: direct LDR xD,[x27,#off]  (page==0)
slot_index = offset / 8
```
Calibrate against one known loader before trusting. Blind spot: non-standard encodings
(some channels/reward strings) are missed — a negative result ≠ "unused". Cross-check.

## 7. Repack + sign + verify workflow

```bash
# 1. patch (always from pristine original)
python3 scripts/patch_libapp.py libapp_orig.so libapp_patched.so --spec patches.json
# 2. repack (⚠ bump versionCode every build! clear apktool build cache!)
apktool d app.apk -o build
cp libapp_patched.so build/lib/arm64-v8a/libapp.so
sed -i 's/versionCode: .*/versionCode: 1NNN/' build/apktool.yml
apktool b build -o unsigned.apk
# 3. sign + align
uber-apk-signer.jar -a unsigned.apk --out signed --ks debug.keystore \
    --ksAlias androiddebugkey --ksPass android --ksKeyPass android --allowResign
# 4. install
adb install -r signed/*aligned*signed.apk
# 5. VERIFY on device (pull installed APK, byte-check)
adb shell pm path com.example.app     # → package:/data/app/.../base.apk
adb pull <that path> installed.apk
python3 scripts/verify_bytes.py installed.apk 0x8e1dd0:e00316aac0035fd6 ...
```

## 8. The 7 operational gotchas (each cost real time)

1. **versionCode trap** — `install -r` with unchanged versionCode does NOT replace
   `libapp.so`. Always bump it. Always clear apktool's `build/build` cache.
2. **Emulator false-positive** — if the app is packed, the emulator (LDPlayer/houdini) relaxes
   the packer; "it works on LDPlayer" is NOT evidence. See [05-packers.md](05-packers.md).
3. **file_offset ≠ vaddr** — confirm per binary before trusting offsets.
4. **Packer + repack** — apktool-repacking a jiagu-packed APK black-screens it on real devices.
5. **Untouchable entries** — never null a hot/splash/async entry.
6. **Dart False ≠ 0** — materialize via `add xR,x22,#0x20` (`c0820091`), never `movz w0,#0`
   (→ SIGILL). True = `+0x30`.
7. **Stack-reload trap** — patch the instruction feeding the branch register at the point of
   consumption, not an earlier load the shadow stack overwrites.

## 9. Generic patching recipe (apply to a NEW Flutter APK)

1. `apktool d` → locate `lib/<abi>/libapp.so`. Keep a pristine `libapp_orig.so`.
2. Recover symbol context (blutter, or the manual pool path). You need: a function
   `(start,end)` table, a `ref→slot` map, and string refs.
3. Confirm the ABI (Null reg, PP reg=x27, .text base). Decode a known const-load to confirm
   `slot_offset = idx×8`.
4. Find the target widget/behavior: string ref → slot → `pool_xref.py` → functions.
5. **Choose the primitive by intent** (see SKILL.md quick-patch table).
6. Encode as a JSON spec (`patches.json`) of atomic ops; apply from the original each time.
7. Repack (bump versionCode), sign, install.
8. Verify on device: `verify_bytes.py` + `uiautomator dump` (Flutter text in `content-desc`).
9. Keep an untouchable-entries allowlist.
10. If NOPs don't kill a dialog, suspect an unhandled-exception path — fix the root.
