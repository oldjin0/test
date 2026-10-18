package com.oldjin.meetnote

import android.util.Base64
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject

/**
 * Gemini Live API(WebSocket)로 마이크 PCM을 흘려보내 말하는 즉시 텍스트(중간 결과 포함)를 받는다.
 * 연결이 끊기거나 결과가 오지 않으면 [healthy]가 false가 되어 구간 변환 모드가 대신한다.
 */
class LiveTranscriber(
    http: OkHttpClient,
    private val apiKey: String,
    private val model: String,
    private val transcribeOnly: Boolean,
    private val lang: String,
    private val onText: (text: String, interim: Boolean) -> Unit,
    private val onTurnComplete: () -> Unit,
) {
    private val client = http.newBuilder().readTimeout(0, java.util.concurrent.TimeUnit.MILLISECONDS)
        .pingInterval(20, java.util.concurrent.TimeUnit.SECONDS).build()
    private var ws: WebSocket? = null

    @Volatile var ready = false; private set
    @Volatile var closed = true; private set
    @Volatile var everReady = false; private set
    @Volatile var lastSpeechAt = 0L; private set
    @Volatile var lastTextAt = 0L; private set
    @Volatile var lastError: String? = null; private set

    // 0: languageCodes 포함, 1: 빈 설정(구버전 형식)
    private var variant = 0

    val healthy: Boolean
        get() = ready && !closed && !(lastSpeechAt - lastTextAt > 10_000)

    fun connect() {
        ready = false
        closed = false
        val url = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey"
        ws = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                webSocket.send(setupMessage())
            }

            override fun onMessage(webSocket: WebSocket, text: String) = handle(text)
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handle(bytes.utf8())

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                lastError = response?.let {
                    "HTTP ${it.code} " + (try { it.body?.string()?.replace("\n", " ")?.take(160) } catch (_: Exception) { null } ?: it.message)
                } ?: t.message
                finish()
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                lastError = "closed $code $reason"
                webSocket.close(1000, null)
                finish()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish()
        })
    }

    private fun finish() {
        if (!ready && !everReady) variant = (variant + 1) % 2
        ready = false
        closed = true
    }

    private fun setupMessage(): String {
        val setup = JSONObject()
            .put("model", "models/$model")
            .put(
                "generationConfig",
                JSONObject().put("responseModalities", JSONArray().put(if (transcribeOnly) "TEXT" else "AUDIO"))
            )
        val tr = JSONObject()
        if (variant == 0) tr.put("languageCodes", JSONArray().apply { if (lang.isNotBlank()) put(lang) })
        setup.put("inputAudioTranscription", tr)
        return JSONObject().put("setup", setup).toString()
    }

    private fun handle(raw: String) {
        val j = try { JSONObject(raw) } catch (e: Exception) { return }
        if (j.has("setupComplete") || j.has("setup_complete")) {
            ready = true
            everReady = true
            lastTextAt = System.currentTimeMillis()
            lastSpeechAt = lastTextAt
            return
        }
        val sc = j.optJSONObject("serverContent") ?: j.optJSONObject("server_content") ?: return
        val interim = (sc.optJSONObject("interimInputTranscription") ?: sc.optJSONObject("interim_input_transcription"))
            ?.optString("text").orEmpty()
        val fin = (sc.optJSONObject("inputTranscription") ?: sc.optJSONObject("input_transcription"))
            ?.optString("text").orEmpty()
        if (interim.isNotEmpty()) { lastTextAt = System.currentTimeMillis(); onText(interim, true) }
        if (fin.isNotEmpty()) { lastTextAt = System.currentTimeMillis(); onText(fin, false) }
        if (sc.optBoolean("turnComplete") || sc.optBoolean("turn_complete")) onTurnComplete()
    }

    fun markSpeech() { lastSpeechAt = System.currentTimeMillis() }

    fun send(pcm: ByteArray, len: Int) {
        val w = ws ?: return
        if (!ready || w.queueSize() > 2_000_000) return
        val data = Base64.encodeToString(pcm, 0, len, Base64.NO_WRAP)
        w.send(
            JSONObject().put(
                "realtimeInput",
                JSONObject().put("audio", JSONObject().put("data", data).put("mimeType", "audio/pcm;rate=16000"))
            ).toString()
        )
    }

    fun close() {
        try { ws?.close(1000, "bye") } catch (_: Exception) {}
        closed = true
        ready = false
    }
}
