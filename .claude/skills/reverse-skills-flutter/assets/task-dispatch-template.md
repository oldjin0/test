# Task Dispatch Template (controller → one analyst agent)

> A single focused task to one analyst. The controller pre-writes the executable code; the
> analyst runs + reports ranked data. A/B/C structure with a fallback ladder so the analyst
> never has to ask "what if A fails?"

```markdown
# 主控 → <ANALYST>: <ONE-LINE OBJECTIVE> + <METHOD>

> 承 <ANALYST> `<commit-hash>`. <1-2 sentence ack of what was received>.
> Below is <new clue> + your <task>. 中性措辞 "代码恢复".

## 一、主控静态新发现 / 主控解读
<New info the controller found that the analyst can't see — a static address, a decoded field
name, a corrected assumption. The controller's contribution; the analyst contributes the
capability.>

## 二、★ 给 <ANALYST> 的 task：<objective>
### 任务A（最快验证）：<method A — with ready-to-paste frida/JS or script code>
### 任务B（定位 <X>）：<method B, fallback>
### 兜底（任务C）：<simplest confirmation if A/B inconclusive>
<Each task ships WORKING CODE the analyst can paste — the controller pre-writes the hook/script
so the analyst just runs it and reports numbers.>

## 三、主控侧已确认 / 已排除（固化给你）
✅ 已确认: <numbered frozen facts>
❌ 已排除: <numbered dead-ends — do NOT re-try>

## 四、最小回传（按优先级）
1. <highest-value single data point — e.g. "the cid value">
2. <next>
3. <next>
> 一句话：<dense summary of the decision tree — do A, if no result do B, lock → I produce the
> final on-disk patch>.
```

**What makes it work:**
- **A/B/C with a fallback ladder** — conditional next-steps; the analyst never asks "what if A fails".
- **Controller pre-writes the executable code** — every dispatch ships a complete frida snippet or
  script invocation. The analyst's job is "run this, report numbers," not "design the experiment."
- **"最小回传 (ranked minimum return)"** — rank what to report so you get 1–3 data points, not a dump.
  The #1 item is always the single datum that lets the controller close the loop.
- **"一句话" closing line** restates the full decision tree compactly.
- **References a frozen-fact + ruled-out list** so the analyst doesn't re-investigate settled questions.

## Controller-feedback variant (when install-test FALSIFIES a hypothesis)

```markdown
# 主控紧急反馈: <X> 不是 <analyst's claim>（第N次误判）
<Analyst said H>. 主控装机 <precise install-test>:
  <observed: entered page, X shown, Y not shown, no crash>.
→ <H> 【不是】<claim>. <precise method> 验证.
→ <Analyst>'s <anchor> 错误（继 <previous error> 后第N次误判）.
求三方: <the corrected objective>.
方法建议: <concrete method to find the TRUE target>.
```

**Discipline:** an analyst hypothesis is only "confirmed" after the controller's install-test
reproduces it. Until then it is a candidate. The feedback names the falsification, names it as a
repeated-error pattern, and redirects all branches.
