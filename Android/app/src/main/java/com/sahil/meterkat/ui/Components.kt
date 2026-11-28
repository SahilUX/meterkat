package com.sahil.meterkat.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.sahil.meterkat.R
import com.sahil.meterkat.model.providerNames

/** The colour for a provider's name: the accent text colour for Claude, its tint for the rest. */
@Composable
fun providerTextColor(id: String): Color =
    if (id == "claude") MaterialTheme.meterkat.accentText else providerColor(id)

private fun providerLogo(id: String): Int? =
    when (id) {
        "claude" -> R.drawable.provider_claude
        "openai" -> R.drawable.provider_openai
        "openrouter" -> R.drawable.provider_openrouter
        "copilot" -> R.drawable.provider_copilot
        "gemini" -> R.drawable.provider_gemini
        "cursor" -> R.drawable.provider_cursor
        "opencode" -> R.drawable.provider_opencode
        "zai" -> R.drawable.provider_zai
        "kimi" -> R.drawable.provider_kimi
        "minimax" -> R.drawable.provider_minimax
        "bailian" -> R.drawable.provider_bailian
        "deepseek" -> R.drawable.provider_deepseek
        else -> null
    }

/** A provider's logo (or its first letter) in one colour, with no background. */
@Composable
fun ProviderGlyph(id: String, size: Int, tint: Color = providerColor(id)) {
    val logo = providerLogo(id)
    if (logo != null) Icon(painterResource(logo), null, Modifier.size(size.dp), tint = tint)
    else
        Box(Modifier.size(size.dp), contentAlignment = Alignment.Center) {
            Text(
                (providerNames[id] ?: id).take(1),
                color = tint,
                fontWeight = FontWeight.Bold,
            )
        }
}

/** A provider logo on a soft rounded tile, as in Settings. */
@Composable
internal fun ProviderMark(id: String, size: Int = 36) {
    Box(
        Modifier.size(size.dp)
            .clip(RoundedCornerShape((size * .28f).dp))
            .background(providerColor(id).copy(alpha = .15f)),
        contentAlignment = Alignment.Center,
    ) {
        ProviderGlyph(id, (size * .55f).toInt())
    }
}

/**
 * A message. A warning is an orange block; a plain note is a grey one. [onCard] is for a notice
 * inside a white card, where it takes the page colour so it still stands out.
 */
@Composable
fun Notice(text: String, warning: Boolean = false, onCard: Boolean = false) {
    val colors = MaterialTheme.meterkat
    Surface(
        shape = RoundedCornerShape(16.dp),
        color =
            when {
                warning -> colors.urgentBg
                onCard -> MaterialTheme.colorScheme.background
                else -> MaterialTheme.colorScheme.surface
            },
    ) {
        Row(
            Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                if (warning) Icons.Default.WarningAmber else Icons.Default.Info,
                null,
                Modifier.size(20.dp),
                tint = if (warning) colors.warn else MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** A Material switch in the app's coral. */
@Composable
fun MeterkatSwitch(checked: Boolean, onChange: ((Boolean) -> Unit)?, modifier: Modifier = Modifier) {
    Switch(
        checked,
        onChange,
        modifier,
        colors =
            SwitchDefaults.colors(
                checkedTrackColor = Coral,
                checkedBorderColor = Coral,
                checkedThumbColor = Color.White,
            ),
    )
}

/** The small orange dot that marks a provider with a problem. */
@Composable
fun ProblemDot(ring: Color, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(13.dp)
            .background(ring, CircleShape)
            .padding(2.dp)
            .background(MaterialTheme.meterkat.warn, CircleShape)
    )
}
