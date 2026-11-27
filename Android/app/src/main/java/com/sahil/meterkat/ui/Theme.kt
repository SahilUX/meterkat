package com.sahil.meterkat.ui

import android.app.Activity
import android.content.ContextWrapper
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

fun providerColor(id: String): Color =
    when (id) {
        "claude" -> Color(0xFFC57854)
        "openai" -> Color(0xFF369E80)
        "opencode" -> Color(0xFF7774CE)
        "openrouter" -> Color(0xFF557FC2)
        "copilot" -> Color(0xFF9874BF)
        "gemini" -> Color(0xFF558BE0)
        "cursor" -> Color(0xFF8B9198)
        "zai" -> Color(0xFFD39843)
        "kimi" -> Color(0xFFF25959)
        "minimax" -> Color(0xFF4D85FA)
        "bailian" -> Color(0xFFF07533)
        "deepseek" -> Color(0xFF336ED1)
        else -> Color(0xFF578E87)
    }

@Composable
fun MeterkatTheme(dynamic: Boolean = false, content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val scheme =
        if (dynamic && Build.VERSION.SDK_INT >= 31) {
            if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        } else meterkatColorScheme(dark)
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
    MaterialTheme(colorScheme = scheme, content = content)
}

fun meterkatColorScheme(dark: Boolean): ColorScheme =
    if (dark)
        darkColorScheme(
            primary = Color(0xFF83D9B5),
            onPrimary = Color(0xFF0A3A29),
            primaryContainer = Color(0xFF254C3A),
            onPrimaryContainer = Color(0xFFB6F3D5),
            secondary = Color(0xFFACCFBB),
            secondaryContainer = Color(0xFF2D473A),
            onSecondaryContainer = Color(0xFFD0EADB),
            background = Color(0xFF101412),
            surface = Color(0xFF171D1A),
            surfaceContainer = Color(0xFF202722),
        )
    else
        lightColorScheme(
            primary = Color(0xFF276A50),
            onPrimary = Color.White,
            primaryContainer = Color(0xFFC2EBD3),
            onPrimaryContainer = Color(0xFF143828),
            secondary = Color(0xFF4B6355),
            secondaryContainer = Color(0xFFCEE7D7),
            onSecondaryContainer = Color(0xFF213D2E),
            background = Color(0xFFF3F5F1),
            surface = Color(0xFFFDFEF9),
            surfaceContainer = Color(0xFFE9EEE6),
        )
