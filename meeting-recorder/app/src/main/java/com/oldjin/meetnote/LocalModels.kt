package com.oldjin.meetnote

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

/** 기기 안에서 쓰는 음성인식 모델. tar(.tar.bz2) 하나 또는 개별 파일 여러 개로 받는다. */
data class LocalModel(
    val id: String,
    val title: String,
    val desc: String,
    val size: String,
    val tarUrls: List<String> = emptyList(),
    val files: List<String> = emptyList(),
)

object LocalModels {
    private const val GH = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
    private const val HF = "https://huggingface.co/csukuangfj"

    val KO_STREAM = LocalModel(
        "ko-stream", "실시간 한국어 인식 (Sherpa)",
        "Google 기기 내 인식을 못 쓰는 폰에서 실시간 자막에 사용", "약 100~300MB",
        tarUrls = listOf(
            "$GH/sherpa-onnx-streaming-zipformer-korean-2024-06-16-mobile.tar.bz2",
            "$GH/sherpa-onnx-streaming-zipformer-korean-2024-06-16.tar.bz2",
        ),
    )
    val WHISPER_SMALL = LocalModel(
        "whisper-small", "Whisper small (권장)",
        "녹음 후 기기 내 정밀 변환 · 무료 · 녹음 길이 정도 시간 소요", "약 360MB",
        files = listOf("small-encoder.int8.onnx", "small-decoder.int8.onnx", "small-tokens.txt")
            .map { "$HF/sherpa-onnx-whisper-small/resolve/main/$it" },
    )
    val WHISPER_TURBO = LocalModel(
        "whisper-turbo", "Whisper turbo (최고 정확도)",
        "가장 정확하지만 크고 느림 · 고사양 폰 · 충전 중 권장", "약 1GB",
        files = listOf("turbo-encoder.int8.onnx", "turbo-decoder.int8.onnx", "turbo-tokens.txt")
            .map { "$HF/sherpa-onnx-whisper-turbo/resolve/main/$it" },
    )
    val ALL = listOf(KO_STREAM, WHISPER_SMALL, WHISPER_TURBO)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    /** id → 진행률(0..1). 없으면 대기 중. */
    val progress = MutableStateFlow<Map<String, Float>>(emptyMap())
    val messages = MutableStateFlow<Map<String, String>>(emptyMap())
    /** 설치/삭제 시 화면 갱신용 */
    val version = MutableStateFlow(0)

    fun dir(ctx: Context, m: LocalModel) = File(ctx.filesDir, "models/${m.id}")
    fun installed(ctx: Context, m: LocalModel) = File(dir(ctx, m), ".ok").exists()

    /** 설치된 Whisper 중 가장 좋은 것 (turbo > small). */
    fun bestWhisper(ctx: Context): LocalModel? = listOf(WHISPER_TURBO, WHISPER_SMALL).firstOrNull { installed(ctx, it) }

    fun find(dir: File, pred: (String) -> Boolean): File? =
        dir.walkTopDown().filter { it.isFile && pred(it.name) }.minByOrNull { it.path.length }

    fun delete(ctx: Context, m: LocalModel) {
        dir(ctx, m).deleteRecursively()
        messages.update { it - m.id }
        version.update { it + 1 }
    }

    private fun msg(id: String, s: String) = messages.update { it + (id to s) }
    private fun prog(id: String, p: Float?) = progress.update { if (p == null) it - id else it + (id to p) }

    fun install(ctx: Context, m: LocalModel) {
        if (m.id in progress.value) return
        val app = ctx.applicationContext
        prog(m.id, 0f)
        msg(m.id, "내려받는 중…")
        scope.launch {
            val out = dir(app, m)
            val http = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).build()
            try {
                out.deleteRecursively(); out.mkdirs()
                if (m.tarUrls.isNotEmpty()) {
                    val tmp = File(app.cacheDir, "${m.id}.tar.bz2")
                    var lastErr: Exception? = null
                    var ok = false
                    for (u in m.tarUrls) {
                        try { download(http, u, tmp) { prog(m.id, it * 0.7f) }; ok = true; break } catch (e: Exception) { lastErr = e }
                    }
                    if (!ok) throw lastErr ?: IOException("다운로드 실패")
                    msg(m.id, "압축 푸는 중…")
                    untarBz2(tmp, out) { prog(m.id, 0.7f + it * 0.3f) }
                    tmp.delete()
                } else {
                    m.files.forEachIndexed { i, u ->
                        val name = u.substringAfterLast('/')
                        download(http, u, File(out, name)) { prog(m.id, (i + it) / m.files.size) }
                    }
                }
                File(out, ".ok").writeText("ok")
                msg(m.id, "설치 완료")
            } catch (e: Exception) {
                out.deleteRecursively()
                msg(m.id, "설치 실패: ${e.message?.take(100)}")
            } finally {
                prog(m.id, null)
                version.update { it + 1 }
            }
        }
    }

    private fun download(http: OkHttpClient, url: String, dest: File, onProgress: (Float) -> Unit) {
        http.newCall(Request.Builder().url(url).header("User-Agent", "MeetNote").build()).execute().use { r ->
            if (!r.isSuccessful) throw IOException("HTTP ${r.code} ($url)")
            val total = r.body!!.contentLength()
            r.body!!.byteStream().use { i ->
                dest.outputStream().use { o ->
                    val buf = ByteArray(256 * 1024)
                    var done = 0L
                    var last = 0L
                    while (true) {
                        val n = i.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        done += n
                        if (total > 0 && done - last > 1_000_000) { last = done; onProgress(done.toFloat() / total) }
                    }
                }
            }
        }
    }

    /** 맨 앞 폴더 이름을 떼고 풀어낸다. 테스트 음성 등 불필요한 파일은 건너뛴다. */
    private fun untarBz2(src: File, out: File, onProgress: (Float) -> Unit) {
        val root = out.canonicalPath + File.separator
        val total = src.length().coerceAtLeast(1)
        val counting = src.inputStream().buffered(1 shl 16)
        var read = 0L
        val tracked = object : java.io.FilterInputStream(counting) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, len).also { if (it > 0) read += it }
            override fun read(): Int = super.read().also { if (it >= 0) read++ }
        }
        TarArchiveInputStream(BZip2CompressorInputStream(tracked)).use { tar ->
            var n = 0
            while (true) {
                val e = tar.nextEntry ?: break
                val rel = e.name.substringAfter('/', "")
                if (rel.isEmpty() || rel.startsWith("test_wavs")) continue
                val f = File(out, rel)
                if (!f.canonicalPath.startsWith(root)) continue // 경로 조작 방지
                if (e.isDirectory) f.mkdirs() else {
                    f.parentFile?.mkdirs()
                    f.outputStream().use { tar.copyTo(it) }
                }
                if (++n % 2 == 0) onProgress(read.toFloat() / total)
            }
        }
    }
}
