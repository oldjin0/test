# 05 — Packers / Protectors (360 Jiagu) & Repacking Pitfalls

> **The most important failure-mode in the whole campaign.** Detect a packer BEFORE you
> commit to a repack workflow — it can save days. This is the "pre-flight gate" the SKILL.md
> router demands.

## Table of contents
1. THE meta-lesson (read first)
2. How 360 jiagu works
3. THE critical failure: repack destroys the shell → black screen
4. The false-positive trap (emulator leniency)
5. Detecting a packer early
6. The 3 correct delivery paths
7. Cross-cutting lessons

---

## 1. THE meta-lesson

> **If the target APK is packed/shelled (加固), `apktool b` repacking is the WRONG delivery
> path.** Repacking re-assembles DEX from smali, which destroys the packer's shell, so the
> runtime can't decrypt the real code → `MissingPluginException` → **black/blank screen on
> real devices.**

This overturned an entire assumed-correct delivery strategy. **Detect the packer first.**
A 2-minute check saves days of chasing black screens from a doomed repack.

## 2. How 360 jiagu (libjiagu) works

A packer/壳 encrypts the real application DEX and ships a **stub** instead. At runtime the
stub decrypts the real code in memory and runs it.

- `assets/libjiagu*.so` (+ `_a64/_x64/_x86`) = 360 jiagu runtime
- `libzeus_direct_dex.so` = dynamic DEX loader
- the original `classes.dex` is **only the shell** — no business strings in it
- entry class replaced with a 360 stub (e.g. `com.stub.StubApp`)

**The shell is transient:** libjiagu loads, decrypts, **unloads itself**. It may NOT appear
in `/proc/self/maps` even on the legitimate app at check time. → A memory dump taken too
early/late misses the decrypted DEX.

**Other packer families** (same failure mode): Bangcle (`libSecShell`), Tencent Legu
(`libshell`/`libshella`), ijiami, 娜迦 (`libnsaer`/`libnq`), Ali (`libmobisec`).

## 3. THE critical failure: repack destroys the shell

```
apktool d → smali → apktool b   re-assembles DEX
  → a packer stub is NOT normal re-assemblable code; it carries self-integrity/layout
    assumptions that the smali→dex round-trip breaks
  → libjiagu can't locate/validate the encrypted payload → never decrypts
  → any platform-channel handler in the (still-encrypted) real DEX throws MissingPluginException
  → Flutter uncaught exception tears down rendering → BLACK SCREEN (process alive, no crash)
```

**Smoking gun:** `classes.dex` (1× ~8.9MB) round-trips into **multiple** DEX (e.g. 6) with
empty ~140-byte `classes4/5/6.dex`.

**The contradiction it creates:** any change that must enter the DEX (e.g. injecting a Java
hook) requires a repack — which breaks the shell. This is the core blocker.

## 4. The false-positive trap

> A repacked, shell-broken APK can still *appear to work* on an emulator (LDPlayer/houdini)
> because the packer's integrity check is **relaxed/emulated** there. The same APK
> **black-screens on a real ARM device** where the packer enforces strictly.

**Lesson:** never validate a repack workflow on an emulator alone if a packer is involved.
Always confirm on a real device with the target OS. "It works on LDPlayer" is **not** evidence.

## 5. Detecting a packer early (run BEFORE repacking)

```bash
unzip -l app.apk | grep -iE 'libjiagu|libshell|libSecShell|libnq|libmobisec|libzeus'
apktool d app.apk -o build
grep -ri 'StubApp\|Application' AndroidManifest.xml smali/ | head
```
Markers:
- `assets/libjiagu*.so`, `libzeus_direct_dex.so`, a `.jiagu` dir
- `com.stub.StubApp` (or similar) as the Application class
- a single huge `classes.dex` that is **only** the stub (no business strings)
- DEX round-trip → multiple DEX with empty stubs

Any positive ⇒ packed ⇒ route to a packer-aware path (§6).

## 6. The 3 correct delivery paths

When packed, pick one:

**(a) Unpack then repack** (best fidelity)
Use an unpacker (`blackdex`, `FART`/`frida-dexdump`) to recover the *decrypted real* DEX from
the live process during the decryption window (remember the shell is transient). Then re-pack
from the real DEX — the shell is no longer needed. **Pitfall:** scrub every packer artifact
(`libjiagu*`, `.jiagu`, `libzeus*`) from assets before rebuilding, or the packer runtime
conflicts with the now-plain DEX.

**(b) LSPatch / no-repack injection** (lowest risk to the shell)
Inject dex hooks **without** re-assembling DEX — the shell and its self-integrity are
untouched. Replace `libapp.so` in place; inject Java hooks via LSPatch. Caveat: the app may
**detect LSPatch** (an integrity signal you must also handle). Preferred path.

**(c) Resident gadget** (no file change at all)
Inject `frida-gadget`; run an auto-start script performing runtime signature spoof + libapp
memory patches on every boot. No DEX touched, shell untouched. Caveat: gadget is detectable,
and runtime flips of check-coupled flags can backfire.

**Not recommended:** making apktool repack pass jiagu checks ("加固壳兼容") — requires
reverse-engineering libjiagu's validation. Hard.

## 7. Cross-cutting lessons

1. A packer makes "it works on the emulator" meaningless — validate on real hardware.
2. A packer + an app that **self-checks for the packer** = double constraint. Removing the
   shell (path a) may trip the app's own jiagu-presence check unless you also neutralize it.
3. Round-tripping a stub through smali is lossy by design (empty 140-byte DEX).
4. Capture the decryption window — transient unload means memory dumps must be timed.
5. Shared flags couple features to anti-tamper — runtime flipping a "display" bool that is also
   an integrity signal is a trap.
6. **Detection is the cheapest fix** — 2 minutes of packer detection saves days.
