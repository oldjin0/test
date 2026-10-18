package com.oldjin.meetnote

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.delay

data class PlayState(
    val id: String? = null,
    val playing: Boolean = false,
    val posMs: Long = 0,
    val durMs: Long = 0,
    val speed: Float = 1f,
)

/** 앱 전역 플레이어. 화면을 이동해도 재생이 이어지고, 화면이 꺼져도 CPU 잠금을 유지한다. */
object Playback {
    private var player: ExoPlayer? = null
    var currentId: String? = null
        private set
    var speed = 1f
        private set

    private fun p(ctx: Context): ExoPlayer = player ?: ExoPlayer.Builder(ctx.applicationContext).build().apply {
        setWakeMode(C.WAKE_MODE_LOCAL)
        setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true
        )
    }.also { player = it }

    fun hasAudio(ctx: Context, id: String) = Store.file(ctx, id, "audio.wav").exists()

    fun load(ctx: Context, id: String): Boolean {
        val f = Store.file(ctx, id, "audio.wav")
        if (!f.exists()) return false
        if (currentId != id) {
            p(ctx).apply {
                setMediaItem(MediaItem.fromUri(Uri.fromFile(f)))
                prepare()
                setPlaybackSpeed(speed)
            }
            currentId = id
        }
        return true
    }

    fun toggle(ctx: Context, id: String) {
        if (!load(ctx, id)) return
        val pl = p(ctx)
        if (pl.isPlaying) pl.pause() else {
            if (pl.playbackState == Player.STATE_ENDED) pl.seekTo(0)
            pl.play()
        }
    }

    fun seekTo(ctx: Context, id: String, ms: Long, play: Boolean = false) {
        if (!load(ctx, id)) return
        p(ctx).seekTo(ms.coerceAtLeast(0))
        if (play) p(ctx).play()
    }

    fun skip(ctx: Context, id: String, deltaMs: Long) {
        if (!load(ctx, id)) return
        val pl = p(ctx)
        val dur = pl.duration.takeIf { it > 0 } ?: Long.MAX_VALUE
        pl.seekTo((pl.currentPosition + deltaMs).coerceIn(0, dur))
    }

    fun cycleSpeed() {
        speed = when (speed) { 1f -> 1.25f; 1.25f -> 1.5f; 1.5f -> 2f; else -> 1f }
        player?.setPlaybackSpeed(speed)
    }

    fun stop() {
        player?.run { stop(); clearMediaItems() }
        currentId = null
    }

    fun snapshot(): PlayState {
        val pl = player ?: return PlayState(speed = speed)
        return PlayState(
            id = currentId,
            playing = pl.isPlaying,
            posMs = pl.currentPosition,
            durMs = pl.duration.coerceAtLeast(0),
            speed = speed,
        )
    }
}

@Composable
fun rememberPlayState(): State<PlayState> = produceState(Playback.snapshot()) {
    while (true) {
        value = Playback.snapshot()
        delay(250)
    }
}
