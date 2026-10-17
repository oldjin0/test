package com.oldjin.meetnote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.IBinder
import android.os.PowerManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.sqrt

private class Chunk(val offsetSec: Int, val pcm: ByteArray)

/**
 * 포그라운드 서비스: 화면이 꺼지거나 다른 앱을 써도 종료(중지)할 때까지
 * 녹음 → 실시간 전사 → 최종 화자 분석 → 요약 → 다운로드 폴더 저장을 계속한다.
 */
class RecordingService : Service() {
    companion object {
        const val ACTION_START = "com.oldjin.meetnote.START"
        const val ACTION_STOP = "com.oldjin.meetnote.STOP"
        private const val CHANNEL = "recording"
        private const val NOTIF_ID = 1
        private const val DONE_ID = 2
        private const val CHUNK_SEC = 15
        private const val SILENCE_RMS = 120.0
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var wake: PowerManager.WakeLock? = null
    private var job: Job? = null
    @Volatile private var stopRequested = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopRequested = true
                if (job == null) stopSelf()
            }
            else -> if (job == null) begin()
        }
        return START_NOT_STICKY
    }

    private fun begin() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "녹음", NotificationManager.IMPORTANCE_LOW))
        startForeground(NOTIF_ID, notification("녹음 중 — 화면을 꺼도 계속됩니다", true), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        wake = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "meetnote:recording").apply { acquire(6 * 60 * 60 * 1000L) }
        stopRequested = false
        val s = Store.create(this)
        Live.state.value = LiveState(phase = Phase.Recording, sessionId = s.id, status = "녹음 중")
        job = scope.launch(Dispatchers.IO) {
            try {
                runSession(s)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Live.update { it.copy(phase = Phase.Done, status = "오류", warning = e.message) }
            } finally {
                wake?.takeIf { it.isHeld }?.release()
                stopForeground(STOP_FOREGROUND_REMOVE)
                job = null
                stopSelf()
            }
        }
    }

    private fun notification(text: String, withStop: Boolean): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val b = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_mic)
            .setContentTitle("MeetNote")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (withStop) {
            val stop = PendingIntent.getService(
                this, 1, Intent(this, RecordingService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE
            )
            b.addAction(Notification.Action.Builder(null, "녹음 종료", stop).build())
        }
        return b.build()
    }

    private fun notify(text: String, withStop: Boolean) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification(text, withStop))
    }

    private fun status(s: String) = Live.update { it.copy(status = s) }

    private fun rms(b: ByteArray, len: Int = b.size): Double {
        val sb = ByteBuffer.wrap(b, 0, len).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val n = sb.remaining()
        if (n == 0) return 0.0
        var sum = 0.0
        while (sb.hasRemaining()) {
            val v = sb.get().toDouble()
            sum += v * v
        }
        return sqrt(sum / n)
    }

    private suspend fun runSession(s: Session) {
        val key = Prefs.apiKey(this)
        val client = key?.let { GeminiClient(it, Prefs.model(this)) }
        val dir = Store.dir(this, s.id)
        val pcmFile = File(dir, "audio.pcm")
        val chunks = Channel<Chunk>(Channel.UNLIMITED)
        val worker = scope.launch(Dispatchers.IO) {
            for (c in chunks) handleChunk(client, c)
        }

        var total = 0L
        val rec = AudioRecord(
            MediaRecorder.AudioSource.MIC, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            max(AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT), SAMPLE_RATE * 2)
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            chunks.close()
            Store.delete(this, s.id)
            Live.update { it.copy(phase = Phase.Done, sessionId = null, status = "오류", warning = "마이크를 열 수 없습니다") }
            return
        }
        try {
            rec.startRecording()
            val out = BufferedOutputStream(FileOutputStream(pcmFile), 64 * 1024)
            val buf = ByteArray(4096)
            val chunkBuf = ByteArrayOutputStream()
            var chunkStart = 0
            var flushed = 0L
            val chunkBytes = CHUNK_SEC * SAMPLE_RATE * 2
            fun sendChunk() {
                if (chunkBuf.size() >= SAMPLE_RATE * 2) { // 1초 미만 조각은 버림
                    Live.update { it.copy(pending = it.pending + 1) }
                    chunks.trySend(Chunk(chunkStart, chunkBuf.toByteArray()))
                }
                chunkStart = (total / (SAMPLE_RATE * 2)).toInt()
                chunkBuf.reset()
            }
            try {
                while (!stopRequested) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) break
                    if (n == 0) continue
                    out.write(buf, 0, n)
                    chunkBuf.write(buf, 0, n)
                    total += n
                    if (total - flushed >= SAMPLE_RATE * 2) {
                        out.flush(); flushed = total
                    }
                    val level = (rms(buf, n) / 6000.0).coerceIn(0.0, 1.0).toFloat()
                    Live.update { it.copy(elapsedSec = (total / (SAMPLE_RATE * 2)).toInt(), level = level) }
                    if (chunkBuf.size() >= chunkBytes) sendChunk()
                }
                sendChunk()
            } finally {
                out.close()
            }
        } finally {
            try { rec.stop() } catch (_: Exception) {}
            rec.release()
        }
        chunks.close()

        Live.update { it.copy(phase = Phase.Processing, level = 0f, status = "남은 구간 변환 중…") }
        notify("처리 중 — 앱을 닫아도 계속됩니다", false)
        worker.join()

        val wav = File(dir, "audio.wav")
        Wav.fromPcmFile(pcmFile, wav)
        val duration = (total / (SAMPLE_RATE * 2)).toInt()
        Store.writeMeta(this, s.copy(durationSec = duration))

        var lines = Live.state.value.lines.filter { it.speaker != "!" }
        var warning: String? = null
        if (client == null) {
            warning = "API 키가 없어 텍스트 변환을 하지 못했습니다"
        } else if (duration >= 2) {
            status("최종 화자 분석 중…")
            try {
                val finalLines = client.transcribeFull(wav)
                if (finalLines.isNotEmpty()) lines = finalLines
            } catch (e: Exception) {
                warning = "최종 분석 실패 — 실시간 초안을 저장했습니다 (${e.message})"
            }
            Live.update { it.copy(lines = lines) }
            if (lines.isNotEmpty()) {
                status("요약 작성 중…")
                try {
                    File(dir, "summary.txt").writeText(client.summarize(Store.toText(lines)))
                } catch (e: Exception) {
                    warning = (warning?.plus(" / ") ?: "") + "요약 실패 (${e.message})"
                }
            }
        }
        Store.saveLines(this, s.id, lines)

        status("다운로드 폴더에 저장 중…")
        val saved = try {
            Exporter.toDownloads(this, s.copy(durationSec = duration))
        } catch (e: Exception) {
            0
        }
        if (saved == 0) warning = (warning?.plus(" / ") ?: "") + "다운로드 폴더 저장 실패"
        Live.update { it.copy(phase = Phase.Done, status = "완료", warning = warning) }

        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(
            DONE_ID,
            Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_stat_mic)
                .setContentTitle("회의록이 준비되었습니다").setContentText(s.title).setAutoCancel(true)
                .setContentIntent(
                    PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
                ).build()
        )
    }

    private fun handleChunk(client: GeminiClient?, c: Chunk) {
        try {
            if (client == null || rms(c.pcm) < SILENCE_RMS) return
            val context = Live.state.value.lines.filter { it.speaker != "!" }.takeLast(8)
            val lines = client.transcribeChunk(Wav.wrap(c.pcm), c.offsetSec, context)
            Live.update { it.copy(lines = it.lines + lines) }
        } catch (e: Exception) {
            Live.update {
                it.copy(
                    failed = it.failed + 1,
                    lines = it.lines + Line(c.offsetSec, "!", "이 구간은 실시간 변환에 실패했습니다. 종료 후 최종 분석에서 다시 시도합니다.")
                )
            }
        } finally {
            Live.update { it.copy(pending = max(0, it.pending - 1)) }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        wake?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }
}
