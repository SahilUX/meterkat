import Charts
import SwiftUI

/// Usage across a window's cycle in the chosen bar mode: used so far (or
/// what's left), the ideal line from 0% to 100% (or 100% to 0%) at the
/// reset, and where the current rate of use is heading. The x axis counts
/// down to the reset.
struct UsageChartView: View {
    let window: UsageWindow
    let providerID: String
    var mode: BarMode = .used
    /// This window's recorded samples from `UsageHistory`, oldest first.
    let samples: [UsageSample]
    var now: Date = .now
    var predictionData: UsagePredictionData? = nil
    /// For ~120pt dashboard rows: no legend, caption or axis titles.
    var isCompact = false
    var compactChartHeight: CGFloat = 120
    @State private var selectedElapsed: Double?

    private var tint: Color { UsageFormat.providerTint(providerID) }

    var body: some View {
        if window.isReset(at: now) {
            placeholder("Window reset. Refresh for the new cycle.")
        } else if let start = window.windowStart, let windowSeconds = window.windowSeconds {
            let cycle = samples
                .filter { $0.date >= start && $0.date <= now }
                .sorted { $0.date < $1.date }
            let projection = predictionData.flatMap { UsageProjection.from($0, window: window, now: now) }
                ?? UsageProjection.make(window: window, samples: cycle, now: now)
            if isCompact {
                VStack(alignment: .leading, spacing: 4) {
                    chart(start: start, length: Double(windowSeconds), cycle: cycle, projection: projection)
                        .frame(height: compactChartHeight)
                    outlookLabel(projection)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    chart(start: start, length: Double(windowSeconds), cycle: cycle, projection: projection)
                        .chartXAxisLabel("Time until reset", alignment: .center)
                        .chartYAxisLabel(mode.label)
                        .frame(minHeight: 220)
                    outlookLabel(projection)
                    legend
                    caption(projection: projection, hasHistory: !cycle.isEmpty)
                }
            }
        } else {
            placeholder("Not enough data for a graph")
        }
    }

    // MARK: Chart

    /// `value` is used or remaining, per `mode`.
    private struct Point {
        var elapsed: Double
        var value: Double
    }

    /// A used percentage as plotted in the chosen mode.
    private func plotted(used: Double) -> Double {
        mode.value(used: min(max(used, 0), 100))
    }

    private func chart(start: Date, length: Double, cycle: [UsageSample], projection: UsageProjection?) -> some View {
        let nowX = min(max(now.timeIntervalSince(start), 0), length)
        let actual = actualPoints(start: start, nowX: nowX, cycle: cycle)
        let projected = projection.map { projectedPoints(start: start, length: length, nowX: nowX, projection: $0) } ?? []
        let ideal = [Point(elapsed: 0, value: plotted(used: 0)), Point(elapsed: length, value: plotted(used: 100))]

        let inspectedX = selectedElapsed.map { min(max($0, 0), nowX) }
        let inspectedValue = inspectedX.map { value(at: $0, points: actual, fallback: plotted(used: window.effectivePercent(at: now))) }

        return Chart {
            ForEach(ideal.indices, id: \.self) { index in
                LineMark(
                    x: .value("Elapsed", ideal[index].elapsed),
                    y: .value(mode.label, ideal[index].value),
                    series: .value("Line", "Ideal")
                )
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            ForEach(actual.indices, id: \.self) { index in
                AreaMark(
                    x: .value("Elapsed", actual[index].elapsed),
                    y: .value(mode.label, actual[index].value)
                )
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(
                    x: .value("Elapsed", actual[index].elapsed),
                    y: .value(mode.label, actual[index].value),
                    series: .value("Line", "Actual")
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            ForEach(projected.indices, id: \.self) { index in
                LineMark(
                    x: .value("Elapsed", projected[index].elapsed),
                    y: .value(mode.label, projected[index].value),
                    series: .value("Line", "Projected")
                )
                .foregroundStyle(tint.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }

            if let projection, let runsOutAt = projection.runsOutAt {
                PointMark(
                    x: .value("Elapsed", runsOutAt.timeIntervalSince(start)),
                    y: .value(mode.label, plotted(used: 100))
                )
                .foregroundStyle(tint)
                .symbolSize(isCompact ? 30 : 50)
            }

            RuleMark(x: .value("Now", nowX))
                .foregroundStyle(Color.primary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1))

            if let inspectedX, let inspectedValue {
                RuleMark(x: .value("Selected time", inspectedX))
                    .foregroundStyle(tint.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                PointMark(x: .value("Selected time", inspectedX), y: .value(mode.label, inspectedValue))
                    .foregroundStyle(tint)
                    .symbolSize(55)
            }
        }
        .chartXScale(domain: 0...length)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: xAxisValues(length: length)) { value in
                let elapsed = value.as(Double.self) ?? 0
                AxisGridLine()
                // Labels sit right of their gridline by default, which would
                // push the reset edge's "0h" out of the plot and drop it.
                AxisValueLabel(anchor: elapsed >= length ? .topTrailing : nil) {
                    Text(timeLeftLabel(length - elapsed, length: length))
                }
                .font(axisFont)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: isCompact ? [0, 50, 100] : [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(UsageFormat.percent(percent))
                    }
                }
                .font(axisFont)
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedElapsed)
        .overlay(alignment: .topLeading) {
            if let inspectedX, let inspectedValue {
                Text("\(inspectionTime(start: start, elapsed: inspectedX))  ·  \(UsageFormat.percent(inspectedValue)) \(mode == .used ? "used" : "remaining")")
                    .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    #if os(macOS)
                    // Adding a material inside a MenuBarExtra can change the
                    // entire popover's backdrop, even after selection clears.
                    .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                    #else
                    .background(.regularMaterial, in: Capsule())
                    #endif
                    .padding(.leading, 8)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(mode == .used ? "Usage over this window" : "Remaining allowance over this window")
    }

    private func value(at elapsed: Double, points: [Point], fallback: Double) -> Double {
        guard let first = points.first, let last = points.last else { return fallback }
        guard elapsed > first.elapsed else { return first.value }
        guard elapsed < last.elapsed else { return last.value }
        for pair in zip(points, points.dropFirst()) where elapsed <= pair.1.elapsed {
            let span = pair.1.elapsed - pair.0.elapsed
            guard span > 0 else { return pair.1.value }
            let fraction = (elapsed - pair.0.elapsed) / span
            return pair.0.value + (pair.1.value - pair.0.value) * fraction
        }
        return last.value
    }

    private func inspectionTime(start: Date, elapsed: Double) -> String {
        let date = start.addingTimeInterval(elapsed)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The value after each sample, ending at the current one. Without
    /// history the line is the implied average: straight from the start of the window.
    private func actualPoints(start: Date, nowX: Double, cycle: [UsageSample]) -> [Point] {
        var points = cycle.map { Point(elapsed: $0.date.timeIntervalSince(start), value: plotted(used: $0.percent)) }
        if points.isEmpty { points.append(Point(elapsed: 0, value: plotted(used: 0))) }
        if let last = points.last, last.elapsed < nowX {
            points.append(Point(elapsed: nowX, value: plotted(used: window.effectivePercent(at: now))))
        }
        return points
    }

    /// From now to the reset, or to where the allowance runs out first.
    private func projectedPoints(start: Date, length: Double, nowX: Double, projection: UsageProjection) -> [Point] {
        let from = Point(elapsed: nowX, value: plotted(used: projection.current))
        if let runsOutAt = projection.runsOutAt {
            return [from, Point(elapsed: runsOutAt.timeIntervalSince(start), value: plotted(used: 100))]
        }
        return [from, Point(elapsed: length, value: plotted(used: projection.projectedAtReset))]
    }

    /// The Mac panel's compact charts are about 90pt tall, so their labels shrink.
    private var axisFont: Font? {
        #if os(macOS)
        isCompact ? .system(size: 9) : nil
        #else
        nil
        #endif
    }

    // MARK: Axis

    /// Hours for windows up to two days, days beyond.
    private func axisUnit(length: Double) -> Double {
        length <= 2 * 86_400 ? 3_600 : 86_400
    }

    /// Whole hours or days before the reset, at most eight labels, ending at "0h"/"0d".
    private func xAxisValues(length: Double) -> [Double] {
        let unit = axisUnit(length: length)
        let units = length / unit
        let steps: [Double] = unit == 3_600 ? [1, 2, 3, 4, 6, 12] : [1, 2, 5, 7, 10, 14]
        let step = (steps.first { units / $0 <= 7 } ?? steps[steps.count - 1]) * unit
        return stride(from: length, through: 0, by: -step).map { $0 }
    }

    private func timeLeftLabel(_ left: Double, length: Double) -> String {
        let unit = axisUnit(length: length)
        return "\(Int((left / unit).rounded()))\(unit == 3_600 ? "h" : "d")"
    }

    // MARK: Legend and caption

    @ViewBuilder
    private func outlookLabel(_ projection: UsageProjection?) -> some View {
        if let projection {
            Text(projection.outlookText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(projection.runsOutAt == nil ? Color.secondary : tint)
        } else {
            Text("Forecast unavailable")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("Actual", color: tint, dashed: false)
            legendItem("Projected", color: tint.opacity(0.7), dashed: true)
            legendItem("Ideal", color: .secondary, dashed: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 16, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
            .frame(width: 16, height: 2)
            Text(title)
        }
    }

    private func caption(projection: UsageProjection?, hasHistory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(projection?.basisDescription ?? "Not enough data for a projection")
            if !hasHistory {
                Text("No history from the companion yet, so the usage line is an average.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: isCompact ? 60 : 160)
    }
}

#Preview {
    let now = Date.now
    let window = UsageWindow(id: "five_hour", kind: "session", label: "5-hour", percent: 42,
                             resetsAt: now.addingTimeInterval(2.5 * 3_600), windowSeconds: 18_000)
    let samples = stride(from: 0.0, through: 150, by: 10).map { minute in
        UsageSample(date: now.addingTimeInterval(-(150 - minute) * 60), percent: minute / 150 * 42)
    }
    return VStack(spacing: 32) {
        UsageChartView(window: window, providerID: "claude", samples: samples, now: now, isCompact: true)
        UsageChartView(window: window, providerID: "claude", mode: .remaining, samples: [], now: now)
    }
    .padding()
}
