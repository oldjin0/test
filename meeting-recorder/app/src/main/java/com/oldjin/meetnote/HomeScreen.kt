package com.oldjin.meetnote

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

private data class Item(val s: Session, val preview: String, val hasAudio: Boolean, val hay: String)

private enum class Sort(val label: String) {
    Newest("최신순"), Oldest("오래된순"), Name("이름순"), Longest("긴 녹음순")
}

private val Gold = Color(0xFFF4B400)

private fun previewOf(summary: String?, lines: List<Line>): String {
    if (summary != null) {
        val l = summary.lines().dropWhile { !it.contains("한 줄 요약") }.drop(1)
            .firstOrNull { it.isNotBlank() && !it.trim().startsWith("#") }
        if (!l.isNullOrBlank()) return l.trim().removePrefix("- ").removePrefix("* ").replace("**", "")
    }
    return lines.firstOrNull()?.text.orEmpty()
}

private fun dayStart(t: Long): Long = Calendar.getInstance().apply {
    timeInMillis = t
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

private fun groupOf(t: Long, now: Long): String {
    val days = ((dayStart(now) - dayStart(t)) / 86_400_000L).toInt()
    return when {
        days <= 0 -> "오늘"
        days == 1 -> "어제"
        days < 7 -> "최근 7일"
        else -> SimpleDateFormat("yyyy년 M월", Locale.KOREA).format(Date(t))
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(
    live: LiveState,
    version: Int,
    onRecord: () -> Unit,
    onOpenLive: () -> Unit,
    onOpen: (String) -> Unit,
    onSettings: () -> Unit,
) {
    val ctx = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    val all = remember(version, tick, live.phase) {
        Store.list(ctx).map {
            val summary = Store.loadSummary(ctx, it.id)
            val lines = Store.loadLines(ctx, it.id)
            Item(
                it, previewOf(summary, lines), Playback.hasAudio(ctx, it.id),
                (it.title + "\n" + summary.orEmpty() + "\n" + Store.toText(lines)).lowercase()
            )
        }
    }
    var query by remember { mutableStateOf("") }
    var onlyFav by remember { mutableStateOf(false) }
    var sort by remember { mutableStateOf(Sort.Newest) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var renaming by remember { mutableStateOf<Item?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { Updater.autoCheck(ctx) }
    val ps by rememberPlayState()
    val busy = live.phase == Phase.Recording || live.phase == Phase.Processing
    val selecting = selected.isNotEmpty()

    BackHandler(enabled = selecting) { selected = emptySet() }

    val shown = remember(all, query, onlyFav, sort) {
        val q = query.trim().lowercase()
        all.filter { (!onlyFav || it.s.favorite) && (q.isEmpty() || it.hay.contains(q)) }.let { l ->
            when (sort) {
                Sort.Newest -> l.sortedByDescending { it.s.startedAt }
                Sort.Oldest -> l.sortedBy { it.s.startedAt }
                Sort.Name -> l.sortedBy { it.s.title.lowercase() }
                Sort.Longest -> l.sortedByDescending { it.s.durationSec }
            }
        }
    }
    val now = remember { System.currentTimeMillis() }
    val rows: List<Any> = remember(shown, sort) {
        if (sort == Sort.Newest || sort == Sort.Oldest) {
            buildList {
                var last = ""
                shown.forEach {
                    val g = groupOf(it.s.startedAt, now)
                    if (g != last) { add(g); last = g }
                    add(it)
                }
            }
        } else shown
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            if (selecting) {
                TopAppBar(
                    title = { Text("${selected.size}개 선택", fontWeight = FontWeight.Bold) },
                    navigationIcon = { IconButton({ selected = emptySet() }) { Icon(Icons.Filled.Close, "선택 해제") } },
                    actions = {
                        IconButton({ selected = shown.map { it.s.id }.toSet() }) { Icon(Icons.Filled.Check, "전체 선택") }
                        if (selected.size == 1) IconButton({ renaming = all.firstOrNull { it.s.id == selected.first() } }) {
                            Icon(Icons.Filled.Edit, "이름 변경")
                        }
                        IconButton({ confirmDelete = true }) { Icon(Icons.Filled.Delete, "삭제") }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
                )
            } else {
                TopAppBar(
                    title = { Text("MeetNote", fontWeight = FontWeight.Bold) },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                    actions = { IconButton(onSettings) { Icon(Icons.Filled.Settings, "설정") } }
                )
            }
        },
        bottomBar = {
            Column {
                val playingItem = all.firstOrNull { it.s.id == ps.id }
                if (playingItem != null) {
                    Card(
                        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).clickable { onOpen(playingItem.s.id) },
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
                    ) {
                        Column {
                            Row(
                                Modifier.padding(start = 14.dp, end = 4.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(Modifier.weight(1f)) {
                                    Text(playingItem.s.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
                                    Text("${fmtTime((ps.posMs / 1000).toInt())} / ${fmtTime((ps.durMs / 1000).toInt())}", fontSize = 12.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
                                }
                                PlayButton(ps.playing, 40.dp) { Playback.toggle(ctx, playingItem.s.id) }
                                IconButton({ Playback.stop() }) { Icon(Icons.Filled.Close, "닫기", tint = MaterialTheme.colorScheme.onPrimaryContainer) }
                            }
                            LinearProgressIndicator(
                                progress = { if (ps.durMs > 0) ps.posMs.toFloat() / ps.durMs else 0f },
                                modifier = Modifier.fillMaxWidth().height(3.dp),
                                trackColor = Color.Transparent
                            )
                        }
                    }
                }
                if (!busy && !selecting) {
                    Box(Modifier.fillMaxWidth().padding(12.dp), contentAlignment = Alignment.Center) {
                        Row(
                            Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.primary).clickable(onClick = onRecord)
                                .padding(horizontal = 28.dp, vertical = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            Box(Modifier.size(12.dp).background(Color(0xFFFF6B6B), CircleShape))
                            Text("녹음 시작", color = MaterialTheme.colorScheme.onPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                        }
                    }
                }
            }
        }
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad)) {
            if (all.isNotEmpty()) {
                OutlinedTextField(
                    value = query, onValueChange = { query = it }, singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    placeholder = { Text("제목·요약·대화 내용 검색") },
                    leadingIcon = { Icon(Icons.Filled.Search, null) },
                    trailingIcon = { if (query.isNotEmpty()) IconButton({ query = "" }) { Icon(Icons.Filled.Close, "지우기") } },
                    shape = RoundedCornerShape(14.dp),
                    keyboardOptions = KeyboardOptions.Default
                )
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically
                ) {
                    FilterChip(selected = onlyFav, onClick = { onlyFav = !onlyFav }, label = { Text("즐겨찾기") },
                        leadingIcon = { Icon(Icons.Filled.Star, null, Modifier.size(16.dp), tint = Gold) })
                    FilterChip(selected = false, onClick = { sort = Sort.entries[(sort.ordinal + 1) % Sort.entries.size] },
                        label = { Text("정렬: ${sort.label}") })
                    Spacer(Modifier.weight(1f))
                    Text("${shown.size}개", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                item { UpdateBanner() }
                if (busy) item {
                    Card(
                        Modifier.fillMaxWidth().clickable(onClick = onOpenLive),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
                        shape = RoundedCornerShape(16.dp)
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Box(Modifier.size(10.dp).background(Color(0xFFE03131), CircleShape))
                            Column(Modifier.weight(1f)) {
                                Text(if (live.phase == Phase.Recording) "녹음 중 ${fmtTime(live.elapsedSec)}" else "처리 중", fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                                Text(live.status, fontSize = 13.sp, color = MaterialTheme.colorScheme.onPrimaryContainer)
                            }
                            Text("열기", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
                if (all.isEmpty() && !busy) item {
                    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("아직 회의 기록이 없어요", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                        Spacer(Modifier.height(6.dp))
                        Text("녹음을 시작하면 실시간으로 받아쓰고,\n화자를 나눠 요약까지 정리해 드려요.", color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
                    }
                } else if (all.isNotEmpty() && shown.isEmpty()) item {
                    Text("조건에 맞는 기록이 없어요", Modifier.fillMaxWidth().padding(top = 48.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
                }
                items(rows, key = { if (it is Item) it.s.id else "h_$it" }) { row ->
                    if (row is String) {
                        Text(row, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = 10.dp, start = 4.dp))
                    } else if (row is Item) {
                        val s = row.s
                        val isSel = s.id in selected
                        val thisPlaying = ps.id == s.id && ps.playing
                        Card(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).combinedClickable(
                                onClick = {
                                    if (selecting) selected = if (isSel) selected - s.id else selected + s.id else onOpen(s.id)
                                },
                                onLongClick = { selected = if (isSel) selected - s.id else selected + s.id }
                            ),
                            colors = CardDefaults.cardColors(
                                containerColor = if (isSel) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface
                            ),
                            shape = RoundedCornerShape(16.dp),
                            elevation = CardDefaults.cardElevation(0.dp)
                        ) {
                            Row(Modifier.padding(start = 12.dp, top = 12.dp, bottom = 12.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                if (selecting) {
                                    Box(
                                        Modifier.size(40.dp).clip(CircleShape)
                                            .background(if (isSel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant),
                                        contentAlignment = Alignment.Center
                                    ) { if (isSel) Icon(Icons.Filled.Check, null, tint = MaterialTheme.colorScheme.onPrimary) }
                                } else if (row.hasAudio) {
                                    PlayButton(thisPlaying, 40.dp) { Playback.toggle(ctx, s.id) }
                                } else Spacer(Modifier.size(40.dp))
                                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                    Text(s.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(
                                        SimpleDateFormat("M월 d일 HH:mm", Locale.KOREA).format(Date(s.startedAt)) + "  ·  " + fmtTime(s.durationSec),
                                        fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                    if (row.preview.isBlank() && row.hasAudio) Text(
                                        "아직 텍스트로 변환되지 않았어요 (열어서 변환 가능)", fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp)
                                    )
                                    if (row.preview.isNotBlank()) Text(
                                        row.preview, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                                        color = MaterialTheme.colorScheme.onSurface, modifier = Modifier.padding(top = 4.dp)
                                    )
                                }
                                IconButton({ Store.setFavorite(ctx, s.id, !s.favorite); tick++ }) {
                                    Icon(Icons.Filled.Star, "즐겨찾기", tint = if (s.favorite) Gold else MaterialTheme.colorScheme.outlineVariant)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    renaming?.let { item ->
        var text by remember(item.s.id) { mutableStateOf(item.s.title) }
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text("이름 변경") },
            text = { OutlinedTextField(text, { text = it }, singleLine = true) },
            confirmButton = {
                TextButton({ Store.rename(ctx, item.s.id, text); renaming = null; selected = emptySet(); tick++ }) { Text("저장") }
            },
            dismissButton = { TextButton({ renaming = null }) { Text("취소") } }
        )
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("${selected.size}개를 삭제할까요?") },
            text = { Text("앱 내부 기록이 삭제됩니다. 다운로드 폴더에 저장된 파일은 유지됩니다.") },
            confirmButton = {
                TextButton({
                    selected.forEach { Store.delete(ctx, it) }
                    selected = emptySet(); confirmDelete = false; tick++
                }) { Text("삭제") }
            },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("취소") } }
        )
    }
}

@Composable
fun PlayButton(playing: Boolean, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Box(
        Modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.primary).clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        if (playing) Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            repeat(2) { Box(Modifier.size(width = 4.dp, height = size * 0.36f).background(MaterialTheme.colorScheme.onPrimary)) }
        } else Icon(Icons.Filled.PlayArrow, "재생", tint = MaterialTheme.colorScheme.onPrimary)
    }
}
