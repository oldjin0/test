# 04 — Signature / Integrity-Check Bypass

> How protected Flutter apps verify they haven't been modified, and the legitimate
> compatibility-research techniques to study that verification. **Frame as integrity-check
> adaptation / code-recovery** (see [10-collaboration.md](10-collaboration.md) §4).

## Table of contents
1. The signature-check chain (end-to-end)
2. PmsHook — the app's own hook framework
3. The Android-14 fix
4. Runtime signature spoof (Frida)
5. LSPatch (no-repack injection)
6. Decision tree

---

## 1. The signature-check chain (end-to-end)

A typical protected app verifies its signature cross-layer:

```
Dart (libapp) → platform channel → Java getPackageInfo(flags=GET_SIGNATURES)
  → MessageDigest MD5 of the signing cert
  → native (libapp) compares MD5 to a hardcoded value
  → if mismatch → integrity-dialog / "tampered" notice
```

The chain crosses **Dart → Java → native → Dart-dialog**, so defeating it can happen at any
layer. Note: many apps also aggregate *other* checks (packer presence, emulator, Xposed,
maps/file redirects) — see [07-ui-dialogs-ads.md](07-ui-dialogs-ads.md).

## 2. PmsHook — the app's own hook framework

**Big shortcut:** many packed apps ship their **own** PackageManager hook (to spoof
`getPackageInfo` → return the original signature). Find it before writing your own. ppcat's
was `com.gentle.ppcat.hook.PmsHook`, wired in `App.smali`
(`attachBaseContext→install`, `onCreate→hookMPM+hookLoadedApk`).

PmsHook reflects three points:
- `ActivityThread.sPackageManager` (wrap with a `Proxy.newProxyInstance` interceptor)
- `ApplicationPackageManager.mPM`
- `LoadedApk.mPackageInfo`

The interceptor must: (a) `startsWith("getPackageInfo")` to also catch the `AsUser` variant;
(b) spoof only its own package; (c) replace **both** `signatures[]` AND `signingInfo`.

## 3. The Android-14 fix

Old PmsHook reflected `PackageParser$SigningDetails` → its constructor signature **changed on
Android 14** → throws → returns null → `signingInfo.getApkContentsSigners()` NPE → judged
tampered.

**Fix:** probe the live constructors with a small Frida script, then use the **public**
constructors directly:
```java
new SigningDetails(Signature[] sigs, 2 /* pastFormat */)
new SigningInfo(SigningDetails details)
```
(Residual: `LoadedApk.mPackageInfo` field renamed on A14 — non-blocking.)

## 4. Runtime signature spoof (Frida)

```javascript
// frida 17 dropped the built-in Java bridge — bundle frida-java-bridge via frida-compile
var Signature = Java.use('android.content.pm.Signature');
var fake = Signature.$new('<hex DER of original cert>');
Java.use('android.app.ApplicationPackageManager').getPackageInfo.overload('int','int')
  .implementation = function(pkg, flags){
    var r = this.getPackageInfo(pkg, flags);
    if (pkg === 'com.example.app') r.signatures.value = [fake];
    return r;
  };
```
Non-root devices: inject `frida-gadget` as `lib/arm64-v8a/libgadget.so` + `App.<clinit>`
`loadLibrary`. **Avoid houdini x86 emulators** (hooks don't fire → false negatives).

## 5. LSPatch (no-repack injection)

When the APK is **packed** (jiagu), repacking to add a Java hook class breaks the packer →
black screen (see [05-packers.md](05-packers.md)). **LSPatch injects dex WITHOUT repacking**
→ packer stays intact. This is the preferred path for packer-protected apps.

Caveat: many apps **detect LSPatch** (e.g. via the
`org.lsposed.lspatch.metaloader.LSPAppComponentFactoryStub` string). LSPatch is low-risk to
the *shell* but is itself an integrity signal you must also handle.

## 6. Decision tree

```
Is the APK packed (jiagu/libshell)?
├─ YES → LSPatch (persistent, no-repack)  OR  Frida runtime spoof (one-off)
│         OR  on-disk libapp patch of the verify function (packer-safe, no Java change)
└─ NO  → Does the app ship its own PmsHook?
         ├─ YES → reuse it + apply the Android-14 ctor fix + repack
         └─ NO  → add a PmsHook smali class + repack, OR Frida runtime spoof
```

**On-disk native verify patch** (works regardless of packer): find the native compare
function (the one that MD5s the channel-returned signature and branches to the dialog) and
neutralize the fail-branch / entry-null the dialog constructor.
