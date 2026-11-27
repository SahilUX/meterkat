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
    paint.color = if (dark) 0xFF343E37.toInt() else 0xFFE0E5DE.toInt()
    listOf(0.0, 25.0, 50.0, 75.0, 100.0).forEach { canvas.drawLine(left, y(it), left+w, y(it), paint) }
    if (start != null && reset != null && reset > now) {
        paint.color = if (dark) 0xFFAEB9AF.toInt() else 0xFF6C776E.toInt()
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

internal fun widgetBar(fraction: Double, marker: Double?, color: Int, dark: Boolean): Bitmap {
    val bitmap = Bitmap.createBitmap(600, 20, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap); val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = if (dark) 0xFF364239.toInt() else 0xFFDFE5DC.toInt()
    canvas.drawRoundRect(0f, 3f, 600f, 17f, 7f, 7f, paint)
    paint.color = color
    if (fraction > 0) canvas.drawRoundRect(0f, 3f, (fraction * 600).toFloat(), 17f, 7f, 7f, paint)
    marker?.let {
        val x = (it * 596).toFloat().coerceIn(2f, 598f)
        paint.color = if (dark) 0xFF18201B.toInt() else 0xFFFDFEF9.toInt(); paint.strokeWidth = 6f
        canvas.drawLine(x, 0f, x, 20f, paint)
        paint.color = if (dark) 0xFFE1EBE2.toInt() else 0xFF303832.toInt(); paint.strokeWidth = 2f
        canvas.drawLine(x, 0f, x, 20f, paint)
    }
    return bitmap
}
