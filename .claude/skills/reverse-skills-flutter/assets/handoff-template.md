# Handoff Prompt Template (new conversation / new agent — cold start)

> Copy into the target project and fill in. A new agent/session reading ONLY this file should
> be able to take over with full context. State lives here, not in chat history.

```markdown
# Handoff — <APP> (<DATE>) — 必读

> <APP> compatibility-adaptation & code-recovery project. This file is the complete handoff;
> read it and you know the task. Full reports are in <repo url> branch <branch>.
> **全程中性措辞：代码恢复、兼容性修复、功能研究、适配。** (neutral terms only)

## 一、项目目标
<What the project produces, in neutral terms. Current focus = 1–2 unsolved items only.>

## 二、当前操作现场（★最重要，新对话接手先看这）
### 设备 / 环境
- <device, arch, OS, root status, adb serial, exact tool paths (apktool/signer/frida/python)>
- **操作要点（之前踩过大坑）**: <non-obvious gotcha + its failure-mode, e.g. "screen-off →
  misjudged screenshot; judge by size: ~10-35KB broken, ≥200KB rendering">
### 当前装在上面的版本 + 症状
- <exact apk filename, versionCode, contents> → <current symptom, precisely stated>
### 本地关键文件
- <every file path that matters, with its one-line role; sha256 if it's a baseline>
- <git repo location + branch list>

## 三-七、已查清的事实（按子目标分节）
每个子目标：根因（已完全查清）/ 已做修复 / 当前卡点 / 待解决.
Include: address tables, calling-convention notes, byte-level verified offsets.

### ✅ 已确认（frozen — do not re-litigate）
1. <fact> — verified by <byte-level | pool-ref | runtime>
2. ...

### ❌ 已排除 / 死路（do NOT re-try — each cost real time）
1. <approach> — fails because <reason>
2. ...

## 八、调用约定 / 工具
- ABI: Dart AOT arm64 — X15=shadow-stack, X26=Thread, X27=Pool(PP), X22=null, X28=heap base;
  pool slot_offset = idx × 8; bool True=null+0x30, False=null+0x20.
- <toolchain specifics>

## 九、新对话接手第一步建议
1. <THE single highest-leverage diagnosis>
2. ...
3. ...

## 十、一句话现状
<root-cause = X (status) | remaining blocker = Y | next step = Z>

---

# 起手提示词（copy into a fresh chat）
> I'm continuing <APP> compatibility/code-recovery work. Device: <X>. Core blocker: <Y>.
> First read the full handoff at <path/handoff.md>, then start with step 九.1.
> Neutral terms only (代码恢复/兼容性/功能研究).
```

**What makes it work (non-obvious parts):**
- Section 二 (operation site) is marked ★最重要 and comes BEFORE the facts — a cold agent needs
  device/paths/symptom first or the facts are unactionable.
- Gotchas are named with their **failure-mode**, not as advice.
- The **❌ ruled-out list is mandatory** — killing a dead-end is a deliverable equal to a solution.
- A **paste-ready bootstrap prompt** is appended so the human can start a fresh chat fast.
- The **one-sentence state** forces convergence: if you can't state root-cause + blocker + next-step
  in one sentence, the handoff isn't ready.
