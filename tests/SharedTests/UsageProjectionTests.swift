import XCTest

final class UsageProjectionTests: XCTestCase {
    /// A 5-hour window that started 2.5 hours before `referenceNow`.
    private let resetsAt = referenceNow.addingTimeInterval(2.5 * 3_600)

    private func sample(minutesAgo: Double, _ percent: Double) -> UsageSample {
        UsageSample(date: referenceNow.addingTimeInterval(-minutesAgo * 60), percent: percent)
    }

    // MARK: - When there is no projection

    func testNilWithoutResetTime() {
        let w = window(percent: 40, resetsAt: nil)
        XCTAssertNil(UsageProjection.make(window: w, samples: [], now: referenceNow))
    }

    func testNilWithoutWindowLength() {
        let w = window(percent: 40, resetsAt: resetsAt, windowSeconds: nil)
        XCTAssertNil(UsageProjection.make(window: w, samples: [], now: referenceNow))
    }

    func testNilOnceReset() {
        let w = window(percent: 40, resetsAt: referenceNow)
        XCTAssertNil(UsageProjection.make(window: w, samples: [], now: referenceNow))
        let past = window(percent: 40, resetsAt: referenceNow.addingTimeInterval(-1))
        XCTAssertNil(UsageProjection.make(window: past, samples: [], now: referenceNow))
    }

    func testNilAtTheVeryStartOfTheWindowWithoutTrend() {
        // Window starts exactly now: no elapsed time to average over.
        let w = window(percent: 0, resetsAt: referenceNow.addingTimeInterval(18_000))
        XCTAssertNil(UsageProjection.make(window: w, samples: [], now: referenceNow))
    }

    // MARK: - Window average

    func testWindowAverageLastsUntilReset() throws {
        let w = window(percent: 25, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: [], now: referenceNow))
        XCTAssertEqual(p.basis, .windowAverage)
        XCTAssertEqual(p.current, 25)
        XCTAssertEqual(p.now, referenceNow)
        XCTAssertEqual(p.resetsAt, resetsAt)
        XCTAssertEqual(p.ratePerHour, 10, accuracy: 1e-9)
        XCTAssertEqual(p.projectedAtReset, 50, accuracy: 1e-9)
        XCTAssertNil(p.runsOutAt)
        XCTAssertNil(p.runsOutText)
        XCTAssertEqual(p.outlookText, "Lasts until reset (~50% left)")
        XCTAssertEqual(p.basisDescription, "Projection from the average since the window started")
    }

    func testWindowAverageRunsOutBeforeReset() throws {
        // 60% in 2.5 h is 24 points/h: the remaining 40 points last 100 min.
        let w = window(percent: 60, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: [], now: referenceNow))
        XCTAssertEqual(p.ratePerHour, 24, accuracy: 1e-9)
        XCTAssertEqual(p.projectedAtReset, 120, accuracy: 1e-9)
        let runsOutAt = try XCTUnwrap(p.runsOutAt)
        XCTAssertEqual(runsOutAt.timeIntervalSince(referenceNow), 6_000, accuracy: 1e-6)
        XCTAssertEqual(p.runsOutText, "Runs out in ~1 hr 40 min")
        XCTAssertEqual(p.outlookText, "Runs out in ~1 hr 40 min")
    }

    func testExactlyReachingTheLimitAtResetDoesNotRunOut() throws {
        // 50% in 2.5 h reaches 100% exactly at the reset, not before it.
        let w = window(percent: 50, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: [], now: referenceNow))
        XCTAssertEqual(p.projectedAtReset, 100, accuracy: 1e-9)
        XCTAssertNil(p.runsOutAt)
        XCTAssertEqual(p.outlookText, "Lasts until reset (~0% left)")
    }

    func testLimitReached() throws {
        let w = window(percent: 100, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: [], now: referenceNow))
        XCTAssertNil(p.runsOutAt)
        XCTAssertEqual(p.outlookText, "Limit reached until reset")
    }

    func testCurrentIsClampedToZeroThroughHundred() throws {
        let over = window(percent: 140, resetsAt: resetsAt)
        XCTAssertEqual(try XCTUnwrap(UsageProjection.make(window: over, samples: [], now: referenceNow)).current, 100)
        let under = window(percent: -3, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: under, samples: [], now: referenceNow))
        XCTAssertEqual(p.current, 0)
        XCTAssertEqual(p.ratePerHour, 0)
        XCTAssertEqual(p.outlookText, "Lasts until reset (~100% left)")
    }

    // MARK: - Recent trend

    func testTrendMinutesIsFivePercentOfTheWindow() {
        XCTAssertEqual(UsageProjection.trendMinutes(for: window(percent: 0, resetsAt: nil, windowSeconds: 18_000)), 15)
        XCTAssertEqual(UsageProjection.trendMinutes(for: window(percent: 0, resetsAt: nil, windowSeconds: 604_800)), 504)
        XCTAssertEqual(UsageProjection.trendMinutes(for: window(percent: 0, resetsAt: nil, windowSeconds: 2_592_000)), 2_160)
        XCTAssertEqual(UsageProjection.trendMinutes(for: window(percent: 0, resetsAt: nil, windowSeconds: nil)), 0)
    }

    func testRecentTrendUsesLeastSquaresSlope() throws {
        // One point a minute over the last 10 minutes of a 15-minute trend.
        let samples = [sample(minutesAgo: 10, 30), sample(minutesAgo: 5, 35), sample(minutesAgo: 0, 40)]
        let w = window(percent: 40, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow))
        XCTAssertEqual(p.basis, .recentTrend(minutes: 15))
        XCTAssertEqual(p.ratePerHour, 60, accuracy: 1e-9)
        XCTAssertEqual(p.projectedAtReset, 40 + 60 * 2.5, accuracy: 1e-9)
        let runsOutAt = try XCTUnwrap(p.runsOutAt)
        XCTAssertEqual(runsOutAt.timeIntervalSince(referenceNow), 3_600, accuracy: 1e-6)
        XCTAssertEqual(p.outlookText, "Runs out in ~1 hr 0 min")
        XCTAssertEqual(p.basisDescription, "Projection from the last 15 min")
    }

    func testTrendFitsNoisySamples() throws {
        // Unsorted input, not on a straight line.
        let samples = [sample(minutesAgo: 0, 34), sample(minutesAgo: 8, 19), sample(minutesAgo: 12, 10), sample(minutesAgo: 4, 25)]
        let w = window(percent: 34, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow))
        // Least squares over (0,10),(4,19),(8,25),(12,34): slope = 1.95/min.
        XCTAssertEqual(p.ratePerHour, 1.95 * 60, accuracy: 1e-9)
    }

    func testTrendNeedsAQuarterOfTheTrendWindow() throws {
        // 15-minute trend needs samples spanning 3.75 minutes; 3 is too short.
        let short = [sample(minutesAgo: 3, 30), sample(minutesAgo: 0, 40)]
        let w = window(percent: 40, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: short, now: referenceNow))
        XCTAssertEqual(p.basis, .windowAverage)
        XCTAssertEqual(p.ratePerHour, 16, accuracy: 1e-9)

        let enough = [sample(minutesAgo: 3.75, 30), sample(minutesAgo: 0, 40)]
        let q = try XCTUnwrap(UsageProjection.make(window: w, samples: enough, now: referenceNow))
        XCTAssertEqual(q.basis, .recentTrend(minutes: 15))
    }

    func testSamplesOutsideTheTrendWindowAreIgnored() throws {
        // Old and future samples would change the slope if they counted.
        let samples = [
            sample(minutesAgo: 60, 0),
            sample(minutesAgo: 10, 30),
            sample(minutesAgo: 0, 40),
            sample(minutesAgo: -5, 99),
        ]
        let w = window(percent: 40, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow))
        XCTAssertEqual(p.basis, .recentTrend(minutes: 15))
        XCTAssertEqual(p.ratePerHour, 60, accuracy: 1e-9)
    }

    func testSamplesFromBeforeTheWindowStartAreIgnored() throws {
        // Window started 5 minutes ago; a sample from the previous cycle must not count.
        let w = window(percent: 10, resetsAt: referenceNow.addingTimeInterval(18_000 - 300))
        let samples = [sample(minutesAgo: 10, 90), sample(minutesAgo: 4, 2), sample(minutesAgo: 0, 10)]
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow))
        XCTAssertEqual(p.basis, .recentTrend(minutes: 15))
        XCTAssertEqual(p.ratePerHour, 120, accuracy: 1e-9)
    }

    func testFallingTrendClampsRateToZero() throws {
        let samples = [sample(minutesAgo: 10, 50), sample(minutesAgo: 0, 40)]
        let w = window(percent: 40, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow))
        XCTAssertEqual(p.ratePerHour, 0)
        XCTAssertEqual(p.projectedAtReset, 40)
        XCTAssertNil(p.runsOutAt)
        XCTAssertEqual(p.outlookText, "Lasts until reset (~60% left)")
    }

    func testSamplesAtTheSameInstantHaveZeroSlope() throws {
        let samples = [sample(minutesAgo: 0, 10), sample(minutesAgo: 0, 40)]
        let w = window(percent: 40, resetsAt: resetsAt)
        // A zero-minute trend accepts a zero span; with no spread in time the slope is 0.
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow, trendMinutes: 0))
        XCTAssertEqual(p.basis, .recentTrend(minutes: 0))
        XCTAssertEqual(p.ratePerHour, 0)
    }

    func testExplicitTrendMinutesOverridesTheDefault() throws {
        let samples = [sample(minutesAgo: 50, 0), sample(minutesAgo: 0, 50)]
        let w = window(percent: 50, resetsAt: resetsAt)
        let p = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow, trendMinutes: 60))
        XCTAssertEqual(p.basis, .recentTrend(minutes: 60))
        XCTAssertEqual(p.ratePerHour, 60, accuracy: 1e-9)
    }

    // MARK: - Basis description

    func testBasisDescriptionSwitchesToHoursFromTwoHours() {
        func text(_ minutes: Double) -> String {
            UsageProjection(current: 0, now: referenceNow, resetsAt: resetsAt, ratePerHour: 0,
                            projectedAtReset: 0, runsOutAt: nil, basis: .recentTrend(minutes: minutes)).basisDescription
        }
        XCTAssertEqual(text(15), "Projection from the last 15 min")
        XCTAssertEqual(text(119), "Projection from the last 119 min")
        XCTAssertEqual(text(120), "Projection from the last 2 hr")
        XCTAssertEqual(text(504), "Projection from the last 8 hr")
        XCTAssertEqual(text(2_160), "Projection from the last 36 hr")
    }

    // MARK: - From the companion's prediction

    func testFromCompanionPrediction() throws {
        let runsOutAt = referenceNow.addingTimeInterval(3_600)
        let data = UsagePredictionData(current: 40, ratePerHour: 60, projectedAtReset: 190,
                                       runsOutAt: runsOutAt, basis: "recent_trend", trendMinutes: 15)
        let p = try XCTUnwrap(UsageProjection.from(data, window: window(percent: 40, resetsAt: resetsAt), now: referenceNow))
        XCTAssertEqual(p, UsageProjection(current: 40, now: referenceNow, resetsAt: resetsAt, ratePerHour: 60,
                                          projectedAtReset: 190, runsOutAt: runsOutAt, basis: .recentTrend(minutes: 15)))

        let average = UsagePredictionData(current: 25, ratePerHour: 10, projectedAtReset: 50,
                                          runsOutAt: nil, basis: "window_average", trendMinutes: 15)
        XCTAssertEqual(UsageProjection.from(average, window: window(percent: 25, resetsAt: resetsAt), now: referenceNow)?.basis,
                       .windowAverage)
    }

    func testFromCompanionPredictionNeedsAFutureReset() {
        let data = UsagePredictionData(current: 40, ratePerHour: 60, projectedAtReset: 190,
                                       runsOutAt: nil, basis: "recent_trend", trendMinutes: 15)
        XCTAssertNil(UsageProjection.from(data, window: window(percent: 40, resetsAt: nil), now: referenceNow))
        XCTAssertNil(UsageProjection.from(data, window: window(percent: 40, resetsAt: referenceNow), now: referenceNow))
    }

    func testLocalProjectionMatchesTheCompanionFormula() throws {
        // Same inputs as companion/meterkat.py's prediction: both sides must agree.
        let samples = [sample(minutesAgo: 10, 30), sample(minutesAgo: 5, 35), sample(minutesAgo: 0, 40)]
        let w = window(percent: 40, resetsAt: resetsAt)
        let local = try XCTUnwrap(UsageProjection.make(window: w, samples: samples, now: referenceNow))
        let companion = UsagePredictionData(current: 40, ratePerHour: 60, projectedAtReset: 190,
                                            runsOutAt: referenceNow.addingTimeInterval(3_600),
                                            basis: "recent_trend", trendMinutes: 15)
        let fromCompanion = try XCTUnwrap(UsageProjection.from(companion, window: w, now: referenceNow))
        XCTAssertEqual(fromCompanion.basis, local.basis)
        XCTAssertEqual(fromCompanion.current, local.current)
        XCTAssertEqual(fromCompanion.ratePerHour, local.ratePerHour, accuracy: 1e-9)
        XCTAssertEqual(fromCompanion.projectedAtReset, local.projectedAtReset, accuracy: 1e-9)
        let localRunsOut = try XCTUnwrap(local.runsOutAt)
        let companionRunsOut = try XCTUnwrap(fromCompanion.runsOutAt)
        XCTAssertEqual(companionRunsOut.timeIntervalSince(localRunsOut), 0, accuracy: 1e-6)
    }
}
