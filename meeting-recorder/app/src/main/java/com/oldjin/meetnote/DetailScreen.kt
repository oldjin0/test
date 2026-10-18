package com.oldjin.meetnote

import android.content.Intent
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(id: String, onBack: () -> Unit) {
    val ctx = LocalContext.current
    var session by remember(id) { mutableStateOf(Store.readMeta(ctx, id)) }
    val lines = remember(id) { Store.loadLines(ctx, id) }
    val summary = remember(id) { Store.loadSummary(ctx, id) }
    val wav = remember(id) { Store.file(ctx, id, "audio.wav") }
    var tab by remember { mutableIntStateOf(if (summary != null) 0 else 1) }
    var confirmDelete by remember { mutableStateOf(false) }

    val ps by rememberPlayState()
    val isThis = ps.id == id
    val playing = isThis && ps.playing
    val posMs = if (isThis) ps.posMs else 0L
    val durMs = if (isThis) ps.durMs else 0L
    val curSec = (posMs / 1000).toInt()
    val activeIdx = if (isThis && (playing || posMs > 0)) lines.indexOfLast { it.sec <= curSec } else -1
    var renaming by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(session?.title ?: "회의", fontWeight = FontWeight.Bold, maxLines = 1, modifier = Modifier.clickable { renaming = true }) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로") } },
                actions = {
                    IconButton({ renaming = true }) { Icon(Icons.Filled.Edit, "이름 변경") }
                    IconButton({
                        session?.let { Store.setFavorite(ctx, id, !it.favorite); session = Store.readMeta(ctx, id) }
                    }) {
                        Icon(Icons.Filled.Star, "즐겨찾기", tint = if (session?.favorite == true) Color(0xFFF4B400) else MaterialTheme.colorScheme.outlineVariant)
                    }
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
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        PlayButton(playing, 48.dp) { Playback.toggle(ctx, id) }
                        Column(Modifier.weight(1f)) {
                            Slider(
                                value = if (durMs > 0) (posMs.toFloat() / durMs).coerceIn(0f, 1f) else 0f,
                                onValueChange = { f ->
                                    if (Playback.load(ctx, id)) {
                                        val d = Playback.snapshot().durMs
                                        if (d > 0) Playback.seekTo(ctx, id, (f * d).toLong())
                                    }
                                }
                            )
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                Text(fmtTime(curSec), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(fmtTime((durMs / 1000).toInt().takeIf { it > 0 } ?: (session?.durationSec ?: 0)), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                        ChipText("-10초") { Playback.skip(ctx, id, -10_000) }
                        ChipText("+10초") { Playback.skip(ctx, id, 10_000) }
                        ChipText("${ps.speed.let { if (it % 1f == 0f) it.toInt().toString() else it.toString() }}x") { Playback.cycleSpeed() }
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
                                if (wav.exists()) Playback.seekTo(ctx, id, l.sec * 1000L, play = true)
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

    if (renaming) {
        var text by remember { mutableStateOf(session?.title.orEmpty()) }
        AlertDialog(
            onDismissRequest = { renaming = false },
            title = { Text("이름 변경") },
            text = { OutlinedTextField(text, { text = it }, singleLine = true) },
            confirmButton = {
                TextButton({ Store.rename(ctx, id, text); session = Store.readMeta(ctx, id); renaming = false }) { Text("저장") }
            },
            dismissButton = { TextButton({ renaming = false }) { Text("취소") } }
        )
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

@Composable
private fun ChipText(label: String, onClick: () -> Unit) {
    Text(
        label, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary, fontSize = 14.sp,
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp)
    )
}
