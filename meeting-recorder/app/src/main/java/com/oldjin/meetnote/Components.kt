package com.oldjin.meetnote

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun LineRow(line: Line, highlighted: Boolean = false, onClick: (() -> Unit)? = null) {
    val warn = line.speaker == "!"
    val base = Modifier.fillMaxWidth().background(
        if (highlighted) MaterialTheme.colorScheme.primaryContainer else androidx.compose.ui.graphics.Color.Transparent,
        RoundedCornerShape(12.dp)
    )
    Row(
        (if (onClick != null) base.clickableNoRipple(onClick) else base).padding(horizontal = 10.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(
            if (warn) "" else fmtTime(line.sec),
            fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 2.dp)
        )
        Column(Modifier.weight(1f)) {
            if (warn) {
                Text(line.text, fontSize = 13.sp, color = MaterialTheme.colorScheme.error)
            } else {
                if (line.speaker.isNotBlank()) {
                    Text(line.speaker, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = speakerColor(line.speaker))
                    Spacer(Modifier.height(2.dp))
                }
                Text(line.text, fontSize = 15.sp, lineHeight = 22.sp, color = MaterialTheme.colorScheme.onSurface)
            }
        }
    }
}

@Composable
fun MarkdownText(text: String) {
    fun clean(s: String) = s.replace("**", "").replace("`", "")
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
        text.lines().forEach { raw ->
            val l = raw.trim()
            when {
                l.isEmpty() -> Spacer(Modifier.height(2.dp))
                l.startsWith("#") -> Text(
                    clean(l.trimStart('#').trim()), fontSize = 16.sp, fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 10.dp)
                )
                l.startsWith("- ") || l.startsWith("* ") -> Row {
                    Text("•  ", color = MaterialTheme.colorScheme.primary)
                    Text(clean(l.drop(2)), fontSize = 15.sp, lineHeight = 22.sp)
                }
                else -> Text(clean(l), fontSize = 15.sp, lineHeight = 22.sp)
            }
        }
    }
}

val ScreenPadding = PaddingValues(horizontal = 16.dp)
