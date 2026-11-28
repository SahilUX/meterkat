package com.sahil.meterkat.widget

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.DashPathEffect
import com.sahil.meterkat.domain.UsageProjection
import com.sahil.meterkat.model.UsageWindow
import com.sahil.meterkat.model.UsagePredictionData
import com.sahil.meterkat.model.instant
import java.time.Instant

internal fun currentWidgetPoints(window: UsageWindow, points: List<List<Double>>, now: Instant): List<List<Double>> {
    val reset = instant(window.resetsAt)
    // A passed reset makes the cached history belong to the previous cycle.
    if (reset != null && reset <= now) return emptyList()
    val start = reset?.let { end -> window.windowSeconds?.takeIf { it > 0 }?.let { end.minusSeconds(it) } }
    return points.filter { it.size >= 2 && it[0].isFinite() && it[1].isFinite() && it[0] <= now.epochSecond && (start == null || it[0] >= start.epochSecond) }.sortedBy { it[0] }
}

internal fun widgetChart(window: UsageWindow, points: List<List<Double>>, remaining: Boolean, now: Instant, color: Int, dark: Boolean, width: Int, height: Int, fresh: Boolean, predictionData: UsagePredictionData? = null): Bitmap {
    val bitmap = Bitmap.createBitmap(width.coerceIn(120, 720), height.coerceIn(24, 280), Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1f }
    val data = currentWidgetPoints(window, points, now)
    val reset = instant(window.resetsAt)
    val start = reset?.let { r -> window.windowSeconds?.takeIf { it > 0 }?.let { r.minusSeconds(it) } }
    val left = 5f; val top = 4f
    val w = bitmap.width - left * 2; val h = bitmap.height - top * 2
    val begin = start?.epochSecond?.toDouble() ?: data.firstOrNull()?.get(0) ?: now.minusSeconds(86400).epochSecond.toDouble()
    val end = reset?.epochSecond?.toDouble()?.takeIf { it > begin } ?: now.epochSecond.toDouble().coerceAtLeast(begin + 1)
    fun x(epoch: Double) = left + w * ((epoch - begin) / (end - begin)).coerceIn(0.0, 1.0).toFloat()
    fun y(value: Double) = top + h * (1.0 - (if (remaining) 100.0 - value else value).coerceIn(0.0, 100.0) / 100.0).toFloat()
    paint.color = if (dark) 0xFF2C2C2E.toInt() else 0xFFEEEEF2.toInt()
    listOf(0.0, 25.0, 50.0, 75.0, 100.0).forEach { canvas.drawLine(left, y(it), left+w, y(it), paint) }
    if (start != null && reset != null && reset > now) {
        paint.color = 0xFF8E8E93.toInt()
        paint.pathEffect = DashPathEffect(floatArrayOf(8f, 5f), 0f)
        canvas.drawLine(left, y(0.0), left+w, y(100.0), paint)
        paint.pathEffect = null
    }
    paint.color = color; paint.strokeWidth = 2.5f
    if (data.size >= 2) {
        val path = Path()
        data.forEachIndexed { index, sample -> if (index == 0) path.moveTo(x(sample[0]), y(sample[1])) else path.lineTo(x(sample[0]), y(sample[1])) }
        canvas.drawPath(path, paint)
    }
    data.lastOrNull()?.let { paint.style = Paint.Style.FILL; canvas.drawCircle(x(it[0]), y(it[1]), 3f, paint); paint.style = Paint.Style.STROKE }
    // The same projection math as the app; no projected line without real cycle history.
    val projection = if (fresh && data.isNotEmpty()) predictionData?.let { UsageProjection.from(it, window, now) }
        ?: UsageProjection.make(window, data, now) else null
    projection?.let {
        paint.alpha = 165; paint.pathEffect = DashPathEffect(floatArrayOf(2f, 5f), 0f)
        canvas.drawLine(x(now.epochSecond.toDouble()), y(window.effectivePercent(now)), x(it.runsOutAt?.epochSecond?.toDouble() ?: end), y(if(it.runsOutAt != null) 100.0 else it.projectedAtReset), paint)
    }
    return bitmap
}

/** The pace bar of the app: a tint track and fill, with an outlined marker for time through the window. */
internal fun widgetBar(fraction: Double, marker: Double?, color: Int, dark: Boolean): Bitmap {
    val bitmap = Bitmap.createBitmap(600, 20, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap); val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = (color and 0x00FFFFFF) or (0x38 shl 24)
    canvas.drawRoundRect(0f, 4f, 600f, 16f, 6f, 6f, paint)
    paint.color = color
    if (fraction > 0) canvas.drawRoundRect(0f, 4f, (maxOf(fraction, 0.02) * 600).toFloat(), 16f, 6f, 6f, paint)
    marker?.let {
        val x = (it * 596).toFloat().coerceIn(3f, 597f)
        paint.color = if (dark) 0xFF1C1C1E.toInt() else 0xFFFFFFFF.toInt(); paint.strokeWidth = 8f
        canvas.drawLine(x, 1f, x, 19f, paint)
        paint.color = if (dark) 0xFFF2F2F7.toInt() else 0xFF1C1C1E.toInt(); paint.strokeWidth = 4f
        canvas.drawLine(x, 1f, x, 19f, paint)
    }
    return bitmap
}
