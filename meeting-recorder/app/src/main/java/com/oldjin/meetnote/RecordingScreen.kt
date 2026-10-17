package com.oldjin.meetnote

import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingScreen(live: LiveState, onBack: () -> Unit, onStop: () -> Unit, onResult: () -> Unit) {
    val listState = rememberLazyListState()
    LaunchedEffect(live.lines.size) {
        if (live.lines.isNotEmpty()) listState.animateScrollToItem(live.lines.size - 1)
    }
    val level by animateFloatAsState(live.level, label = "level")
    val recording = live.phase == Phase.Recording
    val processing = live.phase == Phase.Processing
    val done = live.phase == Phase.Done

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(if (done) "완료" else if (processing) "처리 중" else "녹음 중", fontWeight = FontWeight.Bold) },
                navigationIcon = { IconButton(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)
            )
        }
    ) { pad ->
        Column(Modifier.fillMaxSize().padding(pad).padding(horizontal = 16.dp)) {
            Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(fmtTime(live.elapsedSec), fontSize = 44.sp, fontWeight = FontWeight.Light, color = MaterialTheme.colorScheme.onBackground)
                Spacer(Modifier.height(8.dp))
                if (recording) {
                    LinearProgressIndicator(
                        progress = { level }, modifier = Modifier.fillMaxWidth(0.6f).height(6.dp).clip(RoundedCornerShape(3.dp)),
                        trackColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                    Spacer(Modifier.height(10.dp))
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (processing) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                    Text(
                        live.status + if (live.pending > 0) " · 변환 대기 ${live.pending}" else "",
                        fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                if (recording) {
                    Spacer(Modifier.height(4.dp))
                    Text("화면을 끄거나 다른 앱을 써도 계속 녹음됩니다", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            Box(
                Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(MaterialTheme.colorScheme.surface)
            ) {
                if (live.lines.isEmpty()) {
                    Text(
                        if (recording) "말씀하시면 여기에 실시간으로 표시됩니다\n(약 15~30초 간격으로 갱신)" else "변환된 내용이 없습니다",
                        Modifier.align(Alignment.Center).padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp
                    )
                } else {
                    LazyColumn(state = listState, modifier = Modifier.fillMaxSize().padding(6.dp)) {
                        itemsIndexed(live.lines) { _, l -> LineRow(l) }
                    }
                }
            }

            live.warning?.let {
                Text(it, color = MaterialTheme.colorScheme.error, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
            }

            Box(Modifier.fillMaxWidth().padding(vertical = 18.dp), contentAlignment = Alignment.Center) {
                when {
                    recording -> Box(
                        Modifier.size(72.dp).clip(CircleShape).background(Color(0xFFE03131)).clickable(onClick = onStop),
                        contentAlignment = Alignment.Center
                    ) { Box(Modifier.size(26.dp).background(Color.White, RoundedCornerShape(6.dp))) }
                    done -> Box(
                        Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.primary).clickable(onClick = onResult)
                            .padding(horizontal = 32.dp, vertical = 16.dp)
                    ) { Text("결과 보기", color = MaterialTheme.colorScheme.onPrimary, fontWeight = FontWeight.SemiBold) }
                    else -> Spacer(Modifier.height(72.dp))
                }
            }
        }
    }
}
