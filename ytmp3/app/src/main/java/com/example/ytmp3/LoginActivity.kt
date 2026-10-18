package com.example.ytmp3

import android.annotation.SuppressLint
import android.content.Context
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import java.io.File

/** 유튜브에 로그인한 뒤 쿠키를 yt-dlp가 읽는 Netscape cookies.txt로 저장한다. */
class LoginActivity : AppCompatActivity() {

    companion object {
        private const val LOGIN_URL =
            "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://m.youtube.com"

        fun cookieFile(context: Context) = File(context.filesDir, "cookies.txt")

        fun logout(context: Context) {
            cookieFile(context).delete()
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
        }
    }

    private lateinit var webView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        webView = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            // 구글은 "; wv"가 붙은 WebView의 로그인을 막으므로 일반 브라우저처럼 보이게 한다
            settings.userAgentString = settings.userAgentString
                .replace("; wv", "")
                .replace(Regex("Version/\\S+ "), "")
            webViewClient = WebViewClient()
        }
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        val done = Button(this).apply {
            text = "로그인 완료 (유튜브 화면이 보이면 누르세요)"
            setOnClickListener { saveCookies() }
        }

        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(done, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(webView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        })

        webView.loadUrl(LOGIN_URL)
    }

    private fun saveCookies() {
        val cm = CookieManager.getInstance()
        cm.flush()
        val raw = cm.getCookie("https://www.youtube.com").orEmpty()
        if (!raw.contains("SID")) {
            Toast.makeText(this, "아직 로그인되지 않았습니다", Toast.LENGTH_SHORT).show()
            return
        }
        val expiry = System.currentTimeMillis() / 1000 + 365L * 24 * 3600
        val lines = raw.split(";").mapNotNull { pair ->
            val idx = pair.indexOf('=')
            if (idx <= 0) null
            else ".youtube.com\tTRUE\t/\tTRUE\t$expiry\t${pair.substring(0, idx).trim()}\t${pair.substring(idx + 1).trim()}"
        }
        cookieFile(this).writeText("# Netscape HTTP Cookie File\n" + lines.joinToString("\n") + "\n")
        Toast.makeText(this, "로그인 정보 저장됨", Toast.LENGTH_SHORT).show()
        finish()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }
}
