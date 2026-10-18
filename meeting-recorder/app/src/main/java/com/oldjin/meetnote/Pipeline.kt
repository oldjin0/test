package com.oldjin.meetnote

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import java.io.File

/** 진행 중인 사후 분석(텍스트 변환·요약) 상태. key = 세션 id. */
object Analysis {
    val status = MutableStateFlow<Map<String, String>>(emptyMap())
    val warnings = MutableStateFlow<Map<String, String>>(emptyMap())

    fun set(id: String, s: String) = status.update { it + (id to s) }
    fun finish(id: String, warning: String?) {
        status.update { it - id }
        warnings.update { if (warning.isNullOrBlank()) it - id else it + (id to warning) }
    }
}

object Pipeline {
    /**
     * 저장된 녹음(audio.wav)을 전체 화자 구분 전사 → 요약한다. 실시간 초안이 있으면 실패 시 그대로 둔다.
     * 문제가 있으면 안내 문구를, 정상이면 null 을 돌려준다. 녹음 파일은 어떤 경우에도 건드리지 않는다.
     */
    fun analyze(ctx: Context, id: String, onStatus: (String) -> Unit): String? {
        val key = Prefs.apiKey(ctx)
            ?: return "API 키가 없어 텍스트 변환을 하지 못했습니다. 설정에서 키를 등록한 뒤 이 화면에서 다시 실행하세요."
        val wav = Store.file(ctx, id, "audio.wav")
        if (!wav.exists()) return "녹음 파일이 없습니다."
        val client = GeminiClient(ctx, key, Prefs.model(ctx))
        var warning: String? = null
        var lines = Store.loadLines(ctx, id)

        onStatus("최종 화자 분석 중…")
        try {
            val full = client.transcribeFull(wav)
            if (full.isNotEmpty()) lines = full
        } catch (e: Exception) {
            warning = "텍스트 변환 실패 (${e.message?.take(120)}). 녹음은 안전하게 저장돼 있어요. 잠시 후 다시 실행해 보세요."
        }
        if (lines.isEmpty()) return warning ?: "변환된 내용이 없습니다 (음성이 감지되지 않았을 수 있어요)."
        Store.saveLines(ctx, id, lines)

        if (!Prefs.summaryOn(ctx)) return warning
        onStatus("요약 작성 중…")
        try {
            File(Store.dir(ctx, id), "summary.txt").writeText(client.summarize(Store.toText(lines)))
        } catch (e: Exception) {
            warning = (warning?.plus(" / ") ?: "") + "요약 실패 (${e.message?.take(120)}). 다시 실행하면 요약만 새로 만듭니다."
        }
        return warning
    }
}
