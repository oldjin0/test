# Tool Catalog

> Every tool in the APK-reverse workflow, with install commands and when-to-use. Plus the
> Claude-Code MCP servers that assist. Copy-paste the install commands.

## A. Flutter / Dart static

| Tool | What | Install | When / NOT |
|---|---|---|---|
| **blutter** | Disassembles Dart AOT → annotated asm + full object pool (`pp.txt`,`asm/`,`blutter_frida.js`). **Primary.** | `git clone https://github.com/worawit/blutter.git && cd blutter && git submodule update --init --recursive`; needs C++20 (gcc≥13/clang≥16) | First tool for any Dart app. **Fails on custom engines** → fall back to `strings libflutter.so \| grep dart-ver` + `dartvm_fetch_build.py <ver> android arm64` |
| **reFlutter** | Alt Dart pool dump / repack; weak but few deps | `pip install reflutter` | Only when blutter won't build |
| **darter** | Dart snapshot parser | `pip install darter` (github.com/mildsunrise/darter) | blutter fallback |
| **unflutter** | Go Dart snapshot parser — survives custom engines; gives VM structure + ref→string table | clone + `go build`; or use `scripts/deserialize_pool.py` (Python equivalent) | When blutter dies on a custom VM |
| **Ghidra** (+ pyghidra) | ARM64 ELF decompiler; pyghidra = Python scripting | Ghidra download + JDK; `pip install pyghidra` | Cross-check capstone disasm; decompile stubborn funcs |

## B. Java / DEX

| Tool | What | Install | When / NOT |
|---|---|---|---|
| **apktool** | DEX↔smali decode/repack | `apt install apktool` or download `apktool.jar` | Read/patch Java layer; repack. ⚠ **repacking a packed APK black-screens it** (see [05-packers.md](05-packers.md)). Bump `versionCode` every build |
| **jadx** | DEX→Java | `apt install jadx` / jadx-gui | Read obfuscated Java when smali isn't enough |
| **smali/baksmali** | DEX↔smali (apktool engine) | bundled / `apt install smali baksmali` | Edit Java logic (PmsHook, ad stubs) |
| **dex2jar / dexdump / enjarify** | DEX→JAR / raw DEX inspect | `apt install dex2jar dexdump`; `pip install enjarify` | When apktool/jadx fail |

## C. ARM64 binary

| Tool | What | Install | Notes |
|---|---|---|---|
| **capstone** (Python) | ARM64 disasm — the dominant static engine | `pip install capstone` (`apt install libcapstone-dev`) | Used by `scripts/disasm_functions.py`, `function_triage.py` |
| **pyelftools** | ELF parse | `pip install pyelftools` | Validate ELF layout. (Scripts have a no-dep fallback.) |
| **unicorn** | ARM64 emulation | `pip install unicorn` | Emulate a gate function's control flow without a device (heap-coupling limits it) |
| **objdump/readelf** | CLI disasm/ELF | `apt install binutils` | One-off checks |

## D. Dynamic instrumentation

| Tool | What | Install | When / NOT |
|---|---|---|---|
| **frida** (server+client+gadget+compile+java-bridge) | Hooks, memory dump, tracing | client `pip install frida-tools`; server `frida-server-<ver>-android-arm64` (adb push, root); gadget → `lib/arm64-v8a/libgadget.so` + `App.<clinit>` loadLibrary; **frida-17 needs `frida-compile`** to bundle `frida-java-bridge` (`npm i frida-java-bridge`) | Memory read always; **hooks/patches only on native ARM**. houdini kills them. Use spawn mode (`-U -f`) to beat anti-tamper |
| **objection** | frida wrapper | `pip install objection` | Quick hooks/SSL-pin bypass |

## E. Packer / unpacking

| Tool | What | Install | When |
|---|---|---|---|
| **blackdex** | Dumps decrypted DEX from memory | github.com/CodingGay/blackdex | Unpack jiagu before repack-without-breaking path (a) |
| **FART / frida-dexdump** | Frida DEX dump | `pip install frida-dexdump` | Same; needs working frida (native ARM) |
| **LSPatch / Xposed** | No-repack dex injection | github.com/LSPosed/LSPatch | Preferred when repack is forbidden by packer (path b). ⚠ detectable |

## F. Repack / sign

| Tool | What | Install | Notes |
|---|---|---|---|
| **uber-apk-signer** | sign+zipalign+verify in one | download `uber-apk-signer.jar` + debug keystore | `apktool b → uber-apk-signer → adb install -r` |
| **apksigner / zipalign** | v2/v3 sign / align | Android SDK build-tools / `apt install apksigner` | Alternative signer |

## G. Emulators / devices

| Tool | When | Limits |
|---|---|---|
| **LDPlayer 9** (x86_64+houdini) | Stable, fast **static** patch-test | houdini → dynamic read-only. "Working" can be packer-downgrade illusion |
| **redroid** (ARM-native Docker) | Real ARM hooks | Unstable on free tier; heavy setup. See [06-environments.md](06-environments.md) |
| **Physical ARM device** | Real-target signature proof + final verification | `stayon` before capture; judge by screenshot size |

## H. Android interaction

| Tool | Notes |
|---|---|
| **adb** | most-used; install/push/shell/screenshot |
| **logcat** | confirm hook triggers, MissingPluginException, tombstones |
| **uiautomator** | dump Flutter tree (Flutter uses `content-desc`, not `text=`); unstable → screenshot-size fallback |
| **aapt/aapt2** | manifest/versionCode; bump versionCode to force native-lib replacement |
| **sqlite3** | inspect app DBs / SP-backed files |

## I. MCP servers (Claude Code ecosystem)

| MCP | Use in APK reverse |
|---|---|
| **jshook** (16 domains: debugger/network/process/core/browser/hooks/wasm/antidebug/…) | **debugger**: native breakpoints/trace (parallel to frida). **network**: inspect app HTTP (parallel to mitmproxy). **process**: enumerate/inject. **hooks**: inline hooks. **browser**: drive WebView-based Flutter. **antidebug**: research the app's anti-debug. Use `search_tools`/`route_tool` to discover, `activate_tools`/`activate_domain` to enable |
| **chrome-devtools** | WebView-Flutter (flutter_web): snapshot UI, evaluate JS, capture network/fetch, lighthouse |
| **context7** | Current docs for frida/capstone/unicorn/ghidra/apktool/redroid/LSPatch — training data lags; check before assuming API signatures |
| **sequential-thinking** | Plan multi-stage strategy (find cid → constructor → guard → patch); branch hypotheses |

## J. This skill's own scripts

See `scripts/README.md`. `analyze_apk.py` → `find_strings.py` / `deserialize_pool.py` / `disasm_functions.py` → `pool_xref.py` → `function_triage.py` → `patch_libapp.py` → `verify_bytes.py`.

## Recommended starter toolchain (minimal)

```bash
git clone https://github.com/worawit/blutter.git          # primary decompiler
python3 -m pip install pyelftools capstone requests        # analysis
apt install -y apktool jadx                                 # Java/DEX layer
python3 -m pip install frida-tools                          # dynamic (native ARM only)
# adb, logcat, uiautomator (platform-tools)
```

## Full belt (hardened apps)

Starter + `pip install reflutter darter unicorn pyghidra` + Ghidra + unpackers
(`blackdex`, `frida-dexdump`) + LSPatch + `uber-apk-signer`/`zipalign`/`apksigner` + redroid
(ARM Docker) / physical ARM device + MCPs (jshook, chrome-devtools, context7).

## Known pitfalls (don't re-prove)

1. **houdini + frida = read-only** — hooks/patches silently no-op; only memory reads work.
2. **blutter fails on custom engines** — use `strings`+`dartvm_fetch_build.py` fallback, then manual pool parse.
3. **apktool repack breaks 360-jiagu** → MissingPluginException → black screen.
4. **versionCode must bump** every rebuild or libapp isn't replaced.
5. **Dart bool**: True=`null+0x30` (`…8071`), False=`null+0x20` (`…8061`) — flipping a shared bool trips integrity checks.
6. **cid virtual dispatch hides static callers** — only dynamic backtrace finds them.
