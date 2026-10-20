package com.oldjin.webtv

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout

private const val START_URL = "https://webtv.dothome.co.kr/"

/** Draws the remote-control pointer. */
private class CursorView(context: Context) : View(context) {
    var px = 0f
    var py = 0f
    var shown = false
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK
        style = Paint.Style.STROKE
        strokeWidth = 4f
    }

    override fun onDraw(canvas: Canvas) {
        if (!shown) return
        canvas.drawCircle(px, py, 14f, fill)
        canvas.drawCircle(px, py, 14f, edge)
    }
}

/**
 * Full-screen WebView for TV boxes. D-pad moves the page focus as usual; the
 * Menu key (or a long press on OK) switches to a pointer that the arrows move
 * and OK clicks, for sites whose player has no focusable controls.
 */
class MainActivity : Activity() {
    private lateinit var root: FrameLayout
    private lateinit var web: WebView
    private lateinit var cursor: CursorView
    private var customView: View? = null
    private var customCallback: WebChromeClient.CustomViewCallback? = null
    private var okDownAt = 0L
    private var okLongHandled = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        root = FrameLayout(this)
        web = WebView(this)
        cursor = CursorView(this)
        root.addView(web, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        root.addView(cursor, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        setContentView(root)

        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
            useWideViewPort = true
            loadWithOverviewMode = true
        }
        web.setBackgroundColor(Color.BLACK)
        web.isFocusable = true
        web.requestFocus()

        // Links and redirects stay inside the app instead of opening a browser.
        web.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = false
        }
        web.webChromeClient = object : WebChromeClient() {
            // The site's player asked for full screen: show it over everything.
            override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                if (customView != null) {
                    callback.onCustomViewHidden()
                    return
                }
                customView = view
                customCallback = callback
                root.addView(view, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                web.visibility = View.GONE
                cursor.bringToFront()
            }

            override fun onHideCustomView() {
                customView?.let { root.removeView(it) }
                customView = null
                customCallback?.onCustomViewHidden()
                customCallback = null
                web.visibility = View.VISIBLE
                web.requestFocus()
            }
        }

        if (savedInstanceState != null) web.restoreState(savedInstanceState) else web.loadUrl(START_URL)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        web.saveState(outState)
    }

    override fun onPause() {
        super.onPause()
        web.onPause()
    }

    override fun onResume() {
        super.onResume()
        web.onResume()
    }

    override fun onDestroy() {
        web.destroy()
        super.onDestroy()
    }

    private fun togglePointer() {
        cursor.shown = !cursor.shown
        if (cursor.shown && cursor.px == 0f && cursor.py == 0f) {
            cursor.px = root.width / 2f
            cursor.py = root.height / 2f
        }
        cursor.invalidate()
    }

    /** Sends a tap at the pointer to whatever view is showing (page or full-screen player). */
    private fun clickAtPointer() {
        val target: View = customView ?: web
        val now = SystemClock.uptimeMillis()
        for (action in intArrayOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val e = MotionEvent.obtain(now, now, action, cursor.px, cursor.py, 0)
            e.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            target.dispatchTouchEvent(e)
            e.recycle()
        }
    }

    private fun movePointer(dx: Float, dy: Float) {
        val step = 40f
        val nx = cursor.px + dx * step
        val ny = cursor.py + dy * step
        // Pushing against the top or bottom edge scrolls the page.
        if (ny < 0f && dy < 0f) web.scrollBy(0, (dy * step * 3).toInt())
        if (ny > root.height && dy > 0f) web.scrollBy(0, (dy * step * 3).toInt())
        cursor.px = nx.coerceIn(0f, root.width.toFloat())
        cursor.py = ny.coerceIn(0f, root.height.toFloat())
        cursor.invalidate()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode

        if (code == KeyEvent.KEYCODE_MENU) {
            if (event.action == KeyEvent.ACTION_UP) togglePointer()
            return true
        }

        if (!cursor.shown) {
            // Without the pointer, a long press on OK turns it on; a short one is a normal click.
            if (code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER) {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    okDownAt = SystemClock.uptimeMillis()
                    okLongHandled = false
                } else if (event.action == KeyEvent.ACTION_DOWN && !okLongHandled &&
                    SystemClock.uptimeMillis() - okDownAt > 800
                ) {
                    okLongHandled = true
                    togglePointer()
                    return true
                }
                if (okLongHandled) return true
            }
            return super.dispatchKeyEvent(event)
        }

        if (event.action == KeyEvent.ACTION_DOWN) {
            when (code) {
                KeyEvent.KEYCODE_DPAD_LEFT -> { movePointer(-1f, 0f); return true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { movePointer(1f, 0f); return true }
                KeyEvent.KEYCODE_DPAD_UP -> { movePointer(0f, -1f); return true }
                KeyEvent.KEYCODE_DPAD_DOWN -> { movePointer(0f, 1f); return true }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                    if (event.repeatCount == 0) clickAtPointer()
                    return true
                }
            }
        } else if (code in intArrayOf(
                KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_UP,
                KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER)
        ) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        when {
            customView != null -> web.webChromeClient?.onHideCustomView()
            web.canGoBack() -> web.goBack()
            else -> super.onBackPressed()
        }
    }
}
