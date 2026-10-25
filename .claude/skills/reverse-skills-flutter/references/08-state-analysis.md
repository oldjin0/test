# 08 — Business-Logic State-Chain Analysis & Round Methodology

> How to recover a feature's logic (VIP, reward, daily-feed, login, network) from a
> **symbol-less** Dart AOT binary with ~21,000 functions — purely statically, over many
> disciplined iterations. The object pool IS your symbol table.

## Table of contents
1. Core insight: the object pool is the symbol table
2. The canonical Dart boolean idiom
3. State-chain tracing recipe (9 steps)
4. Function-feature triage at scale (~21k functions)
5. Cross-validation & convergence discipline
6. The round-report structure
7. Anti-patterns

---

## 1. Core insight: the object pool is the symbol table

In Dart AOT, constants/strings load via `LDR Xn,[X27,#off]` (X27 = pool base). Once you build
**pool offset → ref ID → string content**, every `LDR` in a chain is identifiable and the
symbol-less binary becomes readable. Build with `scripts/deserialize_pool.py` +
`scripts/pool_xref.py`.

The key primitive: `pool_offset → {PCs that load it} → {owning function starts}`. "Which
functions touch string ref N?" becomes answerable — a symbol substitute.

## 2. The canonical Dart boolean idiom

A Dart `bool` is consumed via `tbz`/`tbnz w0, #4`: **bit #4 set = canonical true; clear = false**.
A clean gate: `tbz w0, #4, #<false_epilogue>` then a true epilogue.

**Inferring an unknown compare-helper's polarity:** given `bl <unknown_cmp>` then
`tbnz w0,#4,#target` inside a sequential type-dispatcher, infer by contradiction —
"equal-means-jump" would skip the matching handler (self-contradictory), so it must be
"not-equal-means-jump". Derive semantics from control-flow context when symbols are absent.

## 3. State-chain tracing recipe (9 steps)

1. **Anchor on string refs** — use the pool to pin the feature's entry functions.
2. **Scan all direct BL callers of the success-sink** — 3+ callers ⇒ *shared* sink, not a single helper.
3. **Enumerate every state writer for each `[G+offset]`** — a bit is "permanent" only if no
   false-writer exists; one false-writer reclassifies it as **mutable daily-state**.
4. **Pin field semantics via the cache-loader, not inference** — match the global offset back
   to its pool key name. (Kills speculative meanings.)
5. **Separate write-side from read-side** explicitly — never assume they're the same layer.
6. **Distinguish "same subsystem" from "same direct gate"** — multiple UI entries feeding one
   shared bridge = shared state, *not* a shared builder.
7. **Demote cache-refresh layers** that "read self, write self" with a null-fallback — they're
   SharedPreferences-style, not field translators.
8. **Reconcile against independent analyses by evidence class** (runtime > static > hypothesis).
9. **When the read-side gate sits behind an indirect pool-call wall static can't resolve,
   switch objective** — pursue a user-acceptable result rather than keep guessing.

**State-read function signature:** pinned by embedded persistence/expiry strings
(`adNum`/`lastTime`/`today`/`totalNum`, expiry text). Walk up: state-fn → bool-gate (`tbz w0,#4`)
→ UI wrapper. **Patch the narrowest gate, not the shared state-fn.**

## 4. Function-feature triage at scale (~21k functions, no symbols)

Recover function boundaries by **backwards-scanning for the prologue bytes** `fd 79 bf a9
fd 03 0f aa` (window ~0x6000–0x8000 bytes). Then a per-function feature vector:

1. **String-set accessed** (dominant signal) — bag of strings loaded via pool offsets.
2. **BL targets / callers (fan-in)** — decode BL `(word>>26)==0b100101`, sign-extend imm26.
3. **Branch-after-gate sites** — `TBZ/TBNZ/B.EQ` following a known gate call (the decision byte).
4. **Null-gate compares** — `CMP W0,W22` / `MOV X0,X22`.
5. **bool-return flag**.

**The four rankers** (21k → shortlist):
- **A — keyword string shortlist:** `kw in s and len(s) < 60`; project to owning functions.
- **B — co-accession count** (workhorse): per function, count keyword-class strings accessed;
  threshold `>= 2` flags an orchestrator. 21k → a few hundred.
- **C — set-intersection of two anchors** (precision pin): when a title + its body string are
  both known, intersect each string's accessor-function set → the exact builder (0 or 1 fn).
- **D — BL-caller fan-in:** for a confirmed gate, find every BL to it; iterate upward.

`scripts/function_triage.py` implements A and B; the aggregator score surfaces integrity gates.

> **Caller count = risk metric:** high count (e.g. 17/41) = shared state-fn → *avoid* as patch
> point; count of 1 = dedicated handler → safe target.

## 5. Cross-validation & convergence discipline

- **Runtime evidence > static optimism.** A static candidate that fails on-device is demoted
  **with stated evidence**, never silently dropped.
- **Reconcile by evidence class**, not authority: accept only byte-level/pool-verifiable facts;
  downgrade certainty-framed claims lacking object/runtime evidence.
- **Name every dead-end** with its reason → the search is auditable and **non-repeating**.
- **Convergence by elimination:** a round that "fails" still kills a hypothesis class, narrowing
  the space until the only high-value move is to switch objective.
- **Standard relaxation under evidence:** redefine success ("invisible + unclickable = gone")
  rather than over-claim — state your standard; relax it *with evidence*.

## 6. The round-report structure

Every iteration is a self-contained, auditable unit. Use the template in
[assets/round-report-template.md](../assets/round-report-template.md). The non-negotiable
sections: **self-correction (before new claims)** and the **withdrawn list** (prevents
re-testing known-bad). Conclusion-first; one-sentence verdict last. Two-tier / mutually-exclusive
deliverable packages (e.g. "stable run" vs "retain reward") when patches logically preclude each other.

## 7. Anti-patterns (what NOT to do)

1. Don't trust decoded offsets blindly — recompute (`target = pc + signed_relative_offset` for BL).
2. Don't patch a shared state-fn as if it were a gate (caller count > ~10 ⇒ high blast radius).
3. Don't entry-`return null` a "whole-page assembler" or mixed state machine — only single-purpose gates.
4. Don't assume write-side == read-side; don't assume "same subsystem == same gate".
5. Don't pin field semantics by inference — match the offset to its pool key name.
6. Don't write certainty into a claim lacking object/runtime evidence — downgrade it.
7. Don't silently drop a failed hypothesis — name it, date it, reason it.
8. Don't keep expanding the toolchain past the breakthrough — freeze tools, pour effort into verification.
