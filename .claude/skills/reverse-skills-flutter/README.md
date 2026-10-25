# reverse-skills

A Claude Code **Agent Skill** for reverse-engineering Android APKs — with deep
specialization in **Flutter / Dart AOT** apps (`libapp.so` + `libflutter.so`).

It condenses a real, hard-won reverse-engineering campaign (the `ppcat` project: a
custom-engine, 360-jiagu-packed Flutter app, 173 commits across 5 branches, built with
multi-model collaboration) into a **download-and-use** methodology toolkit: playbooks,
reusable Python scripts, and copy-paste templates.

---

## What's inside

```
reverse-skills/
├── SKILL.md              # Router + overview + master decision tree (start here)
├── references/           # 11 deep-dive docs (load on demand)
│   ├── 01-flutter-dart-aot.md      blutter, ELF layout, pool deserialization, strings, xref bridge
│   ├── 02-arm64-patching.md         entry-null / NOP / branch-flip patterns, patch-config, repack
│   ├── 03-frida-dynamic.md          houdini trap, redroid, cid wall, backtrace, Stalker, bool format
│   ├── 04-signature-integrity.md    signature chain, PmsHook, Android-14 fix, LSPatch
│   ├── 05-packers.md                360 jiagu, why repack black-screens, 3 delivery paths
│   ├── 06-environments.md           LDPlayer vs redroid vs physical ARM decision tree
│   ├── 07-ui-dialogs-ads.md         dialog-source triage, aggregation hunting, ad removal
│   ├── 08-state-analysis.md         state-chain tracing, function triage, round methodology
│   ├── 09-pitfalls.md               the full dead-end catalog (most valuable section)
│   ├── 10-collaboration.md          controller→analyst workflow, handoff/task templates, neutral phrasing
│   └── tool-catalog.md              every tool + install command + MCP servers
├── scripts/              # Generic, portable Python (pass your libapp.so / apk)
│   ├── analyze_apk.py              # entry point — detect symbols, version, strings
│   ├── find_strings.py             # UTF-8 + UTF-16LE string finder
│   ├── disasm_functions.py         # capstone disasm + function table + call graph
│   ├── deserialize_pool.py         # generic Dart object-pool deserializer
│   ├── pool_xref.py                # pool-slot → PC → function cross-reference
│   ├── function_triage.py          # rank functions by feature vector (find gates/aggregators)
│   ├── patch_libapp.py             # apply named patch configs with safe primitives
│   ├── verify_bytes.py             # byte-verify patches inside an APK's libapp
│   └── README.md
└── assets/               # Copy-paste templates
    ├── handoff-template.md
    ├── task-dispatch-template.md
    └── round-report-template.md
```

## Install

### Option A — Personal skill (recommended)

```bash
git clone https://github.com/inliver233/reverse-skills.git ~/.claude/skills/reverse-skills
```

Claude Code auto-detects it. Then ask for it naturally:

> "I have a Flutter APK at ~/Downloads/app.apk. Help me reverse-engineer how its
> anti-tamper dialog works."

Claude will pick up the `reverse-skills` skill from the description and guide you.

### Option B — Project skill

```bash
git clone https://github.com/inliver233/reverse-skills.git .claude/skills/reverse-skills
```

Commit `.claude/skills/` to share it with everyone on the repo.

### Tool dependencies (optional but recommended)

```bash
python3 -m pip install capstone pyelftools    # the scripts' disasm + ELF parsing
# Plus the standard Android RE toolchain as needed:
#   apktool, jadx, frida-tools, adb  (see references/tool-catalog.md)
```

Scripts **degrade gracefully** — if `capstone`/`pyelftools` aren't installed, they tell
you and fall back to stdlib-only behavior where possible.

## What this skill is good at

- **Flutter / Dart AOT** apps — the hard case. blutter, object-pool deserialization,
  string→function mapping, ARM64 patching of `libapp.so`.
- **Custom/patched Flutter engines** where blutter fails — the manual pool-parse +
  capstone fallback path.
- **Defeating the "tamper detected" / integrity dialogs** that protected Flutter apps show.
- **Removing ad / reward UI** and understanding the ad-SDK channel architecture.
- **Packer (360 jiagu)** handling — knowing when *not* to repack.
- **Dynamic analysis with Frida** — and knowing why houdini emulators are a dead end.
- **Multi-model collaboration** — handing off a long RE task across sessions/agents.

## How the skill was built

The source project (`ppcat`) ran for 4 intense days (June 2026) with a human controller
dispatching tasks to independent analyst agents across 5 git branches, plus Codex. It
targeted a **real** custom-engine Flutter app and hit genuine structural ceilings (shared
render functions, cid-typed widget returns, check-coupled state flags). The campaign's
**failures are its most valuable output** — they're catalogued in
[references/09-pitfalls.md](references/09-pitfalls.md) so you don't repeat them.

## License

MIT — see [LICENSE](LICENSE).
