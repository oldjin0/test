# 06 — Choosing an Android Test Environment

> Static (on-disk) patch-and-test runs anywhere. **Live Frida work only works on NATIVE ARM.**
> Final delivery must be verified on a physical device matching the target. Pick the right
> environment for the job.

## The one-sentence rule

> Static patch-and-test → any emulator (even houdini). Dynamic Frida/Dart analysis → MUST be
> native ARM. Final delivery verification → physical device matching the target.

## Capability comparison

| Capability | LDPlayer (x86_64 + houdini) | redroid (ARM-native Docker) | Physical ARM device |
|---|---|---|---|
| Architecture | x86_64 host, arm64 translated | arm64-v8a **native** | arm64-v8a native |
| `Process.arch` | `x64` | `arm64` | `arm64` |
| `findModuleByName('libapp.so')` | **null** | resolved | resolved |
| Memory READ | ✅ | ✅ | ✅ |
| Hooks fire | ❌ (0 hits) | ✅ | ✅ |
| Runtime patch | ❌ (ignored) | ✅ | ✅ |
| Static on-disk patch | ✅ | ✅ | ✅ |
| Anti-tamper behavior | **Relaxed** (false-positive!) | Strict-ish | Strict (matches target) |
| Stability | High | **Low** | High |
| Iteration speed | Fast | Medium | Slow |
| Cost | Free | Free (Oracle Ampere free tier) | The device |
| Setup difficulty | Low | **High** | Medium |

## The houdini dead-end (hard proof)

On x86_64 + houdini, **all live frida ops on translated ARM64 code silently no-op** — only
bare-address memory reads survive. Houdini translates ARM64→x86_64 once at load and caches it;
execution walks the cache, never your patched bytes.

**Decisive proof:** patch a known-essential builder's first instruction to a bare `ret`
(`c0035fd6`); if the UI **still renders normally**, the runtime never runs your patched bytes.
Stop doing live frida there. (Static on-disk patches still work under houdini — bytes are
re-translated at next launch.)

## redroid ARM-native setup (verbatim Docker command)

Host: a native-ARM box (Oracle Cloud **Ampere A1 free tier** works; 4c/23G). The gotchas are
load-bearing:

```bash
modprobe binder_linux devices="binder,hwbinder,vndbinder"
mkdir -p /dev/binderfs
docker run -itd --privileged \
  --memory=4g --memory-swap=4g --cpus="3" \
  -v /dev/binder:/dev/binder \
  -v /dev/hwbinder:/dev/hwbinder \
  -v /dev/vndbinder:/dev/vndbinder \
  -v /root/redroid-data:/data \
  -p 5555:5555 \
  redroid/redroid:14.0.0-latest \
  androidboot.redroid_gpu_mode=guest \
  androidboot.use_memfd=1 \
  ro.product.brand=Xiaomi ro.product.manufacturer=Xiaomi ro.product.model=M2012K11C \
  ro.product.device=alioth \
  ro.build.fingerprint=Xiaomi/alioth/alioth:13/RKQ1.211001.001/V14.0.6.0.TKHCNXM:user/release-keys \
  ro.build.tags=release-keys
```

**Critical gotchas (each learned the hard way):**
1. **Binder = bind-mount** (`-v /dev/binder:/dev/binder`), NOT `--device`, NOT binderfs. Using
   `--device` makes `servicemanager` spin → silent guest hang.
2. **`androidboot.use_memfd=1` mandatory** (kernel 6.12 has no ashmem; else vold crashes).
3. **Do NOT set `ro.secure=1 ro.debuggable=0`** — kills root adb. Satisfy anti-tamper by
   keeping the original signature valid, not by hiding root.
4. **`--memory=4g` floor.**
5. **Re-inject adb pubkey** after every rebuild: `docker exec ... echo $PUBKEY > /data/misc/adb/adb_keys`. You can't `docker restart` a stopped redroid (binder gone) — `docker rm -f` + `docker run`.
6. **Use `frida -U -f` (spawn)** for early injection; attach fires 0× under anti-tamper.
7. Prefer `docker cp` over `adb push/install` for large files (adbd crashes under load).

**Why redroid is a data-acquisition tool, not an iteration env:** on the free tier it's
**operationally unstable** (adb drops repeatedly, can't restart containers). Harvest your
dynamic data, then go back to LDPlayer for stable static patch-test loops. For stable native
iteration: AWS Graviton (paid) or a physical ARM box (RPi 5 / ARM mini-PC + root + frida).

## Physical ARM device

Use for: **real-device signature-bypass proof + final delivery verification.** A packer is
strict here — emulator "it works" does NOT transfer. This is the only environment whose "pass"
is trustworthy for delivery.

**Gotchas:**
- `svc power stayon true` + `input keyevent KEYCODE_WAKEUP` before any capture (sleeping screen → tiny misleading screenshot).
- Flutter self-renders → `uiautomator dump` returns null root; judge state by **screenshot
  byte-size** (~10–35KB = broken, ≥200KB = rendering).
- Non-root gadget injection: bundle `frida-gadget-<ver>-android-arm64.so` as
  `lib/arm64-v8a/libgadget.so` + `App.<clinit>` loadLibrary; frida-17 needs `frida-compile`
  to package `frida-java-bridge`.

## Decision tree

```
STATIC patch-and-test (edit libapp bytes, reinstall, observe)
  └─► LDPlayer (fast; static patches work under houdini). ⚠ provisional until real-device check.

DYNAMIC Frida / Dart analysis (hooks, runtime patch, backtrace, cid resolution)
  └─► MUST be native ARM (houdini is a hard dead-end).
      ├─ one-time capture, cost-sensitive → redroid (Oracle Ampere free tier)
      ├─ stable native iteration → AWS Graviton (paid) or physical ARM box
      └─ need the real target's hardening/signature behavior → physical device

SIGNATURE-bypass proof & FINAL DELIVERY verification
  └─► physical device matching the target (real OS, real SoC). Only its "pass" counts.

Quick rules:
- "Does the patched binary render correctly?" → emulator fine.
- "Did my hook fire / patch take effect?" → must be native ARM.
- "Will this ship?" → only a physical-device pass counts.
- If Process.arch==x64 and findModuleByName→null, you're on houdini: stop live frida, go ARM.
```
