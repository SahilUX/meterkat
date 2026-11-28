package com.sahil.meterkat.ui

import android.app.Activity
import android.content.ContextWrapper
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.core.view.WindowCompat

/** The Meterkat coral. Provider tint for Claude, and the accent of the whole app. */
val Coral = Color(0xFFD97757)

/** Provider tints, the same as the iPhone app (`UsageFormat.providerTint`). */
fun providerColor(id: String): Color =
    when (id) {
        "claude" -> Coral
        "openai" -> Color(0xFF10A37F)
        "opencode" -> Color(0xFF5B82F5)
        "openrouter" -> Color(0xFF9466F2)
        "copilot" -> Color(0xFF8957E5)
        "gemini" -> Color(0xFF1C69FF)
        "cursor" -> Color(0xFF8C8C94)
        "zai" -> Color(0xFF14B8A6)
        "kimi" -> Color(0xFFF25959)
        "minimax" -> Color(0xFF4D85FA)
        "bailian" -> Color(0xFFF07833)
        "deepseek" -> Color(0xFF336ED1)
        else -> Coral
    }

/**
 * Colours that Material 3's scheme has no slot for. They follow the light and dark palettes of the
 * design, also when the wallpaper-based dynamic scheme is on.
 */
data class MeterkatColors(
    /** Accent for text and icons on the page: darker than the coral in light, lighter in dark. */
    val accentText: Color,
    /** Orange for "ahead of pace" and problems. */
    val warn: Color,
    /** Green for "under pace". */
    val ok: Color,
    /** Background of the next-limit banner and the outlook box. */
    val urgentBg: Color,
    val divider: Color,
    /** Chevrons and the sheet handle. */
    val faint: Color,
    /** The floating provider pill. */
    val pill: Color,
    val pillEdge: Color,
    val navBar: Color,
    /** The shaded stretch of a bar that the projection says will be used up. */
    val projected: Color,
    /** Grid lines in charts. */
    val grid: Color,
    /** The even-pace line. */
    val evenPace: Color,
    val dark: Boolean,
)

private val LightExtras =
    MeterkatColors(
        accentText = Color(0xFFB4532F),
        warn = Color(0xFFB25E00),
        ok = Color(0xFF1F7A3A),
        urgentBg = Color(0xFFFFF1DC),
        divider = Color(0xFFE9E9ED),
        faint = Color(0xFFC4C4C8),
        pill = Color(0xE6FFFFFF),
        pillEdge = Color(0x0F000000),
        navBar = Color(0xFFFAFAFC),
        projected = Color(0x40B25E00),
        grid = Color(0xFFEEEEF2),
        evenPace = Color(0xFF8E8E93),
        dark = false,
    )

private val DarkExtras =
    MeterkatColors(
        accentText = Color(0xFFE8906F),
        warn = Color(0xFFFF9F0A),
        ok = Color(0xFF30D158),
        urgentBg = Color(0xFF3A2A12),
        divider = Color(0xFF2C2C2E),
        faint = Color(0xFF5A5A60),
        pill = Color(0xCC2C2C2E),
        pillEdge = Color(0x14FFFFFF),
        navBar = Color(0xFF0E0E10),
        projected = Color(0x55FF9F0A),
        grid = Color(0xFF2C2C2E),
        evenPace = Color(0xFF8E8E93),
        dark = true,
    )

private val LocalMeterkatColors = staticCompositionLocalOf { LightExtras }

val MaterialTheme.meterkat: MeterkatColors
    @Composable @ReadOnlyComposable get() = LocalMeterkatColors.current

/** Tabular (fixed-width) digits, so percentages and times don't jiggle as they change. */
private fun Typography.tabular(): Typography {
    fun TextStyle.t() = copy(fontFeatureSettings = "tnum")
    return copy(
        displayLarge = displayLarge.t(),
        displayMedium = displayMedium.t(),
        displaySmall = displaySmall.t(),
        headlineLarge = headlineLarge.t(),
        headlineMedium = headlineMedium.t(),
        headlineSmall = headlineSmall.t(),
        titleLarge = titleLarge.t(),
        titleMedium = titleMedium.t(),
        titleSmall = titleSmall.t(),
        bodyLarge = bodyLarge.t(),
        bodyMedium = bodyMedium.t(),
        bodySmall = bodySmall.t(),
        labelLarge = labelLarge.t(),
        labelMedium = labelMedium.t(),
        labelSmall = labelSmall.t(),
    )
}

@Composable
fun MeterkatTheme(dynamic: Boolean = false, content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme =
        if (dynamic && Build.VERSION.SDK_INT >= 31) {
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else meterkatColorScheme(dark)
    val extras =
        (if (dark) DarkExtras else LightExtras).let {
            if (dynamic && Build.VERSION.SDK_INT >= 31) it.copy(accentText = scheme.primary) else it
        }
    val view = LocalView.current
    SideEffect {
        var owner = view.context
        while (owner is ContextWrapper && owner !is Activity) owner = owner.baseContext
        (owner as? Activity)?.let { activity ->
            WindowCompat.getInsetsController(activity.window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    CompositionLocalProvider(LocalMeterkatColors provides extras) {
        MaterialTheme(
            colorScheme = scheme,
            typography = MaterialTheme.typography.tabular(),
            content = content,
        )
    }
}

/**
 * The default palette: a coral accent on neutral greys, the same as the iPhone app. Cards are
 * [ColorScheme.surface] on a [ColorScheme.background] page.
 */
fun meterkatColorScheme(dark: Boolean): ColorScheme =
    if (dark) {
        val page = Color(0xFF000000)
        val card = Color(0xFF1C1C1E)
        darkColorScheme(
            primary = Coral,
            onPrimary = Color.White,
            primaryContainer = Coral.copy(alpha = .18f).compositeOver(card),
            onPrimaryContainer = Color(0xFFE8906F),
            secondary = Color(0xFFE8906F),
            onSecondary = Color(0xFF1C1C1E),
            secondaryContainer = Coral.copy(alpha = .18f).compositeOver(card),
            onSecondaryContainer = Color(0xFFE8906F),
            tertiary = Color(0xFFE8906F),
            background = page,
            onBackground = Color(0xFFF2F2F7),
            surface = card,
            onSurface = Color(0xFFF2F2F7),
            surfaceVariant = Color(0xFF2C2C2E),
            onSurfaceVariant = Color(0xFFA1A1A8),
            surfaceTint = Coral,
            surfaceContainerLowest = page,
            surfaceContainerLow = page,
            surfaceContainer = card,
            surfaceContainerHigh = Color(0xFF2C2C2E),
            surfaceContainerHighest = Color(0xFF3A3A3C),
            outline = Color(0xFF8E8E93),
            outlineVariant = Color(0xFF2C2C2E),
            errorContainer = Color(0xFF3A2A12),
            onErrorContainer = Color(0xFFFF9F0A),
        )
    } else {
        val page = Color(0xFFF2F2F7)
        val card = Color(0xFFFFFFFF)
        lightColorScheme(
            primary = Coral,
            onPrimary = Color.White,
            primaryContainer = Coral.copy(alpha = .15f).compositeOver(card),
            onPrimaryContainer = Color(0xFFB4532F),
            secondary = Color(0xFFB4532F),
            onSecondary = Color.White,
            secondaryContainer = Coral.copy(alpha = .15f).compositeOver(card),
            onSecondaryContainer = Color(0xFFB4532F),
            tertiary = Color(0xFFB4532F),
            background = page,
            onBackground = Color(0xFF1C1C1E),
            surface = card,
            onSurface = Color(0xFF1C1C1E),
            surfaceVariant = Color(0xFFE5E5EA),
            onSurfaceVariant = Color(0xFF6C6C72),
            surfaceTint = Coral,
            surfaceContainerLowest = card,
            surfaceContainerLow = page,
            surfaceContainer = card,
            surfaceContainerHigh = card,
            surfaceContainerHighest = Color(0xFFE5E5EA),
            outline = Color(0xFF79747E),
            outlineVariant = Color(0xFFE9E9ED),
            errorContainer = Color(0xFFFFF1DC),
            onErrorContainer = Color(0xFFB25E00),
        )
    }
