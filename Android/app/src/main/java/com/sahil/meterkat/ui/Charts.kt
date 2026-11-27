package com.sahil.meterkat.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.sahil.meterkat.domain.UsageProjection
import com.sahil.meterkat.model.*
import java.time.Instant

@Composable
fun PaceBar(window: UsageWindow, remaining: Boolean, tint: Color, now: Instant) {
    val used = window.effectivePercent(now)
    val fill = if (remaining) 100 - used else used
    val marker = window.elapsed(now)?.let { if (remaining) 1 - it else it }
    val track = MaterialTheme.colorScheme.surfaceContainerHighest
    val ink = MaterialTheme.colorScheme.onSurface
    Canvas(
        Modifier.fillMaxWidth().height(14.dp).semantics {
            contentDescription =
                "${percent(fill)} ${if(remaining)"remaining" else "used"}${marker?.let {", time marker at ${percent(it*100)}"}.orEmpty()}"
        }
    ) {
        drawRoundRect(track, cornerRadius = CornerRadius(size.height / 2))
        if (fill > 0)
            drawRoundRect(
                tint,
                size =
                    androidx.compose.ui.geometry.Size(
                        size.width * (fill / 100).toFloat(),
                        size.height,
                    ),
                cornerRadius = CornerRadius(size.height / 2),
            )
        marker?.let {
            val x = size.width * it.toFloat()
            drawLine(ink, Offset(x, 0f), Offset(x, size.height), 2.dp.toPx())
        }
    }
}

@Composable
fun UsageChart(
    window: UsageWindow,
    points: List<List<Double>>,
    remaining: Boolean,
    tint: Color,
    now: Instant,
    modifier: Modifier = Modifier,
    allowProjection: Boolean = true,
    predictionData: com.sahil.meterkat.model.UsagePredictionData? = null,
    onInspectionChange: (String?) -> Unit = {},
) {
    val grid = MaterialTheme.colorScheme.outlineVariant
    val baseline = MaterialTheme.colorScheme.onSurfaceVariant
    val reset = instant(window.resetsAt)
    val start = reset?.let { r ->
        window.windowSeconds?.takeIf { it > 0 }?.let { r.minusSeconds(it) }
    }
    val cyclePoints =
        points
            .filter {
                it.size >= 2 &&
                    it[0].isFinite() &&
                    it[1].isFinite() &&
                    it[0] <= now.epochSecond &&
                    (start == null || it[0] >= start.epochSecond)
            }
            .sortedBy { it[0] }
    val projection = if (allowProjection) predictionData?.let { UsageProjection.from(it, window, now) }
        ?: UsageProjection.make(window, cyclePoints, now) else null
    val begin = start?.epochSecond?.toDouble()
        ?: cyclePoints.firstOrNull()?.get(0)
        ?: now.minusSeconds(86400).epochSecond.toDouble()
    val end = reset?.epochSecond?.toDouble()?.takeIf { it > begin }
        ?: now.epochSecond.toDouble().coerceAtLeast(begin + 1)
    val density = LocalDensity.current.density
    var inspectedAt by remember(window.id) { mutableStateOf<Double?>(null) }
    fun valueAt(time: Double): Double {
        val first = cyclePoints.firstOrNull() ?: return window.effectivePercent(now) *
            ((time - begin) / (now.epochSecond - begin).coerceAtLeast(1.0)).coerceIn(0.0, 1.0)
        if (time <= first[0]) return first[1]
        for ((a, b) in cyclePoints.zipWithNext()) {
            if (time <= b[0]) {
                val span = b[0] - a[0]
                if (span <= 0) return b[1]
                val fraction = (time - a[0]) / span
                return a[1] + (b[1] - a[1]) * fraction
            }
        }
        val last = cyclePoints.last()
        if (time >= now.epochSecond) return window.effectivePercent(now)
        val next = window.effectivePercent(now)
        val span = (now.epochSecond - last[0]).coerceAtLeast(1.0)
        return last[1] + (next - last[1]) * ((time - last[0]) / span).coerceIn(0.0, 1.0)
    }
    fun inspectionLabel(time: Double): String {
        val value = valueAt(time)
        val date = Instant.ofEpochSecond(time.toLong())
            .atZone(java.time.ZoneId.systemDefault())
            .format(java.time.format.DateTimeFormatter.ofPattern("MMM d · h:mm a"))
        return "$date · ${percent(if (remaining) 100 - value else value)} ${if (remaining) "left" else "used"}"
    }
    fun inspect(x: Float, width: Float) {
        val left = 8.dp.value * density
        val plotWidth = (width - left * 2).coerceAtLeast(1f)
        val fraction = ((x - left) / plotWidth).coerceIn(0f, 1f)
        val time = begin + (end - begin) * fraction
        inspectedAt = time
        onInspectionChange(inspectionLabel(time))
    }
    Box(
        modifier.pointerInput(begin, end) {
            detectHorizontalDragGestures(
                onDragStart = { inspect(it.x, size.width.toFloat()) },
                onDragEnd = {
                    inspectedAt = null
                    onInspectionChange(null)
                },
                onDragCancel = {
                    inspectedAt = null
                    onInspectionChange(null)
                },
                onHorizontalDrag = { change, _ ->
                    change.consume()
                    inspect(change.position.x, size.width.toFloat())
                },
            )
        }.semantics {
            contentDescription =
                "${window.label} recorded usage graph. ${cyclePoints.size} samples. ${percent(window.effectivePercent(now))} used."
        }
    ) {
        Canvas(Modifier.fillMaxSize()) {
        val left = 8.dp.toPx()
        val top = 8.dp.toPx()
        val width = (size.width - left * 2).coerceAtLeast(1f)
        val height = (size.height - top * 2).coerceAtLeast(1f)
        fun y(percent: Double) =
            top +
                height *
                    (1 - (if (remaining) 100 - percent else percent).coerceIn(0.0, 100.0) / 100)
                        .toFloat()
        fun x(epoch: Double) =
            left + width * ((epoch - begin) / (end - begin)).coerceIn(0.0, 1.0).toFloat()
        listOf(0.0, 25.0, 50.0, 75.0, 100.0).forEach {
            val gy = y(it)
            drawLine(grid, Offset(left, gy), Offset(left + width, gy), 1.dp.toPx())
        }
        if (start != null && reset?.isAfter(now) == true)
            drawLine(
                baseline,
                Offset(left, y(0.0)),
                Offset(left + width, y(100.0)),
                1.5.dp.toPx(),
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(), 5.dp.toPx())),
            )
        if (cyclePoints.size >= 2) {
            val path = Path()
            cyclePoints.forEachIndexed { index, p ->
                if (index == 0) path.moveTo(x(p[0]), y(p[1])) else path.lineTo(x(p[0]), y(p[1]))
            }
            drawPath(path, tint, style = Stroke(width = 2.5.dp.toPx()))
        } else if (cyclePoints.isEmpty()) {
            drawLine(
                tint.copy(alpha = .8f),
                Offset(x(begin), y(0.0)),
                Offset(x(now.epochSecond.toDouble()), y(window.effectivePercent(now))),
                2.5.dp.toPx(),
            )
        }
        cyclePoints.lastOrNull()?.let { drawCircle(tint, 4.dp.toPx(), Offset(x(it[0]), y(it[1]))) }
        projection?.let {
            drawLine(
                tint.copy(alpha = .65f),
                Offset(x(now.epochSecond.toDouble()), y(window.effectivePercent(now))),
                Offset(x(it.runsOutAt?.epochSecond?.toDouble() ?: end), y(it.projectedAtReset)),
                2.dp.toPx(),
                pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 5.dp.toPx())),
            )
        }
        inspectedAt?.let { time ->
            val value = valueAt(time)
            drawLine(baseline.copy(alpha = .75f), Offset(x(time), top), Offset(x(time), top + height), 1.dp.toPx())
            drawCircle(tint, 4.dp.toPx(), Offset(x(time), y(value)))
        }
        }
    }
}
