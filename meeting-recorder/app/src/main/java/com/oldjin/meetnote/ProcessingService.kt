package com.oldjin.meetnote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/** 이미 저장된 녹음을 나중에 텍스트 변환·요약한다. 화면을 꺼도 끝날 때까지 계속된다. */
class ProcessingService : Service() {
    companion object {
        const val EXTRA_ID = "id"
        const val EXTRA_MODE = "mode" // "ai"(기본) 또는 "whisper"
        private const val CHANNEL = "processing"
        private const val NOTIF_ID = 3
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val active = AtomicInteger(0)
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra(EXTRA_ID)
        val mode = intent?.getStringExtra(EXTRA_MODE) ?: "ai"
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, "텍스트 변환", NotificationManager.IMPORTANCE_LOW))
        startForeground(NOTIF_ID, notification("텍스트 변환 중…"), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        if (id == null || id in Analysis.status.value || Live.state.value.sessionId == id && Live.busy) {
            if (active.get() == 0) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
            return START_NOT_STICKY
        }
        if (wake == null) {
            wake = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "meetnote:processing").apply { acquire(2 * 60 * 60 * 1000L) }
        }
        active.incrementAndGet()
        Analysis.set(id, "준비 중…")
        scope.launch {
            var warning: String? = null
            try {
                warning = if (mode == "whisper") {
                    Analysis.set(id, "Whisper 모델 불러오는 중…")
                    val lines = LocalWhisper.transcribe(this@ProcessingService, id) { Analysis.set(id, "Whisper 기기 내 변환 중 $it%") }
                    if (lines.isEmpty()) "Whisper가 인식한 음성이 없어요." else {
                        Store.saveLines(this@ProcessingService, id, lines)
                        Store.setEngine(this@ProcessingService, id, "whisper")
                        Analysis.set(id, "기기 내 요약 작성 중…")
                        LocalSummary.write(this@ProcessingService, id)
                        null
                    }
                } else Pipeline.analyze(this@ProcessingService, id) { Analysis.set(id, it) }
                Store.readMeta(this@ProcessingService, id)?.let {
                    Analysis.set(id, "다운로드 폴더에 저장 중…")
                    try { Exporter.toDownloads(this@ProcessingService, it) } catch (_: Exception) {}
                }
            } catch (e: Exception) {
                warning = "처리 중 오류: ${e.message?.take(120)}"
            } finally {
                Analysis.finish(id, warning)
                if (active.decrementAndGet() == 0) {
                    wake?.takeIf { it.isHeld }?.release()
                    wake = null
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_stat_mic)
            .setContentTitle("MeetNote").setContentText(text).setOngoing(true).setContentIntent(open).build()
    }

    override fun onDestroy() {
        wake?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }
}
