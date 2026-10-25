# Round Report Template (the iteration unit)

> Every round is a self-contained, auditable unit that narrows the hypothesis space. Wrong
> turns are *named and dated*, not silently dropped — this is what lets round 34 build on
> round 1 without re-walking dead ends. Conclusion-first; self-correcting; dead-end-naming.

```markdown
# 第N轮 <feature> 代码恢复报告

> 分支：<branch>
> 角色：<pure-static | runtime-confirm | db-build> — 本轮单一目标：<one sentence>

## 1. 本轮结论 (conclusion FIRST)
<the single most important finding, before any evidence>

## 2. 本轮关键纠偏 / 方向修正 (self-correction BEFORE new claims)
- 撤回 <prior claim> —— 原因：<evidence/runtime fact>
- 降级 <prior patch> —— 原因：<why>
（来源：<which branch's evidence>）

## 3. 已验证锚点 / 交叉验证后的共识 (stable baseline)
- <fact A> —— 验证方式：<byte-level | pool-ref | runtime>
- <fact B> —— 来源：<test1 local | test3 db | main runtime>

## 4. 候选分析 + 反汇编证据 (per candidate)
### 4.x <candidate address>
- 交叉验证：<matches/diverges from other branch>
- 反汇编证据：<disasm snippet + pool-slot loads>
- 字符串锚点：<embedded strings>
- 结论：<verdict>
- Patch候选：<address → epilogue> （tier: 根因/兜底/实验）

## 5. 状态链追踪 (if applicable)
- 写入侧 writers：<addr → [G+offset]> (枚举所有 writer)
- 读取侧 reader：<addr reads [G+offset]>
- 字段语义：<offset → pool key name> (用 cache-loader 钉死，勿推断)
- 门控：<tbz w0,#4,<false_tail> — bit4=true>
- 同子系统 vs 同 gate：<distinguish explicitly>

## 6. Patch 三层清单 (triaged, ORDERED)
| 地址 | 改法 | tier | 风险 | 来源 |
- 根因方案：<ordered list>
- 高置信兜底：<ordered list>
- 实验项：<labelled with risk>
- 互斥方案包：<方案A stable / 方案B retain-reward — state mutual-exclusivity>

## 7. 本轮未完成项 (NOT solved — precise blocker)
- <item> —— 阻塞点：<exact reason, e.g. "read-side gate behind indirect pool-call wall">

## 8. 交叉验证与修正 (cross-branch)
- 与 <branch> 一致：<items>
- 与 <branch> 分歧：<items>
- 来自 runtime 的硬事实：<items — outrank static optimism>

## 9. 不再推荐 (withdrawn list — prevents re-testing known-bad)
- <patch> —— 撤回于第M轮，原因：<evidence>

## 10. 下一轮 (next-step handed forward)
<the ONE precise next move, so the next round starts from here>

## N. 一句话结论 (one-sentence verdict)
```

## Usage rules

- **Sections 2 (self-correction) and 9 (withdrawn list) are non-negotiable** — they make the
  search auditable and non-repeating.
- Section 1 leads; Section N distills. The middle is evidence.
- Every address, every patch, every claim carries a **source** and a **tier** (根因/兜底/实验).
- "未完成项" must name the *precise blocker*, never a vague TODO.
- When patches logically preclude each other (you can't both kill a feature and keep its reward
  path), present **mutually-exclusive goal-driven packages** and state the exclusivity.
- **Runtime evidence always outranks static optimism.** A candidate that looks right on paper
  but fails on-device is demoted *with stated evidence*, never silently dropped.
- **Convergence is by elimination:** a round that "fails" still kills a hypothesis class — record it.
