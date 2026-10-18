package com.oldjin.meetnote

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.k2fsa.sherpa.onnx.EndpointConfig
import com.k2fsa.sherpa.onnx.EndpointRule
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** 녹음 PCM(16kHz mono 16bit)을 받아 실시간 자막을 만드는 기기 내 엔진. API를 쓰지 않는다. */
interface CaptionEngine {
    val name: String
    fun feed(buf: ByteArray, len: Int)
    fun close()
}

/**
 * 1순위: 안드로이드 내장 Google 기기 내 음성인식 (Android 13+).
 * 마이크를 따로 열지 않고 녹음 중인 PCM을 파이프로 넘겨주므로 녹음과 충돌하지 않는다.
 * 지원하지 않는 폰이면 [onFail]로 알려 Sherpa로 바꾼다.
 */
class GoogleCaption(
    private val ctx: Context,
    private val lang: String,
    private val onText: (String, Boolean) -> Unit,
    private val onEnd: () -> Unit,
    private val onFail: (String) -> Unit,
) : CaptionEngine {
    override val name = "Google 기기 내 인식"

    companion object {
        fun available(ctx: Context): Boolean =
            Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)
    }

    private val main = Handler(Looper.getMainLooper())
    private val queue = LinkedBlockingQueue<ByteArray>(400)
    @Volatile private var running = true
    @Volatile private var out: OutputStream? = null
    private var readFd: ParcelFileDescriptor? = null
    private var sr: SpeechRecognizer? = null
    private var errors = 0
    @Volatile private var textCount = 0
    private var failed = false

    // 녹음 스레드가 막히지 않도록 별도 스레드에서 파이프에 쓴다
    private val writer = Thread {
        while (running) {
            val b = queue.poll(300, TimeUnit.MILLISECONDS) ?: continue
            try { out?.write(b) } catch (_: IOException) { /* 세션 전환 중: 버림 */ }
        }
    }.apply { isDaemon = true; start() }

    init {
        main.post { start() }
        // 30초 동안 한 글자도 안 나오면 이 폰에서는 동작하지 않는 것으로 보고 넘긴다
        main.postDelayed({ if (running && textCount == 0) fail("30초간 응답 없음") }, 30_000)
    }

    private fun fail(why: String) {
        if (failed) return
        failed = true
        close()
        onFail(why)
    }

    private fun intent(fd: ParcelFileDescriptor) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang.ifBlank { "ko-KR" })
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, fd)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
        // 오디오가 끝날 때까지 끊지 않고 계속 인식 (긴 회의용)
        putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
    }

    private fun start() {
        if (!running || Build.VERSION.SDK_INT < 33) return
        try {
            val pipe = ParcelFileDescriptor.createPipe()
            val oldOut = out
            val oldRead = readFd
            out = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
            readFd = pipe[0]
            try { oldOut?.close() } catch (_: Exception) {}
            try { oldRead?.close() } catch (_: Exception) {}
            val r = sr ?: SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx).also {
                it.setRecognitionListener(listener)
                sr = it
            }
            r.startListening(intent(pipe[0]))
        } catch (e: Exception) {
            fail("시작 실패: ${e.message}")
        }
    }

    private fun restart(delayMs: Long = 200) {
        if (!running) return
        main.postDelayed({ start() }, delayMs)
    }

    private fun first(b: Bundle?): String =
        b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val t = first(partialResults)
            if (t.isNotBlank()) { textCount++; errors = 0; onText(t, true) }
        }

        override fun onSegmentResults(segmentResults: Bundle) {
            val t = first(segmentResults)
            if (t.isNotBlank()) { textCount++; errors = 0; onText(t, false) }
            onEnd()
        }

        override fun onEndOfSegmentedSession() = restart()

        override fun onResults(results: Bundle?) {
            val t = first(results)
            if (t.isNotBlank()) { textCount++; errors = 0; onText(t, false) }
            onEnd()
            restart()
        }

        override fun onError(error: Int) {
            if (!running) return
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> restart()
                SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        try { readFd?.let { sr?.triggerModelDownload(intent(it)) } } catch (_: Exception) {}
                    }
                    fail("한국어 기기 내 모델 없음 (오류 $error) — 설정 > Google 음성 인식에서 한국어 오프라인 다운로드")
                }
                else -> if (++errors >= 3) fail("인식 오류 $error") else restart(800)
            }
        }
    }

    override fun feed(buf: ByteArray, len: Int) {
        if (running) queue.offer(buf.copyOf(len))
    }

    override fun close() {
        if (!running) return
        running = false
        main.post {
            try { sr?.cancel(); sr?.destroy() } catch (_: Exception) {}
            sr = null
            try { out?.close() } catch (_: Exception) {}
            try { readFd?.close() } catch (_: Exception) {}
        }
    }
}

/** 2순위: Sherpa-onnx 스트리밍 한국어 모델 (오프라인, 모든 폰). */
class SherpaCaption(
    ctx: Context,
    private val onText: (String, Boolean) -> Unit,
    private val onEnd: () -> Unit,
) : CaptionEngine {
    override val name = "Sherpa 기기 내 인식"
    private val queue = LinkedBlockingQueue<ByteArray>(400)
    @Volatile private var running = true
    private val rec: OnlineRecognizer

    init {
        val d = LocalModels.dir(ctx, LocalModels.KO_STREAM)
        fun pick(prefix: String, preferInt8: Boolean) =
            (if (preferInt8) LocalModels.find(d) { it.startsWith(prefix) && it.endsWith(".int8.onnx") } else null)
                ?: LocalModels.find(d) { it.startsWith(prefix) && it.endsWith(".onnx") && !it.endsWith(".int8.onnx") }
                ?: LocalModels.find(d) { it.startsWith(prefix) && it.endsWith(".onnx") }
                ?: throw IOException("모델 파일($prefix)이 없어요")
        val tokens = LocalModels.find(d) { it == "tokens.txt" } ?: throw IOException("tokens.txt 가 없어요")
        val cfg = OnlineRecognizerConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = pick("encoder", true).path,
                    decoder = pick("decoder", false).path,
                    joiner = pick("joiner", true).path,
                ),
                tokens = tokens.path,
                numThreads = 2,
                modelType = "zipformer",
            ),
            endpointConfig = EndpointConfig(
                rule1 = EndpointRule(false, 2.4f, 0.0f),
                rule2 = EndpointRule(true, 1.0f, 0.0f),
                rule3 = EndpointRule(false, 0.0f, 15.0f),
            ),
            enableEndpoint = true,
        )
        rec = OnlineRecognizer(null, cfg)
        Thread {
            val stream = rec.createStream()
            var last = ""
            try {
                while (running || queue.isNotEmpty()) {
                    val b = queue.poll(300, TimeUnit.MILLISECONDS) ?: continue
                    val n = b.size / 2
                    val f = FloatArray(n)
                    for (i in 0 until n) {
                        val s = (b[2 * i].toInt() and 0xff) or (b[2 * i + 1].toInt() shl 8)
                        f[i] = s.toShort() / 32768f
                    }
                    stream.acceptWaveform(f, SAMPLE_RATE)
                    while (rec.isReady(stream)) rec.decode(stream)
                    val t = rec.getResult(stream).text.trim()
                    if (t != last && t.isNotEmpty()) { last = t; onText(t, true) }
                    if (rec.isEndpoint(stream)) {
                        if (t.isNotEmpty()) { onText(t, false); onEnd() }
                        last = ""
                        rec.reset(stream)
                    }
                }
                stream.inputFinished()
                while (rec.isReady(stream)) rec.decode(stream)
                val t = rec.getResult(stream).text.trim()
                if (t.isNotEmpty()) { onText(t, false); onEnd() }
            } catch (_: Exception) {
            } finally {
                stream.release()
                rec.release()
            }
        }.apply { isDaemon = true; start() }
    }

    override fun feed(buf: ByteArray, len: Int) {
        if (running) queue.offer(buf.copyOf(len))
    }

    override fun close() { running = false }
}
