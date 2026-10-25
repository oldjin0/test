# 09 — Pitfalls, Dead-Ends & Anti-Patterns

> **The most valuable section in this skill.** The source campaign ultimately hit a structural
> ceiling; its failures are the asset. Each entry: Symptom → Root Cause → Correct Approach →
> Rule. Read this before you start; re-read it when you're stuck.

> **The one rule that prevents most failures:** *Before acting on any analysis result, name
> the precondition it assumes and verify it holds for THIS target.* A function looked
> single-purpose but was shared; a value looked like a widget but was a string; `0` looked
> like `false` but was an illegal tag; a 0-xref looked dead but was cid-dispatched; an
> emulator looked like success but was packer-lenient.

## Group A — Patching traps

### A1. Shared-guard white-screen
- **Symptom:** patching a guard condition makes the target vanish but renders the **whole page blank**.
- **Cause:** the guard lives in a **shared** function (multiple overlay callers). Forcing the
  condition kills every overlay.
- **Fix:** prove the target isn't shared before condition-flipping; target a dedicated insert point.
- **Rule:** a function with >1 overlay caller is load-bearing for rendering — never patch its branch.

### A2. Stack-reload (patched the wrong instruction)
- **Symptom:** patch has "no effect" but no crash.
- **Cause:** a later `ldur x0,[x29,#-8]` reloads the original value from the shadow stack; the
  branch consumes the reloaded value, not your patched register.
- **Fix:** patch the **last writer of the branch's source register before the conditional branch**.
- **Rule:** patch at the point of consumption, not first load — the shadow stack (X15) may overwrite.

### A3. `movz w0,#0` → SIGILL (Dart False ≠ 0)
- **Symptom:** materializing false as `movz w0,#0` (`52800000`) crashes with signal 4.
- **Cause:** a Dart bool is a **tagged pointer to a canonical object**, not 0. True = `null+0x30`;
  False = `null+0x20`.
- **Fix:** emit `add xR,x22,#0x20` (`c0820091`).
- **Rule:** in Dart AOT, "false" is `add xR,x22,#0x20`, never `movz w0,#0`.

### A4. Unverified pool-slot (SizedBox) → SIGSEGV
- **Symptom:** returning pool slot "SizedBox.shrink" crashes.
- **Cause:** the slot was a **String** (the label `"SizedBox.shrink"`), not a Widget instance.
- **Fix:** to remove a widget, `return null` (entry-stub), not a guessed slot.
- **Rule:** never substitute a pool slot as an "empty widget" without deserializing it first.

### A5. Entry-return-null on async/ad state machine
- **Symptom:** nulling an ad/async function's entry breaks splash close or piles up dialogs.
- **Cause:** it's a Future/callback state machine; nulling starves the graph of expected returns.
- **Fix:** NOP the **leaf dialog-show BL sites**, keep the entry intact.
- **Rule:** for async/state machines, NOP leaf call sites, never the entry.

### A6. Per-function NOP safety
- **Symptom:** the BL-NOP that worked for one function breaks another (splash stuck).
- **Cause:** "safe to NOP" is **per-function**, not per-technique — splash/launch entanglement varies.
- **Fix:** treat each function independently; re-verify on device (esp. that splash still closes).
- **Rule:** verify per-function; never generalize a NOP's safety across functions.

### A7. Shared state-flag (isHungry) trap
- **Symptom:** flipping a display bool hides the widget **but triggers the integrity check**, and
  can't become a static patch.
- **Cause:** the flag is **dual-purpose** (display gate + anti-tamper signal).
- **Fix:** don't attack the shared flag; move to the **render layer** (opacity/off-screen/null child).
- **Rule:** runtime success on a check-coupled flag doesn't license a static patch; prefer render-transform.

## Group B — Verification & environment traps (false results)

### B1. versionCode trap
- **Symptom:** false "patch didn't work."
- **Cause:** `install -r` with unchanged versionCode doesn't replace `libapp.so`.
- **Fix:** bump versionCode every rebuild; clear apktool build cache; byte-verify on disk.
- **Rule:** no versionCode bump = no libapp replacement.

### B2. Emulator false-positive (packer leniency)
- **Symptom:** works on LDPlayer, black-screens on the real device.
- **Cause:** packer degrades on the emulator (houdini loosens its checks).
- **Fix:** validate on real hardware; recognize `libjiagu*.so` as a red flag for repack.
- **Rule:** packer leniency fabricates success — real-device black after LDPlayer green = repack-damaged shell.

### B3. Houdini dynamic trap
- **Symptom:** gadget loads/listens, memory readable, but hooks fire 0×, patches ignored.
- **Cause:** cached ARM→x86 translation.
- **Fix:** all execution-dependent work on native ARM; under houdini, read-only memory only.
- **Rule:** under houdini, hooks/patches are silently dead — use native ARM.

### B4. Screen-off / screenshot-size trap
- **Symptom:** "blank" ~30KB screenshot when the app is fine — the screen was asleep.
- **Fix:** `svc power stayon true` + wake before capture; judge by screenshot byte-size
  (~10–35KB = broken, ≥200KB = rendering).
- **Rule:** lock the screen awake; size-threshold screenshots.

## Group C — Static-analysis misdiagnoses

### C1. "0 direct BL callers" trap (cid virtual dispatch)
- **Symptom:** full scan reports 0 callers → concluded dead.
- **Cause:** build/virtual methods are invoked via cid dispatch stubs, not BL. "Callers=0" is normal.
- **Fix:** find callers via dynamic backtrace, never BL xref.
- **Rule:** zero BL callers on a virtual method = "cid-dispatched," not "dead."

### C2. cid-strict-return trap (can't change a builder's return)
- **Symptom:** nulling/changing a builder's return → blank page or crash.
- **Cause:** the return slot is cid-typed; any other cid type-mismatches.
- **Fix:** don't change returns; attack the upstream guard or apply a render-layer transform.
- **Rule:** a widget builder's return slot is cid-locked — suppress insertion upstream instead.

### C3. cid84 / blutter-is-dead trap
- **Symptom:** blutter compiles but produces zero output; "No cluster defined for cid N".
- **Cause:** custom engine with a drifted cid table / non-standard cluster encoding.
- **Fix:** abandon blutter; recover via dynamic (frida) or manual pool deserialization.
- **Rule:** blutter is dead for custom/drifted VMs — if cid≠expected or features mismatch, switch path.

### C4. "Single popup source" trap (third orchestrator)
- **Symptom:** NOP-ing known orchestrators only delays a recurring popup.
- **Cause:** the body builder is reached by more (pool-indirect) orchestrators than static found.
- **Fix:** address at the source (Java-stub the failing channel) rather than chasing Dart call sites.
- **Rule:** static NOP can't enumerate all pool-indirect callers — stub the source.

### C5. Anchor-by-string-presence misdiagnosis
- **Symptom:** declared "found it" on a function that loaded the right strings but wasn't the orchestrator.
- **Cause:** many utility functions load feature strings; string-presence ≠ ownership.
- **Fix:** prove an anchor by patch-and-test nullification — the real orchestrator's null must break the page.
- **Rule:** "loads the string" ≠ "is the orchestrator" — confirm by destructive verification.

### C6. "Singleton has no bool" misdiagnosis
- **Symptom:** concluded a state singleton had no bool fields → hunted a timestamp instead.
- **Cause:** filtered True-pointers as ordinary references (Dart bool = tagged pointer).
- **Fix:** scan for fields equal to canonical True/False addresses; key by instruction frequency.
- **Rule:** a Dart singleton bool is a tagged pointer (…8071/…8061), not an int.

### C7. scan_slot blind-spot
- **Symptom:** the byte-pattern scanner misses some string loaders.
- **Cause:** it only matches the standard 5-insn ADD+LDR pattern; some loads use non-standard encodings.
- **Fix:** calibrate on a known anchor; cross-verify negatives with a second method.
- **Rule:** "scanner finds nothing" ≠ "no loader" — calibrate + cross-verify.

## Group D — Meta-lessons (when to stop)

### D1. "Three direct roads all dead"
When three structurally-distinct direct roads each fail (guard patch→white-screen;
builder-return→cid-crash; runtime-flip→can't-go-static), **stop re-trying them** — they're
blocked by Dart-AOT invariants (shared functions, cid-typed returns, dual-purpose flags).
Accept the static-only outcome, switch environment/abstraction, or move to the render layer.

### D2. "Wrong weapon for the runtime" (the master trap)
Every tool has a hard precondition it silently violates (stock VM, native ARM, unpacked APK,
awake screen, direct-call). Failures were **quiet** — the tool returned empty/lenient/no-op
rather than erroring. **Before trusting any tool, assert its precondition explicitly.** Treat
any silent/empty result as suspect until verified.
