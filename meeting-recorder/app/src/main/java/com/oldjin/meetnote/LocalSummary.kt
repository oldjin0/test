package com.oldjin.meetnote

import android.content.Context
import kotlin.math.sqrt

/**
 * API 없이 기기에서 만드는 간이 요약.
 * 자주 나온 핵심어로 발언에 점수를 매겨 핵심 발언을 뽑고, 결정·할 일로 보이는 발언을 따로 모은다.
 */
object LocalSummary {
    private val josa = listOf(
        "에서는", "으로는", "에게서", "까지는", "부터는", "이라고", "에서", "으로", "에게", "까지", "부터",
        "처럼", "보다", "이랑", "하고", "라고", "은", "는", "이", "가", "을", "를", "에", "의", "도", "로", "와", "과", "만", "요"
    )
    private val stop = setOf(
        "그리고", "그래서", "그러니까", "그런데", "근데", "이제", "그냥", "진짜", "정말", "약간", "조금", "이렇게", "그렇게", "저렇게",
        "이런", "그런", "저런", "어떤", "우리", "저희", "제가", "내가", "여기", "거기", "지금", "오늘", "그거", "이거", "저거", "그게", "이게",
        "있는", "없는", "하는", "되는", "했는데", "하는데", "합니다", "했습니다", "있습니다", "입니다", "그렇죠", "그렇지", "아니", "네네",
        "이번", "그때", "다시", "많이", "너무", "같은", "같아요", "거예요", "건데", "때문", "때문에", "생각"
    )
    private val actionHints = listOf(
        "해야", "하기로", "까지", "부탁", "확인", "준비", "결정", "정하", "다음 주", "다음주", "마감", "진행하", "담당", "보내", "공유"
    )

    private fun norm(w: String): String? {
        var t = w.trim().trim('.', ',', '?', '!', '"', '\'', '(', ')', '…')
        for (j in josa) if (t.length > j.length + 1 && t.endsWith(j)) { t = t.dropLast(j.length); break }
        if (t.length < 2 || t in stop || t.all { it.isDigit() }) return null
        return t
    }

    private fun clip(t: String, n: Int = 110) = if (t.length > n) t.take(n).trimEnd() + "…" else t

    fun build(all: List<Line>): String? {
        val lines = all.filter { it.speaker != "!" && it.text.isNotBlank() }
        if (lines.isEmpty()) return null
        val toks = lines.map { l -> l.text.split(Regex("\\s+")).mapNotNull { norm(it) } }
        val freq = HashMap<String, Int>()
        toks.forEach { ts -> ts.forEach { freq[it] = (freq[it] ?: 0) + 1 } }
        val keywords = freq.entries.filter { it.value >= 2 }.sortedByDescending { it.value }.take(10).map { it.key }
        val kw = keywords.toSet()
        val scores = lines.indices.map { i ->
            val ts = toks[i]
            if (ts.size < 3) 0.0 else ts.sumOf { if (it in kw) freq[it]!!.toDouble() else 0.0 } / sqrt(ts.size.toDouble())
        }
        val order = lines.indices.sortedByDescending { scores[it] }
        val best = order.first()
        val top = order.filter { scores[it] > 0 }.take(5).sorted().ifEmpty { lines.indices.take(3).toList() }
        val actions = lines.filter { l -> actionHints.any { l.text.contains(it) } }.take(6)
        fun at(l: Line) = "[${fmtTime(l.sec)}] " + (if (l.speaker.isBlank()) "" else "${l.speaker}: ")

        return buildString {
            appendLine("## 한 줄 요약")
            appendLine("- " + clip(lines[best].text, 90))
            appendLine()
            appendLine("## 주요 키워드")
            appendLine("- " + keywords.ifEmpty { listOf("(충분한 내용이 없어요)") }.joinToString(" · "))
            appendLine()
            appendLine("## 핵심 발언")
            top.forEach { appendLine("- " + at(lines[it]) + clip(lines[it].text)) }
            appendLine()
            appendLine("## 결정·할 일 후보")
            if (actions.isEmpty()) appendLine("- 없음") else actions.forEach { appendLine("- " + at(it) + clip(it.text)) }
            appendLine()
            appendLine("_기기에서 만든 간이 요약입니다. 중요한 회의는 'AI 정밀 분석'으로 다시 요청하세요._")
        }
    }

    fun write(ctx: Context, id: String): Boolean {
        val s = build(Store.loadLines(ctx, id)) ?: return false
        Store.file(ctx, id, "summary.txt").writeText(s)
        return true
    }
}
