package com.oldjin.meetnote

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class Session(val id: String, val title: String, val startedAt: Long, val durationSec: Int)

const val SAMPLE_RATE = 16000

object Wav {
    fun header(dataLen: Long): ByteArray {
        val b = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt((36 + dataLen).toInt()).put("WAVE".toByteArray())
        b.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
        b.putInt(SAMPLE_RATE).putInt(SAMPLE_RATE * 2).putShort(2).putShort(16)
        b.put("data".toByteArray()).putInt(dataLen.toInt())
        return b.array()
    }

    fun wrap(pcm: ByteArray): ByteArray = header(pcm.size.toLong()) + pcm

    fun fromPcmFile(pcm: File, wav: File) {
        FileOutputStream(wav).use { out ->
            out.write(header(pcm.length()))
            FileInputStream(pcm).use { it.copyTo(out) }
        }
        pcm.delete()
    }
}

/** 녹음 데이터는 앱 내부 저장소에 보관하고, 완료되면 다운로드 폴더로 내보낸다. */
object Store {
    private fun root(ctx: Context) = File(ctx.filesDir, "sessions").apply { mkdirs() }
    fun dir(ctx: Context, id: String) = File(root(ctx), id).apply { mkdirs() }
    fun file(ctx: Context, id: String, name: String) = File(dir(ctx, id), name)

    fun create(ctx: Context): Session {
        val now = System.currentTimeMillis()
        val id = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(now))
        val title = "회의 " + SimpleDateFormat("M월 d일 HH:mm", Locale.KOREA).format(Date(now))
        return Session(id, title, now, 0).also { writeMeta(ctx, it) }
    }

    fun writeMeta(ctx: Context, s: Session) {
        file(ctx, s.id, "meta.json").writeText(
            JSONObject().put("title", s.title).put("startedAt", s.startedAt).put("durationSec", s.durationSec).toString()
        )
    }

    fun readMeta(ctx: Context, id: String): Session? {
        val f = file(ctx, id, "meta.json")
        if (!f.exists()) return null
        return try {
            val j = JSONObject(f.readText())
            Session(id, j.optString("title", id), j.optLong("startedAt"), j.optInt("durationSec"))
        } catch (e: Exception) {
            null
        }
    }

    /** 최신순 목록. 비정상 종료로 남은 PCM은 WAV로 복구한다. */
    fun list(ctx: Context): List<Session> {
        val active = if (Live.busy) Live.state.value.sessionId else null
        return root(ctx).listFiles().orEmpty().filter { it.isDirectory }.mapNotNull { d ->
            val pcm = File(d, "audio.pcm")
            if (pcm.exists() && d.name != active) {
                val wav = File(d, "audio.wav")
                if (!wav.exists()) {
                    val sec = (pcm.length() / (SAMPLE_RATE * 2)).toInt()
                    Wav.fromPcmFile(pcm, wav)
                    readMeta(ctx, d.name)?.let { writeMeta(ctx, it.copy(durationSec = sec)) }
                }
            }
            readMeta(ctx, d.name)
        }.sortedByDescending { it.startedAt }
    }

    fun delete(ctx: Context, id: String) {
        dir(ctx, id).deleteRecursively()
    }

    fun saveLines(ctx: Context, id: String, lines: List<Line>) {
        val arr = JSONArray()
        lines.forEach { arr.put(JSONObject().put("sec", it.sec).put("speaker", it.speaker).put("text", it.text)) }
        file(ctx, id, "transcript.json").writeText(arr.toString())
        file(ctx, id, "transcript.txt").writeText(toText(lines))
    }

    fun loadLines(ctx: Context, id: String): List<Line> {
        val f = file(ctx, id, "transcript.json")
        if (!f.exists()) return emptyList()
        return try {
            val a = JSONArray(f.readText())
            (0 until a.length()).map {
                val o = a.getJSONObject(it)
                Line(o.optInt("sec"), o.optString("speaker"), o.optString("text"))
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun loadSummary(ctx: Context, id: String): String? =
        file(ctx, id, "summary.txt").takeIf { it.exists() }?.readText()

    fun toText(lines: List<Line>) = lines.joinToString("\n") { "[${fmtTime(it.sec)}] ${it.speaker}: ${it.text}" }
}

object Exporter {
    private const val FOLDER = "MeetNote"

    /** 녹음(wav) · 전사(txt) · 요약(txt)을 Download/MeetNote 에 저장한다. */
    fun toDownloads(ctx: Context, s: Session): Int {
        val items = listOf(
            Triple("audio.wav", "_audio.wav", "audio/wav"),
            Triple("transcript.txt", "_transcript.txt", "text/plain"),
            Triple("summary.txt", "_summary.txt", "text/plain"),
        )
        val resolver = ctx.contentResolver
        val rel = "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER"
        var saved = 0
        for ((name, suffix, mime) in items) {
            val src = Store.file(ctx, s.id, name)
            if (!src.exists() || src.length() == 0L) continue
            val display = "MeetNote_${s.id}$suffix"
            try {
                resolver.delete(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                    arrayOf(display, "$rel%")
                )
            } catch (_: Exception) {
            }
            val v = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, display)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v) ?: continue
            try {
                resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                v.clear()
                v.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, v, null, null)
                saved++
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
            }
        }
        return saved
    }
}
