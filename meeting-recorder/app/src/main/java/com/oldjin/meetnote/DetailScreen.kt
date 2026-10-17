package com.oldjin.meetnote

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(id: String, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val session = remember(id) { Store.readMeta(ctx, id) }
    val lines = remember(id) { Store.loadLines(ctx, id) }
    val summary = remember(id) { Store.loadSummary(ctx, id) }
    val wav = remember(id) { Store.file(ctx, id, "audio.wav") }
    var tab by remember { mutableIntStateOf(if (summary != null) 0 else 1) }
    var confirmDelete by remember { mutableStateOf(false) }

    val player = remember(id) {
        ExoPlayer.Builder(ctx).build().apply {
            if (wav.exists()) {
                setMediaItem(MediaItem.fromUri(Uri.fromFile(wav)))
                prepare()
            }
        }
    }
    DisposableEffect(player) { onDispose { player.release() } }
    var playing by remember { mutableStateOf(false) }
    var posMs by remember { mutableStateOf(0L) }
    var durMs by remember { mutableStateOf(0L) }
    var speed by remember { mutableFloatStateOf(1f) }
    LaunchedEffect(player) {
        while (true) {
            playing = player.isPlaying
            posMs = player.currentPosition
            durMs = player.duration.coerceAtLeast(0L)
            delay(250)
        }
    }
    val curSec = (posMs / 1000).toInt()
    val activeIdx = if (playing || posMs > 0) lines.indexOfLast { it.sec <= curSec } else -1

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(session?.title ?: "회의", fontWeight = FontWeight.Bold, maxLines = 1) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로") } },
                actions = {
                    IconButton({
                        val text = buildString {
                            summary?.let { append(it).append("\n\n") }
                            append("── 전사 ──\n").append(Store.toText(lines))
                        }
                        ctx.startActivity(
                            Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), "공유")
                        )
                    }) { Icon(Icons.Filled.Share, "공유") }
                    IconButton({ confirmDelete = true }) { Icon(Icons.Filled.Delete, "삭제") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)
            )
        }
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(horizontal = 16.dp)) {
            if (wav.exists()) {
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surface).padding(12.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(
                            Modifier.size(44.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary)
                                .clickable { if (playing) player.pause() else player.play() },
                            contentAlignment = Alignment.Center
                        ) {
                            if (playing) Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                repeat(2) { Box(Modifier.size(width = 4.dp, height = 16.dp).background(MaterialTheme.colorScheme.onPrimary)) }
                            } else Icon(Icons.Filled.PlayArrow, "재생", tint = MaterialTheme.colorScheme.onPrimary)
                        }
                        Column(Modifier.weight(1f)) {
                            Slider(
                                value = if (durMs > 0) posMs.toFloat() / durMs else 0f,
                                onValueChange = { if (durMs > 0) { player.seekTo((it * durMs).toLong()); posMs = player.currentPosition } }
                            )
                            Text("${fmtTime(curSec)} / ${fmtTime((durMs / 1000).toInt())}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text(
                            "${if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()}x",
                            fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable {
                                speed = when (speed) { 1f -> 1.25f; 1.25f -> 1.5f; 1.5f -> 2f; else -> 1f }
                                player.setPlaybackSpeed(speed)
                            }.padding(8.dp)
                        )
                    }
                }
                Spacer(Modifier.height(10.dp))
            }

            TabRow(selectedTabIndex = tab, containerColor = MaterialTheme.colorScheme.background) {
                Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("요약") })
                Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("전사 (${lines.size})") })
            }

            Box(Modifier.weight(1f).fillMaxWidth().padding(top = 10.dp)) {
                if (tab == 0) {
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(4.dp)) {
                        if (summary != null) MarkdownText(summary)
                        else Text("요약이 없습니다. (API 키가 없거나 변환에 실패했을 수 있어요)", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                } else if (lines.isEmpty()) {
                    Text("전사 내용이 없습니다", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(4.dp))
                } else {
                    LazyColumn(Modifier.fillMaxSize()) {
                        itemsIndexed(lines) { i, l ->
                            LineRow(l, highlighted = i == activeIdx, onClick = {
                                if (wav.exists()) { player.seekTo(l.sec * 1000L); player.play() }
                            })
                        }
                    }
                }
            }

            OutlinedButton(
                onClick = {
                    val n = session?.let { Exporter.toDownloads(ctx, it) } ?: 0
                    Toast.makeText(ctx, if (n > 0) "다운로드/MeetNote 폴더에 ${n}개 파일 저장됨" else "저장 실패", Toast.LENGTH_LONG).show()
                },
                modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp)
            ) { Text("다운로드 폴더에 다시 저장 (녹음·전사·요약)") }
        }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("이 회의를 삭제할까요?") },
            text = { Text("앱 내부 기록이 삭제됩니다. 다운로드 폴더에 저장된 파일은 유지됩니다.") },
            confirmButton = { TextButton({ Store.delete(ctx, id); confirmDelete = false; onBack() }) { Text("삭제") } },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("취소") } }
        )
    }
}
