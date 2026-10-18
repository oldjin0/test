package com.oldjin.meetnote

import android.content.Context
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import java.io.IOException
import java.io.RandomAccessFile
import kotlin.math.sqrt

/**
 * 녹음 후 기기 안에서 Whisper로 다시 받아쓴다 (무료·오프라인, 대신 느림).
 * Whisper는 30초 단위로만 처리하므로 조용한 지점에서 28초 이하로 잘라 순서대로 변환한다.
 */
object LocalWhisper {
    private const val MAX_SEC = 28
    private const val MIN_SEC = 18

    fun transcribe(ctx: Context, id: String, onProgress: (Int) -> Unit): List<Line> {
        val model = LocalModels.bestWhisper(ctx) ?: throw IOException("Whisper 모델이 설치되지 않았어요 (설정에서 설치)")
        val d = LocalModels.dir(ctx, model)
        val enc = LocalModels.find(d) { it.endsWith("encoder.int8.onnx") } ?: LocalModels.find(d) { it.endsWith("encoder.onnx") }
        val dec = LocalModels.find(d) { it.endsWith("decoder.int8.onnx") } ?: LocalModels.find(d) { it.endsWith("decoder.onnx") }
        val tok = LocalModels.find(d) { it.endsWith("tokens.txt") }
        if (enc == null || dec == null || tok == null) throw IOException("Whisper 모델 파일이 부족해요. 다시 설치해 주세요.")
        val wav = Store.file(ctx, id, "audio.wav")
        if (!wav.exists()) throw IOException("녹음 파일이 없어요")

        val cfg = OfflineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = enc.path, decoder = dec.path,
                    language = Prefs.lang(ctx).substringBefore('-').ifBlank { "ko" }, task = "transcribe",
                ),
                tokens = tok.path,
                numThreads = Runtime.getRuntime().availableProcessors().coerceIn(2, 4),
                modelType = "whisper",
            ),
        )
        val rec = OfflineRecognizer(null, cfg)
        val lines = mutableListOf<Line>()
        try {
            RandomAccessFile(wav, "r").use { f ->
                val dataStart = 44L
                val totalSamples = ((f.length() - dataStart) / 2).toInt()
                var pos = 0
                while (pos < totalSamples) {
                    val want = minOf(MAX_SEC * SAMPLE_RATE, totalSamples - pos)
                    val bytes = ByteArray(want * 2)
                    f.seek(dataStart + pos * 2L)
                    f.readFully(bytes)
                    val s = FloatArray(want) { i ->
                        ((bytes[2 * i].toInt() and 0xff) or (bytes[2 * i + 1].toInt() shl 8)).toShort() / 32768f
                    }
                    val len = if (pos + want >= totalSamples) want else cutPoint(s)
                    val seg = if (len == s.size) s else s.copyOf(len)
                    if (rms(seg) > 0.004f) { // 무음 구간은 건너뜀 (Whisper 환각 방지)
                        val st = rec.createStream()
                        try {
                            st.acceptWaveform(seg, SAMPLE_RATE)
                            rec.decode(st)
                            val t = rec.getResult(st).text.trim()
                            if (t.isNotEmpty() && !isJunk(t)) lines += Line(pos / SAMPLE_RATE, "", t)
                        } finally {
                            st.release()
                        }
                    }
                    pos += len
                    onProgress((pos.toLong() * 100 / totalSamples).toInt())
                }
            }
        } finally {
            rec.release()
        }
        return lines
    }

    /** MIN~MAX 초 사이에서 가장 조용한 0.1초 지점을 자를 위치로 고른다. */
    private fun cutPoint(s: FloatArray): Int {
        val frame = SAMPLE_RATE / 10
        var best = s.size
        var bestE = Float.MAX_VALUE
        var i = MIN_SEC * SAMPLE_RATE
        while (i + frame <= s.size) {
            var e = 0f
            for (k in i until i + frame) e += s[k] * s[k]
            if (e < bestE) { bestE = e; best = i + frame / 2 }
            i += frame
        }
        return best
    }

    private fun rms(s: FloatArray): Float {
        var e = 0.0
        for (v in s) e += v * v
        return sqrt(e / s.size.coerceAtLeast(1)).toFloat()
    }

    // Whisper가 무음/잡음에서 자주 지어내는 문구
    private fun isJunk(t: String) = listOf("시청해 주셔서 감사합니다", "구독과 좋아요", "MBC 뉴스", "자막 제공").any { t.contains(it) } && t.length < 40
}
