package com.oldjin.meetnote

import android.content.Context
import android.util.Base64
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

class ApiException(val code: Int, message: String) : IOException(message)

/** Google Gemini REST 클라이언트. 키는 x-goog-api-key 헤더로만 전송한다. */
class GeminiClient(private val ctx: Context, private val apiKey: String, modelOverride: String = "") {
    private val overridden = modelOverride.isNotBlank()
    @Volatile private var model = modelOverride.ifBlank { Prefs.resolvedText(ctx) }
    @Volatile private var liveModelName = Prefs.resolvedLive(ctx)

    val http = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.MINUTES)
        .writeTimeout(10, TimeUnit.MINUTES)
        .callTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private val base = "https://generativelanguage.googleapis.com"

    private fun req(url: String) = Request.Builder().url(url).header("x-goog-api-key", apiKey)

    /** 429/5xx/네트워크 오류는 지수 백오프로 재시도한다. */
    private fun <T> withRetry(retries: Int = 3, block: () -> T): T {
        var delayMs = 2000L
        var last: IOException? = null
        for (attempt in 0..retries) {
            try {
                return block()
            } catch (e: ApiException) {
                if (e.code != 429 && e.code < 500) throw e
                last = e
            } catch (e: IOException) {
                last = e
            }
            if (attempt < retries) {
                Thread.sleep(delayMs)
                delayMs *= 2
            }
        }
        throw last ?: IOException("알 수 없는 오류")
    }

    private fun exec(r: Request): String = http.newCall(r).execute().use { resp ->
        val body = resp.body?.string().orEmpty()
        if (!resp.isSuccessful) {
            val msg = try {
                JSONObject(body).getJSONObject("error").getString("message")
            } catch (e: Exception) {
                "HTTP ${resp.code}"
            }
            throw ApiException(resp.code, msg)
        }
        body
    }

    fun validateKey() {
        withRetry(1) { exec(req("$base/v1beta/models?pageSize=1").build()) }
    }

    /** 현재 계정에서 쓸 수 있는 최신 flash(텍스트)·Live(실시간) 모델을 찾는다. 하루에 한 번 갱신. */
    @Synchronized
    fun ensureModels(force: Boolean = false) {
        val stale = System.currentTimeMillis() - Prefs.resolvedAt(ctx) > 24 * 3600 * 1000L
        if (!force && !stale && (model.isNotBlank() || overridden)) return
        val found = discover()
        if (!overridden || force) model = found.first ?: model.ifBlank { "gemini-flash-latest" }
        liveModelName = found.second ?: ""
        Prefs.setResolved(ctx, model, liveModelName)
    }

    fun textModel(): String { ensureModels(); return model }
    fun liveModel(): String? { ensureModels(); return liveModelName.ifBlank { null } }

    private fun discover(): Pair<String?, String?> {
        val all = mutableListOf<Pair<String, List<String>>>()
        var token: String? = null
        do {
            val url = "$base/v1beta/models?pageSize=200" + (token?.let { "&pageToken=$it" } ?: "")
            val j = JSONObject(withRetry(1) { exec(req(url).build()) })
            val arr = j.optJSONArray("models")
            if (arr != null) for (i in 0 until arr.length()) {
                val m = arr.getJSONObject(i)
                val methods = m.optJSONArray("supportedGenerationMethods")
                all += m.optString("name").removePrefix("models/") to
                    (if (methods == null) emptyList() else (0 until methods.length()).map { methods.getString(it) })
            }
            token = j.optString("nextPageToken").ifBlank { null }
        } while (token != null)

        val bad = listOf("image", "tts", "live", "audio", "transcribe", "embedding", "robotics", "computer", "native", "learnlm")
        val text = all.filter { (n, m) -> "generateContent" in m && bad.none { n.contains(it) } }
            .mapNotNull { (n, _) -> flashScore(n)?.let { n to it } }.maxByOrNull { it.second }?.first
            ?: all.firstOrNull { it.first == "gemini-flash-latest" }?.first
        val live = all.filter { (_, m) -> "bidiGenerateContent" in m }
            .maxByOrNull { (n, _) -> liveScore(n) }?.first
        return text to live
    }

    private val verRe = Regex("""gemini-(\d+)(?:\.(\d+))?""")

    private fun version(n: String): Long {
        val m = verRe.find(n) ?: return 0
        return m.groupValues[1].toLong() * 1_000_000 + (m.groupValues[2].toLongOrNull() ?: 0) * 10_000
    }

    private fun flashScore(n: String): Long? {
        if (!Regex("""gemini-\d+(\.\d+)?-flash""").containsMatchIn(n)) return null
        val lite = n.contains("lite")
        val unstable = n.contains("preview") || n.contains("exp") || Regex("""-\d{2,}""").containsMatchIn(n.substringAfter("flash"))
        return version(n) + (if (lite) 0 else 5_000) + (if (unstable) 0 else 1_000)
    }

    private fun liveScore(n: String): Long =
        version(n) + (if (n.contains("transcribe")) 1_000_000_000L else 0) + (if (n.contains("live")) 100 else 0)

    fun liveIsTranscribeOnly(): Boolean = liveModelName.contains("transcribe")
    fun apiKeyForSocket() = apiKey

    private fun generate(parts: JSONArray, json: Boolean, fast: Boolean): String {
        val gen = JSONObject().put("temperature", 0.2)
        if (json) gen.put("responseMimeType", "application/json").put("responseSchema", SCHEMA)
        if (fast && model.contains("2.5-flash")) gen.put("thinkingConfig", JSONObject().put("thinkingBudget", 0))
        val body = JSONObject()
            .put("contents", JSONArray().put(JSONObject().put("role", "user").put("parts", parts)))
            .put("generationConfig", gen)
        ensureModels()
        fun call() = withRetry {
            exec(
                req("$base/v1beta/models/$model:generateContent")
                    .post(body.toString().toRequestBody("application/json".toMediaType())).build()
            )
        }
        val resp = try {
            call()
        } catch (e: ApiException) {
            // 모델이 내려갔거나 신규 사용자에게 막힌 경우: 목록을 다시 받아 최신 모델로 한 번 재시도
            if ((e.code == 404 || e.message.orEmpty().contains("no longer available"))) {
                ensureModels(force = true)
                call()
            } else throw e
        }
        val cand = JSONObject(resp).optJSONArray("candidates")?.optJSONObject(0)
            ?: throw IOException("응답이 비어 있습니다 (차단되었을 수 있음)")
        val parts2 = cand.optJSONObject("content")?.optJSONArray("parts") ?: return ""
        return (0 until parts2.length()).joinToString("") { parts2.getJSONObject(it).optString("text") }
    }

    private fun text(s: String) = JSONObject().put("text", s)

    private fun parseLines(json: String, offset: Int): List<Line> {
        val arr = JSONArray(json.trim().ifEmpty { "[]" })
        return (0 until arr.length()).mapNotNull {
            val o = arr.getJSONObject(it)
            val t = o.optString("text").trim()
            if (t.isEmpty()) null else Line(offset + o.optInt("start"), o.optString("speaker", "화자 1").ifBlank { "화자 1" }, t)
        }
    }

    /** 실시간 초안: 짧은 청크 단위 전사 + 화자 구분. */
    fun transcribeChunk(wav: ByteArray, offsetSec: Int, context: List<Line>): List<Line> {
        val ctx = if (context.isEmpty()) "없음" else context.joinToString("\n") { "${it.speaker}: ${it.text}" }
        val prompt = """
            회의 녹음의 일부 구간입니다. 들리는 말을 그대로 받아 적고 화자를 구분하세요.
            - 화자 라벨은 "화자 1", "화자 2" 형식. 같은 목소리는 같은 라벨을 유지하고, 처음 듣는 목소리만 새 번호를 부여.
            - 직전까지의 대화(라벨 참고용): 
            $ctx
            - 한국어는 한국어로, 다른 언어는 원어 그대로 적기. 들리지 않는 내용을 지어내지 말 것. 음성이 없으면 빈 배열 [].
            - start 는 이 오디오 시작 기준 초 단위 정수.
        """.trimIndent()
        val parts = JSONArray().put(text(prompt)).put(
            JSONObject().put("inline_data", JSONObject().put("mime_type", "audio/wav").put("data", Base64.encodeToString(wav, Base64.NO_WRAP)))
        )
        return parseLines(generate(parts, json = true, fast = true), offsetSec)
    }

    /** 최종본: 전체 오디오를 Files API로 올려 한 번에 화자 구분 전사. */
    fun transcribeFull(wav: File): List<Line> {
        val (uri, name) = upload(wav, "audio/wav")
        try {
            val prompt = """
                이 오디오는 회의 전체 녹음입니다. 처음부터 끝까지 빠짐없이 받아 적고 화자를 구분하세요.
                - 화자 라벨은 "화자 1", "화자 2" 형식. 목소리 특징으로 구분하고 녹음 전체에서 일관되게 유지.
                - 발언 단위(화자가 바뀌거나 문단이 바뀔 때)로 나누고, start 는 오디오 시작 기준 초 단위 정수.
                - 한국어는 한국어로, 다른 언어는 원어 그대로. 들리지 않는 내용을 지어내지 말 것. 음성이 없으면 [].
            """.trimIndent()
            val parts = JSONArray().put(text(prompt)).put(
                JSONObject().put("file_data", JSONObject().put("mime_type", "audio/wav").put("file_uri", uri))
            )
            return parseLines(generate(parts, json = true, fast = true), 0)
        } finally {
            try { exec(req("$base/v1beta/$name").delete().build()) } catch (_: Exception) {}
        }
    }

    fun summarize(transcript: String): String {
        val prompt = """
            아래는 화자가 구분된 회의 전사문입니다. 한국어로 간결하게 정리하세요. 전사문에 없는 내용은 추가하지 마세요.
            형식(마크다운):
            ## 한 줄 요약
            ## 핵심 내용
            - 항목
            ## 결정 사항
            - 항목 (없으면 "없음")
            ## 할 일
            - [담당 화자] 내용 (기한이 언급되면 포함, 없으면 "없음")
            ## 미결 사항
            - 항목 (없으면 "없음")

            전사문:
            $transcript
        """.trimIndent()
        return generate(JSONArray().put(text(prompt)), json = false, fast = false).trim()
    }

    /** Files API 재개형 업로드. (file uri, file name) 반환. */
    private fun upload(file: File, mime: String): Pair<String, String> = withRetry(2) {
        val startReq = req("$base/upload/v1beta/files")
            .header("X-Goog-Upload-Protocol", "resumable")
            .header("X-Goog-Upload-Command", "start")
            .header("X-Goog-Upload-Header-Content-Length", file.length().toString())
            .header("X-Goog-Upload-Header-Content-Type", mime)
            .post(JSONObject().put("file", JSONObject().put("display_name", file.name)).toString().toRequestBody("application/json".toMediaType()))
            .build()
        val uploadUrl = http.newCall(startReq).execute().use {
            if (!it.isSuccessful) throw ApiException(it.code, "업로드 시작 실패 (HTTP ${it.code})")
            it.header("X-Goog-Upload-URL") ?: throw IOException("업로드 URL 없음")
        }
        val upReq = Request.Builder().url(uploadUrl)
            .header("X-Goog-Upload-Offset", "0")
            .header("X-Goog-Upload-Command", "upload, finalize")
            .post(file.asRequestBody(mime.toMediaType()))
            .build()
        val info = JSONObject(exec(upReq)).getJSONObject("file")
        val name = info.getString("name")
        var state = info.optString("state", "ACTIVE")
        var uri = info.getString("uri")
        var tries = 0
        while (state == "PROCESSING" && tries++ < 60) {
            Thread.sleep(2000)
            val f = JSONObject(exec(req("$base/v1beta/$name").build()))
            state = f.optString("state", "ACTIVE")
            uri = f.optString("uri", uri)
        }
        if (state == "FAILED") throw IOException("파일 처리 실패")
        uri to name
    }

    companion object {
        private val SCHEMA = JSONObject(
            """{"type":"ARRAY","items":{"type":"OBJECT","properties":{"speaker":{"type":"STRING"},"start":{"type":"INTEGER"},"text":{"type":"STRING"}},"required":["speaker","start","text"]}}"""
        )
    }
}
