package com.oldjin.meetnote

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

data class UpdateInfo(val build: Int, val sha: String, val url: String, val size: Long)

/** GitHub 릴리스(meetnote-latest)를 확인해 새 빌드가 있으면 내려받아 설치한다. */
object Updater {
    private const val API = "https://api.github.com/repos/oldjin0/test/releases/tags/meetnote-latest"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS).build()

    val available = MutableStateFlow<UpdateInfo?>(null)
    /** null: 대기, 0..1: 다운로드 진행률 */
    val progress = MutableStateFlow<Float?>(null)
    val checking = MutableStateFlow(false)
    /** 마지막 확인 결과 문구 (설정 화면 표시용) */
    val message = MutableStateFlow("")

    private fun sp(ctx: Context) = ctx.getSharedPreferences("meetnote", Context.MODE_PRIVATE)

    /** 앱을 열 때 6시간에 한 번만 자동 확인. */
    fun autoCheck(ctx: Context) {
        val last = sp(ctx).getLong("update_checked_at", 0)
        if (System.currentTimeMillis() - last < 6 * 3600 * 1000L) return
        check(ctx)
    }

    fun check(ctx: Context) {
        if (checking.value) return
        checking.value = true
        val app = ctx.applicationContext
        scope.launch {
            try {
                val info = fetch()
                sp(app).edit().putLong("update_checked_at", System.currentTimeMillis()).apply()
                val newer = info != null && isNewer(info)
                available.value = if (newer) info else null
                message.value = when {
                    info == null -> "확인하지 못했어요"
                    newer -> "새 버전이 있어요 (빌드 ${info.build.takeIf { it > 0 } ?: info.sha})"
                    else -> "최신 버전입니다"
                }
            } catch (e: Exception) {
                message.value = "확인 실패: ${e.message?.take(80)}"
            } finally {
                checking.value = false
            }
        }
    }

    private fun isNewer(i: UpdateInfo): Boolean =
        if (i.build > 0) i.build > BuildConfig.VERSION_CODE else i.sha != BuildConfig.GIT_SHA

    private fun fetch(): UpdateInfo? {
        val req = Request.Builder().url(API)
            .header("Accept", "application/vnd.github+json").header("User-Agent", "MeetNote").build()
        http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
            val j = JSONObject(r.body?.string().orEmpty())
            val body = j.optString("body")
            val assets = j.optJSONArray("assets") ?: return null
            var url: String? = null
            var size = 0L
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                if (a.optString("name").endsWith(".apk")) {
                    url = a.optString("browser_download_url"); size = a.optLong("size"); break
                }
            }
            if (url == null) return null
            val build = Regex("""Build (\d+)""").find(body)?.groupValues?.get(1)?.toIntOrNull() ?: 0
            val sha = Regex("""Commit ([0-9a-f]{7})""").find(body)?.groupValues?.get(1) ?: ""
            return UpdateInfo(build, sha, url, size)
        }
    }

    /** 내려받기 → 완료되면 설치 화면을 연다. 앱을 이동해도 계속 진행된다. */
    fun downloadAndInstall(ctx: Context, info: UpdateInfo) {
        if (progress.value != null) return
        if (Live.busy) {
            Toast.makeText(ctx, "녹음·처리 중에는 업데이트할 수 없어요. 끝난 뒤에 해주세요", Toast.LENGTH_LONG).show()
            return
        }
        val app = ctx.applicationContext
        progress.value = 0f
        scope.launch {
            try {
                val dir = File(app.cacheDir, "updates").apply { deleteRecursively(); mkdirs() }
                val out = File(dir, "MeetNote.apk")
                http.newCall(Request.Builder().url(info.url).header("User-Agent", "MeetNote").build()).execute().use { r ->
                    if (!r.isSuccessful) throw IOException("HTTP ${r.code}")
                    val total = r.body?.contentLength()?.takeIf { it > 0 } ?: info.size
                    r.body!!.byteStream().use { input ->
                        out.outputStream().use { o ->
                            val buf = ByteArray(64 * 1024)
                            var done = 0L
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                o.write(buf, 0, n)
                                done += n
                                if (total > 0) progress.value = (done.toFloat() / total).coerceIn(0f, 1f)
                            }
                        }
                    }
                }
                if (info.size > 0 && out.length() != info.size) throw IOException("파일이 완전하지 않아요")
                progress.value = null
                install(app, out)
            } catch (e: Exception) {
                progress.value = null
                message.value = "다운로드 실패: ${e.message?.take(80)}"
                CoroutineScope(Dispatchers.Main).launch {
                    Toast.makeText(app, "업데이트 다운로드 실패: ${e.message?.take(80)}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun install(ctx: Context, apk: File) {
        if (!ctx.packageManager.canRequestPackageInstalls()) {
            CoroutineScope(Dispatchers.Main).launch {
                Toast.makeText(ctx, "'이 출처 허용'을 켠 뒤 업데이트를 다시 눌러주세요", Toast.LENGTH_LONG).show()
            }
            ctx.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", apk)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
