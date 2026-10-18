package com.example.manga_viewer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/// Keeps the app running while pages are colorized in the background: a
/// foreground service (Android does not freeze or kill such an app when the
/// screen goes off or another app is in front) with a partial wake lock (the
/// processor keeps working with the screen off). Its notification shows how
/// many pages are left and offers to quit the app.
class ColorizeKeepAlive : Service() {
    companion object {
        private const val CHANNEL = "colorize"
        private const val NOTIFICATION = 7
        const val EXTRA_LEFT = "left"
        const val ACTION_EXIT = "com.example.manga_viewer.EXIT"

        /// Set by the activity: what quitting from the notification does.
        var onExit: (() -> Unit)? = null

        fun show(context: Context, left: Int) {
            val intent = Intent(context, ColorizeKeepAlive::class.java).putExtra(EXTRA_LEFT, left)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun hide(context: Context) {
            context.stopService(Intent(context, ColorizeKeepAlive::class.java))
        }
    }

    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_EXIT) {
            onExit?.invoke()
            stopSelf()
            android.os.Process.killProcess(android.os.Process.myPid())
            return START_NOT_STICKY
        }
        val left = intent?.getIntExtra(EXTRA_LEFT, 0) ?: 0
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "백그라운드 채색", NotificationManager.IMPORTANCE_LOW),
            )
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
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle("백그라운드 채색 중")
            .setContentText("남은 페이지 ${left}쪽 · 화면을 꺼도 계속됩니다")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, "앱 종료", exit)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION, notification)
        }
        if (wake == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "manga_viewer:colorize").apply {
                setReferenceCounted(false)
                acquire(12 * 60 * 60 * 1000L) // a safety limit; released when done
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wake?.let { if (it.isHeld) it.release() }
        wake = null
        super.onDestroy()
    }
}
