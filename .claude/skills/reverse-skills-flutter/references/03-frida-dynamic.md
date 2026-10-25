# 03 — Frida Dynamic Instrumentation (Flutter/Dart AOT)

> When static analysis hits the **cid virtual-dispatch wall** (callers=0) or you need to
> validate a hypothesis before committing to an on-disk patch, Frida is the answer — but
> only on **native ARM**. This doc is the playbook.
>
> All Frida JS below is a template distilled from the source campaign's handoff docs; adapt
> the offsets to your target. The techniques are universal.

## Table of contents
1. The #1 rule: dynamic Dart analysis needs NATIVE ARM
2. The Dart-AOT ABI cheat-sheet
3. The cid virtual-dispatch wall
4. Attaching & resolving libapp (late-load)
5. Techniques: backtrace, Stalker, MemoryAccessMonitor, bool-scan, runtime flip
6. Guard → on-disk patch conversion
7. Anti-tamper: spawn early-injection

---

## 1. The #1 rule: dynamic Dart analysis needs NATIVE ARM

**Houdini (x86_64 emulator + ARM translation) makes Frida READ-ONLY.** This is the
single most expensive lesson.

| Capability | LDPlayer (x86_64 + houdini) | redroid/physical (native ARM) |
|---|---|---|
| `Process.arch` | `x64` | `arm64` |
| `findModuleByName('libapp.so')` | **null** (houdini hides it) | resolved |
| Bare memory READ | ✅ works | ✅ works |
| `Interceptor.attach` (hooks fire) | ❌ arms, **0 hits** | ✅ fires |
| Runtime memory patch | ❌ silently ignored | ✅ takes effect |

**Why:** houdini translates ARM64→x86_64 once at load and **caches** it; execution walks the
cache, never your patched ARM64 bytes. **Proof:** patching a function's first instruction to a
bare `ret` (`c0035fd6`) left the widget rendering normally.

> Under houdini: only **read-only** memory inspection works. For any execution-dependent
> work (hooks, patches, backtraces), switch to native ARM. See [06-environments.md](06-environments.md).

## 2. The Dart-AOT ABI cheat-sheet

```
X15 = shadow-stack   X26 = Thread   X27 = Pool(PP)   X22 = null   X28 = heap base
prologue : stp x29,x30,[x15,#-0x10]!; mov x29,x15   → bytes fd79bfa9 fd030faa
epilogue : mov x15,x29 (ef031daa); ldp (fd79c1a8); ret (c0035fd6)
func+8   = first real instruction after prologue
bool     : add xR,x22,#0x30 = True  /  add xR,x22,#0x20 = False   (tbz/tbnz w0,#4 tests bit4)
PP load  : add xR,x27,#page lsl12 ; ldr xD,[xR,#off] ; slot=(page+off)/8
Thread global: G = Thread[x26+0x80]  (then read G.field@0xXXX)
alloc thunk: mov x2,#imm; movk x2,#cid,lsl16; ldr x4,[x26,#0x228]; br x4
```

## 3. The cid virtual-dispatch wall (why static xref fails)

Dart `build`/virtual methods are reached **not** by `BL` but by a dispatch stub:
```
ldurh w2,[x1,#1]        ; read the object's cid (class id)
add  x30,x0,x17,#...    ; cid + offset
ldr  x30,[x21,x30,lsl#3]; look up function ptr in dispatch table
blr  x30                ; ★ virtual dispatch
```
**Implication:** `BL <func>` xref scanning reports `callers=0` for any build/virtual method —
this is the **norm**, not evidence of dead code. To find the caller you MUST capture `lr` /
backtrace dynamically. There is no static shortcut.

## 4. Attaching & resolving libapp (late-load)

`libapp.so` loads after the Flutter engine spins up. Use a polling wrapper + **spawn mode**
(`frida -U -f`, not attach): early injection beats anti-tamper that runs at startup and
catches the first widget build. Attach-mode often fires 0 times.

```javascript
'use strict';
function log(s){ console.log('[R] ' + s); }
function waitForLibapp(cb){
  var m = Process.findModuleByName('libapp.so');
  if (m) cb(m); else {
    var iv = setInterval(function(){
      var mm = Process.findModuleByName('libapp.so');
      if(mm){ clearInterval(iv); cb(mm); }
    }, 200);
  }
}
waitForLibapp(function(libapp){
  var base = libapp.base;
  function rel(a){ try { return a.compare(base)>=0 ? 'libapp+0x'+a.sub(base).toString(16) : String(a); } catch(e){ return String(a); } }
  // ... hooks here, using base.add(0xOFFSET) ...
});
```

## 5. Techniques

### 5.1 Capture a caller: lr + backtrace (breaks the cid wall)
```javascript
Interceptor.attach(base.add(0xYOURFUNC), {
  onEnter: function(){
    log('HIT lr=' + rel(this.returnAddress));
    try {
      var bt = Thread.backtrace(this.context, Backtracer.ACCURATE).slice(0,20);
      bt.forEach(function(a){ log('  bt ' + rel(a)); });
    } catch(e){ log('bt err ' + e); }
  }
});
```
**Interpretation:** frames like `"while rebuilding dirty elements"` are Flutter framework
render path — the app-layer builder has already returned. A single backtrace locates the
dispatch site but not the guard; for the guard use 5.3/5.4.

### 5.2 Capture the widget's cid (then find its constructor statically)
```javascript
Interceptor.attach(base.add(0xYOURFUNC), {
  onEnter: function(){
    var cid = this.context.x0.toInt32() & 0xffff;       // stub passes cid in x0
    var obj = this.context.x1;                            // widget object
    var cidField = obj.add(1).readU16();                  // fallback: cid at field@1
    console.log('[CID] x0=0x'+cid.toString(16)+' field@1=0x'+cidField.toString(16));
  }
});
```
Then statically search `movk xR,#<cid>,lsl#16` → constructor → its `bl` caller = parent build.

### 5.3 Stalker — find the PC that reads a field during rebuild (locate the guard)
Once you know the gating field (e.g. `singleton+0x20`), Stalker finds the exact instruction
reading it:
```javascript
Interceptor.attach(base.add(0xWIDGET_BUILD), {
  onEnter: function(){
    var tid = Process.getCurrentThreadId();
    Stalker.follow(tid, {
      events:{exec:false,call:false,ret:false,block:false,compile:false},
      transform: function(iterator){
        var inst;
        while ((inst = iterator.next()) !== null){
          var s = inst.toString();
          if (s.indexOf('ldr')===0 && s.indexOf('#0x20')!==-1 && s.indexOf('[x')!==-1){
            iterator.putCallout(function(ctx){
              console.log('[GUARD-PC] ldr..,#0x20 @ libapp+0x'+ctx.pc.sub(base).toString(16));
            });
          }
          iterator.keep();
        }
      }
    });
  }
});
```
**The first matching PC = the guard.**

### 5.4 MemoryAccessMonitor — cleaner when you have a precise field address
```javascript
MemoryAccessMonitor.enable(fieldAddr, 64, {
  onAccess: function(details){
    console.log('[GUARD] op='+details.operation+' from=libapp+0x'+details.from.sub(base).toString(16));
  }
});
// trigger a rebuild in-app; when the guard reads the field, onAccess fires → guard's PC
```
(arm64 support varies; fall back to Stalker or a candidate-hook sweep if unsupported.)

### 5.5 Scan an object for bool fields (crack the bool format)
The bool format is cracked by **instruction frequency**: `add xR,x22,#0x30` appears ~thousands
of times (True), `add xR,x22,#0x20` similarly (False) → True = `null+0x30` (`…8071`),
False = `null+0x20` (`…8061`). Then scan a singleton:
```javascript
var sing = this.context.x26.add(0x80).readPointer();   // Thread[x26+0x80]
var b = sing.readByteArray(0x2800); var a = new Uint8Array(b);
for (var i=0; i+8<=a.length; i+=8){
  var lo = a[i] | (a[i+1]<<8);
  if (lo === 0x8071)      console.log('  [TRUE]  sing+0x'+i.toString(16));
  else if (lo === 0x8061) console.log('  [FALSE] sing+0x'+i.toString(16));
}
```

### 5.6 Runtime memory flip — validate before committing a static patch
```javascript
sing.add(0x20).writePointer(ptr('0xffeb00008061'));   // flip True→False live
// trigger rebuild; if the widget stops building, you've confirmed the gate field
```
**Why it matters:** flipping live confirms the field is the gate *without* rebuilding the APK.
Only after confirmation spend effort on the static patch.

## 6. Guard → on-disk patch conversion (the payoff)

Once you have the guard PC, read its disasm and patch the conditional branch:
```
ldr x1,[sing,#0x20]   ; read the bool
...                    ; (a later ldur may reload it from stack — patch THAT one)
tbz w0,#4,<skip>      ; GUARD: bit4=0(False)→skip insert; bit4=1(True)→insert
```
**Two traps:**
1. **`movz w0,#0` → SIGILL.** Dart False ≠ 0. Materialize a real Dart False: `add x0,x22,#0x20`
   → `c0820091`.
2. **Stack-reload:** patch the instruction feeding the branch's register, not an earlier load
   the shadow stack overwrites.

**Shared-function warning:** a naive unconditional `b` over a guard whose callee is *shared*
(multiple overlay callers) → **white screen**. Verify the guard's target isn't shared before
wholesale NOP. See [09-pitfalls.md](09-pitfalls.md) A1.

## 7. Anti-tamper: spawn early-injection

Integrity checks run at startup (~7s). Attach-mode hooks arm *after* checks complete → 0 hits.
**Spawn mode (`frida -U -f`):** early-inject and force-pass the known fail-branches
(`CMP W0,W22; B.EQ fail` → NOP). On-disk equivalents: NOP the aggregate fail-branches, or
entry-null the dialog-constructor helpers. See [04-signature-integrity.md](04-signature-integrity.md).

---

### Generic Frida playbook for Flutter APKs

1. **Environment first** — native ARM only (real device or ARM redroid). Verify
   `findModuleByName('libapp.so')` resolves & `Process.arch == arm64`.
2. **Decode the ABI** (§2); crack bools by instruction frequency.
3. **Resolve libapp late-load** with `waitForLibapp`; use **spawn mode**.
4. **Callers=0 → don't trust static xref** — capture `lr`+backtrace dynamically (§5.1).
5. **Find a widget's gating field** via same-day diff + bool-scan + brute-force flip (§5.5/5.6).
6. **Find the guard** via Stalker / MemoryAccessMonitor / candidate-hook sweep (§5.3/5.4).
7. **Convert guard → on-disk patch** with a *real* Dart False; patch the branch-feeding insn.
8. **Validate live first** (Memory.protect+writeByteArray) before baking into the APK.
