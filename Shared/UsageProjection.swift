import Foundation

/// Where a window's usage is heading by its reset, extrapolated from the
/// samples the companion recorded. The graph and the stats sheet share it.
struct UsageProjection: Equatable {
    enum Basis: Equatable {
        /// Least-squares trend of the samples from the last `minutes`.
        case recentTrend(minutes: Double)
        /// Usage so far spread evenly over the time since the window started.
        case windowAverage
    }

    /// Usage when the projection was made, 0...100.
    var current: Double
    var now: Date
    var resetsAt: Date
    /// Percentage points per hour. Never negative: usage only grows within a cycle.
    var ratePerHour: Double
    /// Usage expected at the reset if the rate holds. Can pass 100; clamp for display.
    var projectedAtReset: Double
    /// When usage reaches 100% at this rate, if that's before the reset.
    var runsOutAt: Date?
    var basis: Basis

    static func from(_ data: UsagePredictionData, window: UsageWindow, now: Date) -> UsageProjection? {
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        let basis: Basis = data.basis == "recent_trend" ? .recentTrend(minutes: data.trendMinutes) : .windowAverage
        return UsageProjection(current: data.current, now: now, resetsAt: resetsAt,
                               ratePerHour: data.ratePerHour,
                               projectedAtReset: data.projectedAtReset,
                               runsOutAt: data.runsOutAt, basis: basis)
    }

    /// How far back the trend looks: the last 5% of the usage window
    /// (15 min for a 5-hour window, 8.4 h weekly, 36 h monthly).
    static func trendMinutes(for window: UsageWindow) -> Double {
        let windowMinutes = Double(window.windowSeconds ?? 0) / 60
        return windowMinutes * 0.05
    }

    /// Nil when the window's start is unknown (no reset time or length) or
    /// it has already reset.
    static func make(window: UsageWindow, samples: [UsageSample], now: Date = .now, trendMinutes: Double? = nil) -> UsageProjection? {
        guard let start = window.windowStart, let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        let current = window.effectivePercent(at: now)
        let trendMinutes = trendMinutes ?? Self.trendMinutes(for: window)
        // Recent samples must cover a quarter of the trend window before
        // their slope beats the window average.
        let minimumTrendSpan = trendMinutes * 60 * 0.25

        let trendStart = max(start, now.addingTimeInterval(-trendMinutes * 60))
        let recent = samples
            .filter { $0.date >= trendStart && $0.date <= now }
            .sorted { $0.date < $1.date }

        let perSecond: Double
        let basis: Basis
        if recent.count >= 2, let first = recent.first, let last = recent.last,
           last.date.timeIntervalSince(first.date) >= minimumTrendSpan {
            perSecond = slope(of: recent)
            basis = .recentTrend(minutes: trendMinutes)
        } else {
            let elapsed = now.timeIntervalSince(start)
            guard elapsed > 0 else { return nil }
            perSecond = current / elapsed
            basis = .windowAverage
        }

        let rate = max(perSecond, 0)
        let remaining = resetsAt.timeIntervalSince(now)
        var runsOutAt: Date?
        if current < 100, rate > 0 {
            let secondsToLimit = (100 - current) / rate
            if secondsToLimit < remaining { runsOutAt = now.addingTimeInterval(secondsToLimit) }
        }

        return UsageProjection(
            current: current,
            now: now,
            resetsAt: resetsAt,
            ratePerHour: rate * 3_600,
            projectedAtReset: current + rate * remaining,
            runsOutAt: runsOutAt,
            basis: basis
        )
    }

    /// A relative run-out estimate, if the limit is reached before reset.
    var runsOutText: String? {
        guard let runsOutAt else { return nil }
        return "Runs out in ~\(UsageFormat.longCountdown(to: runsOutAt, from: now))"
    }

    var outlookText: String {
        if current >= 100 { return "Limit reached until reset" }
        if let runsOutText { return runsOutText }
        return "Lasts until reset (~\(UsageFormat.percent(max(0, 100 - projectedAtReset))) left)"
    }

    var basisDescription: String {
        switch basis {
        case .recentTrend(let minutes):
            let span = minutes >= 120 ? "\(Int((minutes / 60).rounded())) hr" : "\(Int(minutes)) min"
            return "Projection from the last \(span)"
        case .windowAverage: return "Projection from the average since the window started"
        }
    }

    /// Least-squares slope of percent over time, in percentage points per second.
    private static func slope(of samples: [UsageSample]) -> Double {
        guard let origin = samples.first?.date else { return 0 }
        let xs = samples.map { $0.date.timeIntervalSince(origin) }
        let ys = samples.map(\.percent)
        let count = Double(samples.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        return variance > 0 ? covariance / variance : 0
    }
}
