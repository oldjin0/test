package com.example.manga_viewer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/// Keeps the app running continuously until the user explicitly stops it or
/// all coloring tasks finish: a high-priority foreground service with an ongoing
/// progress notification, a permanent partial wake lock (CPU keeps running with screen off),
/// and a high-perf Wi-Fi lock for online palette / hint models.
class ColorizeKeepAlive : Service() {
    companion object {
        private const val CHANNEL = "colorize"
        private const val NOTIFICATION = 7
        const val EXTRA_LEFT = "left"
        const val EXTRA_TITLE = "title"
        const val EXTRA_CURRENT = "current"
        const val EXTRA_TOTAL = "total"
        const val ACTION_EXIT = "com.example.manga_viewer.EXIT"

        /// Set by the activity: what quitting from the notification does.
        var onExit: (() -> Unit)? = null

        // All on the main thread (method calls and service callbacks).
        private var instance: ColorizeKeepAlive? = null
        private var starting = false // started, startForeground not run yet
        private var stopWanted = false
        private var latestLeft = 0
        private var latestTitle: String? = null
        private var latestCurrent = 0
        private var latestTotal = 0

        fun show(context: Context, left: Int, title: String? = null, current: Int = 0, total: Int = 0) {
            latestLeft = left
            latestTitle = title
            latestCurrent = current
            latestTotal = total
            stopWanted = false

            // Running: only the notification changes. Starting the service
            // again for every page is wasted, and one started and stopped
            // before it calls startForeground takes the app down.
            instance?.let {
                it.refresh(left, title, current, total)
                return
            }
            if (starting) return
            starting = true
            val intent = Intent(context, ColorizeKeepAlive::class.java).apply {
                putExtra(EXTRA_LEFT, left)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_CURRENT, current)
                putExtra(EXTRA_TOTAL, total)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun hide(context: Context) {
            if (starting && instance == null) {
                stopWanted = true // stopped once it has called startForeground
                return
            }
            context.stopService(Intent(context, ColorizeKeepAlive::class.java))
        }
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_EXIT) {
            onExit?.invoke()
            stopSelf()
            android.os.Process.killProcess(android.os.Process.myPid())
            return START_NOT_STICKY
        }
        instance = this
        starting = false

        val left = latestLeft.takeIf { it > 0 } ?: (intent?.getIntExtra(EXTRA_LEFT, 0) ?: 0)
        val title = latestTitle ?: intent?.getStringExtra(EXTRA_TITLE)
        val current = if (latestCurrent > 0) latestCurrent else (intent?.getIntExtra(EXTRA_CURRENT, 0) ?: 0)
        val total = if (latestTotal > 0) latestTotal else (intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0)

        refresh(left, title, current, total)

        // Acquire WakeLock without timeout so it runs until completion or explicit exit
        if (wake == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "manga_viewer:colorize").apply {
                setReferenceCounted(false)
                acquire()
            }
        }

        // Acquire Wi-Fi lock to ensure network calls (e.g. Gemini palette) never drop
        if (wifiLock == null) {
            try {
                val wm = applicationContext.getSystemService(WIFI_SERVICE) as? WifiManager
                wifiLock = wm?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "manga_viewer:colorize_wifi")?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (_: Exception) {}
        }

        if (stopWanted) {
            stopWanted = false
            stopSelf()
        }
        // START_STICKY ensures service recovery if memory temporarily pressure forces OS restart
        return START_STICKY
    }

    /// Shows progress in the notification (and keeps the service in the foreground).
    fun refresh(left: Int, title: String? = null, current: Int = 0, total: Int = 0) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL,
                "오토채색기 백그라운드 엔진",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "화면이 꺼져도 완료 시까지 중단 없는 일괄 채색"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
        val flagsImmutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flagsImmutable,
        )
        val exit = PendingIntent.getService(
            this, 1,
            Intent(this, ColorizeKeepAlive::class.java).setAction(ACTION_EXIT),
            flagsImmutable,
        )

        val notifTitle = if (!title.isNullOrEmpty()) "오토채색: $title" else "오토채색기 백그라운드 진행 중"
        val notifText = if (total > 0) {
            val pct = (current * 100 / total).coerceIn(0, 100)
            "$current / $total 쪽 ($pct%) · 화면이 꺼져도 완성까지 계속됩니다"
        } else {
            "남은 페이지 ${left}쪽 · 화면이 꺼져도 완성까지 계속됩니다"
        }

        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle(notifTitle)
            .setContentText(notifText)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, "작업 중지 및 앱 종료", exit)

        if (total > 0) {
            builder.setProgress(total, current, false)
        }

        val notification = builder.build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION, notification)
        }
    }

    override fun onDestroy() {
        instance = null
        starting = false
        wake?.let { if (it.isHeld) it.release() }
        wake = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        super.onDestroy()
    }
}
