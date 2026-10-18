package com.example.ytmp3

import android.content.ContentValues
import android.content.Intent
import android.os.Bundle
import android.provider.MediaStore
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {

    private val qualities = listOf(
        "64 kbps (용량 최소)" to "64K",
        "128 kbps (보통)" to "128K",
        "192 kbps (좋음)" to "192K",
        "256 kbps (아주 좋음)" to "256K",
        "320 kbps (최고)" to "320K",
    )

    private lateinit var urlInput: EditText
    private lateinit var spinner: Spinner
    private lateinit var convertBtn: Button
    private lateinit var updateBtn: Button
    private lateinit var progress: ProgressBar
    private lateinit var status: TextView

    @Volatile private var ready = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        urlInput = findViewById(R.id.urlInput)
        spinner = findViewById(R.id.qualitySpinner)
        convertBtn = findViewById(R.id.convertBtn)
        updateBtn = findViewById(R.id.updateBtn)
        progress = findViewById(R.id.progress)
        status = findViewById(R.id.status)

        spinner.adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_dropdown_item, qualities.map { it.first }
        )
        spinner.setSelection(2)

        if (intent?.action == Intent.ACTION_SEND) {
            urlInput.setText(intent.getStringExtra(Intent.EXTRA_TEXT).orEmpty())
        }

        convertBtn.setOnClickListener { convert() }
        updateBtn.setOnClickListener { updateYtDlp() }

        setBusy(true, "엔진 초기화 중...")
        thread {
            try {
                YoutubeDL.getInstance().init(applicationContext)
                FFmpeg.getInstance().init(applicationContext)
                ready = true
                ui { setBusy(false, "준비됨") }
            } catch (e: Exception) {
                ui { setBusy(false, "초기화 실패: ${e.message}") }
            }
        }
    }

    private fun convert() {
        val url = urlInput.text.toString().trim()
        if (!ready) return setStatus("아직 초기화 중입니다")
        if (url.isEmpty()) return setStatus("링크를 입력하세요")
        val bitrate = qualities[spinner.selectedItemPosition].second

        setBusy(true, "변환 시작...")
        thread {
            val workDir = File(cacheDir, "dl").apply { deleteRecursively(); mkdirs() }
            try {
                val request = YoutubeDLRequest(url).apply {
                    addOption("--no-playlist")
                    addOption("-x")
                    addOption("--audio-format", "mp3")
                    addOption("--audio-quality", bitrate)
                    addOption("-o", "${workDir.absolutePath}/%(title)s.%(ext)s")
                }
                YoutubeDL.getInstance().execute(request, "ytmp3") { p, _, line ->
                    ui {
                        progress.progress = p.toInt().coerceIn(0, 100)
                        status.text = line.trim().take(120)
                    }
                }
                val mp3 = workDir.listFiles { f -> f.extension == "mp3" }?.firstOrNull()
                    ?: throw IllegalStateException("mp3 파일이 생성되지 않았습니다")
                saveToMusic(mp3)
                ui { setBusy(false, "완료! 음악 > YTmp3 폴더에 저장됨\n${mp3.name}") }
            } catch (e: Exception) {
                ui { setBusy(false, "실패: ${e.message}") }
            } finally {
                workDir.deleteRecursively()
            }
        }
    }

    private fun saveToMusic(file: File) {
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mpeg")
            put(MediaStore.Audio.Media.RELATIVE_PATH, "Music/YTmp3")
        }
        val uri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("저장 실패")
        contentResolver.openOutputStream(uri)!!.use { out ->
            file.inputStream().use { it.copyTo(out) }
        }
    }

    private fun updateYtDlp() {
        if (!ready) return setStatus("아직 초기화 중입니다")
        setBusy(true, "yt-dlp 업데이트 중...")
        thread {
            try {
                val r = YoutubeDL.getInstance()
                    .updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.STABLE)
                ui { setBusy(false, "업데이트 결과: $r") }
            } catch (e: Exception) {
                ui { setBusy(false, "업데이트 실패: ${e.message}") }
            }
        }
    }

    private fun setBusy(busy: Boolean, msg: String) {
        convertBtn.isEnabled = !busy
        updateBtn.isEnabled = !busy
        if (!busy) progress.progress = 0
        status.text = msg
    }

    private fun setStatus(msg: String) { status.text = msg }

    private fun ui(block: () -> Unit) = runOnUiThread(block)
}
