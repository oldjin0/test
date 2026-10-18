package com.oldjin.meetnote

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream

/** 기기 안에서 도는 오프라인 한국어 음성인식(Vosk). API·네트워크를 쓰지 않는다. */
class OfflineTranscriber(
    ctx: Context,
    private val onText: (text: String, interim: Boolean) -> Unit,
    private val onUtteranceEnd: () -> Unit,
) {
    private val queue = LinkedBlockingQueue<ByteArray>(300)
    @Volatile private var running = true
    @Volatile var textCount = 0; private set
    @Volatile var error: String? = null; private set
    private val model: Model
    private val rec: Recognizer
    private val worker: Thread

    init {
        model = Model(ModelInstaller.dir(ctx).path)
        rec = Recognizer(model, SAMPLE_RATE.toFloat())
        worker = Thread {
            try {
                while (running || queue.isNotEmpty()) {
                    val b = queue.poll(300, TimeUnit.MILLISECONDS) ?: continue
                    if (rec.acceptWaveForm(b, b.size)) {
                        emit(JSONObject(rec.result).optString("text"), false)
                        onUtteranceEnd()
                    } else {
                        emit(JSONObject(rec.partialResult).optString("partial"), true)
                    }
                }
                emit(JSONObject(rec.finalResult).optString("text"), false)
                onUtteranceEnd()
            } catch (e: Exception) {
                error = e.message
            } finally {
                try { rec.close() } catch (_: Exception) {}
                try { model.close() } catch (_: Exception) {}
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun emit(t: String, interim: Boolean) {
        if (t.isBlank()) return
        textCount++
        onText(t, interim)
    }

    fun feed(buf: ByteArray, len: Int) {
        if (running) queue.offer(buf.copyOf(len))
    }

    fun close() {
        running = false
    }
}

/** 모델(약 80MB)을 한 번 내려받아 앱 내부에 설치한다. */
object ModelInstaller {
    private const val URL = "https://alphacephei.com/vosk/models/vosk-model-small-ko-0.22.zip"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** null: 대기, 0..1: 진행률(받기 0~0.8, 풀기 0.8~1) */
    val progress = MutableStateFlow<Float?>(null)
    val message = MutableStateFlow("")

    fun dir(ctx: Context) = File(ctx.filesDir, "vosk-ko")
    fun installed(ctx: Context) = File(dir(ctx), "am").exists()

    fun install(ctx: Context) {
        if (progress.value != null) return
        val app = ctx.applicationContext
        progress.value = 0f
        message.value = "내려받는 중…"
        scope.launch {
            val zip = File(app.cacheDir, "vosk-ko.zip")
            val out = dir(app)
            try {
                val http = OkHttpClient.Builder().connectTimeout(30, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()
                http.newCall(Request.Builder().url(URL).build()).execute().use { r ->
                    if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
                    val total = r.body!!.contentLength().takeIf { it > 0 } ?: 82_000_000L
                    r.body!!.byteStream().use { i ->
                        zip.outputStream().use { o ->
                            val buf = ByteArray(64 * 1024)
                            var done = 0L
                            while (true) {
                                val n = i.read(buf)
                                if (n < 0) break
                                o.write(buf, 0, n)
                                done += n
                                progress.value = (done.toFloat() / total).coerceIn(0f, 1f) * 0.8f
                            }
                        }
                    }
                }
                message.value = "설치 중…"
                out.deleteRecursively(); out.mkdirs()
                val root = out.canonicalPath + File.separator
                var entries = 0
                ZipInputStream(zip.inputStream().buffered()).use { z ->
                    while (true) {
                        val e = z.nextEntry ?: break
                        val rel = e.name.substringAfter('/', "")
                        if (rel.isEmpty()) continue
                        val f = File(out, rel)
                        if (!f.canonicalPath.startsWith(root)) continue // zip-slip 방지
                        if (e.isDirectory) f.mkdirs() else {
                            f.parentFile?.mkdirs()
                            f.outputStream().use { z.copyTo(it) }
                        }
                        if (++entries % 20 == 0) progress.value = 0.8f + (entries % 400) / 400f * 0.19f
                    }
                }
                if (!installed(app)) throw IOException("모델 파일 구조가 예상과 달라요")
                message.value = "설치 완료"
            } catch (e: Exception) {
                out.deleteRecursively()
                message.value = "설치 실패: ${e.message?.take(80)}"
            } finally {
                zip.delete()
                progress.value = null
            }
        }
    }
}
