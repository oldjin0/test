package com.oldjin.meetnote

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

data class Line(val sec: Int, val speaker: String, val text: String)

enum class Phase { Idle, Recording, Processing, Done }

data class LiveState(
    val phase: Phase = Phase.Idle,
    val sessionId: String? = null,
    val elapsedSec: Int = 0,
    val level: Float = 0f,
    val lines: List<Line> = emptyList(),
    val pending: Int = 0,
    val failed: Int = 0,
    val status: String = "",
    val warning: String? = null,
)

/** 서비스와 UI가 공유하는 실시간 상태. */
object Live {
    val state = MutableStateFlow(LiveState())
    fun update(f: (LiveState) -> LiveState) = state.update(f)
    val busy get() = state.value.phase == Phase.Recording || state.value.phase == Phase.Processing
}

fun fmtTime(sec: Int): String {
    val h = sec / 3600
    val m = sec % 3600 / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}
