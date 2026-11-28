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

    // MARK: Run-out presentation

    /// The projection the app shows for a window: the companion's own when
    /// it sent one, otherwise one worked out from the recorded samples.
    static func resolve(window: UsageWindow, samples: [UsageSample], data: UsagePredictionData?, now: Date) -> UsageProjection? {
        data.flatMap { from($0, window: window, now: now) }
            ?? make(window: window, samples: samples, now: now)
    }

    /// Whether the window is on course to hit its limit before the reset.
    var runsOutBeforeReset: Bool { current < 100 && runsOutAt != nil }

    /// The earliest run-out among `items`, skipping windows that last until their reset.
    static func earliestRunOut<ID>(_ items: [(id: ID, projection: UsageProjection?)]) -> (id: ID, projection: UsageProjection)? {
        var best: (id: ID, projection: UsageProjection, at: Date)?
        for item in items {
            guard let projection = item.projection, projection.runsOutBeforeReset,
                  let at = projection.runsOutAt else { continue }
            if best == nil || at < best!.at { best = (item.id, projection, at) }
        }
        return best.map { ($0.id, $0.projection) }
    }

    /// Trailing text for a window row's percent line, and whether it warns.
    struct ResetSummary: Equatable {
        var text: String
        var warns: Bool
    }

    /// "About 61% at reset" (or "About 39% left at reset" in remaining mode),
    /// or "Runs out early" when the limit is hit first. Nil once the limit is
    /// already reached: the row says so itself.
    func resetSummary(mode: BarMode) -> ResetSummary? {
        if current >= 100 { return nil }
        if runsOutAt != nil { return ResetSummary(text: "Runs out early", warns: true) }
        let value = UsageFormat.percent(mode.value(used: min(max(projectedAtReset, 0), 100)))
        return ResetSummary(text: mode == .used ? "About \(value) at reset" : "About \(value) left at reset", warns: false)
    }

    /// Where the bar's fill would end at the reset, in the bar's own scale
    /// (`.used` fills toward 100, `.remaining` drains toward 0). Nil unless the
    /// window is projected to exceed 100%, so the bar draws the stretch
    /// between its fill and this value only when it will run out.
    func barProjectedFill(mode: BarMode) -> Double? {
        guard runsOutBeforeReset else { return nil }
        return mode.value(used: 100)
    }

    /// The span from the projected run-out to the reset, or from now when the
    /// limit is already reached: the stretch the chart marks as blocked.
    var blockedRange: ClosedRange<Date>? {
        if current >= 100 { return now <= resetsAt ? now...resetsAt : nil }
        guard let runsOutAt, runsOutAt <= resetsAt else { return nil }
        return runsOutAt...resetsAt
    }

    /// Percentage points per hour or per day that would make the allowance last to the reset.
    struct Budget: Equatable {
        enum Unit: Equatable {
            case hour, day
            var word: String { self == .hour ? "hr" : "day" }
        }

        var points: Double
        var unit: Unit

        /// "11" at 10 or above, otherwise to one decimal: "4.8", "0.5". Never "0".
        var pointsText: String {
            if points >= 10 { return String(Int(points.rounded())) }
            let rounded = (points * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        }

        /// "11 pts / day", for a stat row.
        var statText: String { "\(pointsText) pts / \(unit.word)" }
        /// "~11 pts a day", for a sentence.
        var sentenceText: String { "~\(pointsText) pts \(unit == .hour ? "an hour" : "a day")" }
    }

    /// Hourly for windows up to two days (the 5-hour session), daily beyond.
    /// Nil when the limit is already reached or the reset has passed.
    func budget(windowSeconds: Int?) -> Budget? {
        let remaining = resetsAt.timeIntervalSince(now)
        guard current < 100, remaining > 0 else { return nil }
        let length = windowSeconds.map(Double.init) ?? remaining
        let unit: Budget.Unit = length <= 2 * 86_400 ? .hour : .day
        let units = remaining / (unit == .hour ? 3_600 : 86_400)
        return Budget(points: (100 - current) / units, unit: unit)
    }

    /// "Wed, 6 PM" for the run-out moment: nearest quarter hour (5 minutes for
    /// the last two days before a reset), and a date instead of a weekday
    /// from six days out, where a weekday would repeat.
    var runsOutWhenText: String? {
        guard let runsOutAt else { return nil }
        let step: TimeInterval = resetsAt.timeIntervalSince(now) > 2 * 86_400 ? 900 : 300
        let rounded = Date(timeIntervalSinceReferenceDate: (runsOutAt.timeIntervalSinceReferenceDate / step).rounded() * step)
        let farOut = rounded.timeIntervalSince(now) >= 6 * 86_400
        let day = farOut
            ? rounded.formatted(.dateTime.month(.abbreviated).day())
            : rounded.formatted(.dateTime.weekday(.abbreviated))
        let minutes = Calendar.current.component(.minute, from: rounded)
        let time = minutes == 0
            ? rounded.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            : rounded.formatted(date: .omitted, time: .shortened)
        return "\(day), \(time)"
    }

    /// "27 hr before it resets", "40 min before it resets", "2 days before it resets".
    var leadBeforeResetText: String? {
        guard let runsOutAt else { return nil }
        let seconds = max(0, resetsAt.timeIntervalSince(runsOutAt))
        let amount: String
        if seconds < 3_600 {
            amount = "\(max(Int((seconds / 60).rounded()), 1)) min"
        } else if seconds < 2 * 86_400 {
            amount = "\(Int((seconds / 3_600).rounded())) hr"
        } else {
            amount = "\(Int((seconds / 86_400).rounded())) days"
        }
        return "\(amount) before it resets"
    }

    /// The banner's two lines: "Weekly limit runs out Wed, 6 PM" and
    /// "27 hr before it resets. Slow to ~11 pts a day to make it."
    func bannerLines(title: String, windowSeconds: Int?) -> (headline: String, detail: String)? {
        guard runsOutBeforeReset, let when = runsOutWhenText, let lead = leadBeforeResetText else { return nil }
        var detail = "\(lead.prefix(1).uppercased() + lead.dropFirst())."
        if let budget = budget(windowSeconds: windowSeconds) {
            detail += " Slow to \(budget.sentenceText) to make it."
        }
        return ("\(title) runs out \(when)", detail)
    }

    /// The detail sheet's outlook: "Runs out Wed, about 6 PM." and
    /// "That's 27 hr before the reset. Staying under ~11 pts a day gets you there."
    func detailOutlook(windowSeconds: Int?) -> (headline: String, detail: String)? {
        guard runsOutBeforeReset, let when = runsOutWhenText, let lead = leadBeforeResetText else { return nil }
        let before = lead.replacingOccurrences(of: "before it resets", with: "before the reset")
        var detail = "That's \(before)."
        if let budget = budget(windowSeconds: windowSeconds) {
            detail += " Staying under \(budget.sentenceText) gets you there."
        }
        let headline = when.replacingOccurrences(of: ", ", with: ", about ")
        return ("Runs out \(headline).", detail)
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
