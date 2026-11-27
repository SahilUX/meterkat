import XCTest

/// A `/v1/usage` response in the shape `companion/meterkat.py` serves.
/// Fake values only.
let sampleSnapshotJSON = """
{
  "generatedAt": "2026-10-24T21:50:51Z",
  "host": "testbox",
  "companionVersion": "2.5.0",
  "providers": [
    {
      "id": "claude",
      "name": "Claude",
      "plan": "max",
      "account": "User@Example.com ",
      "status": "ok",
      "error": null,
      "fetchedAt": "2026-10-24T21:50:46.123Z",
      "windows": [
        {"id": "five_hour", "kind": "session", "label": "5-hour", "percent": 38.0,
         "resetsAt": "2026-10-25T01:40:00Z", "windowSeconds": 18000},
        {"id": "weekly", "kind": "weekly", "label": "Weekly", "percent": 38.5,
         "resetsAt": "2026-10-29T16:59:59Z", "windowSeconds": 604800},
        {"id": "weekly_fable", "kind": "model", "label": "Fable", "percent": 0.0,
         "resetsAt": "2026-10-29T17:00:00Z", "windowSeconds": 604800}
      ],
      "details": [{"label": "Extra usage", "value": "Off"}],
      "breakdown": {
        "title": "Weekly usage by product",
        "window": "weekly",
        "asOf": "2026-10-24T21:50:46Z",
        "rows": [{"key": "claude_code", "label": "Claude Code", "percent": 100.0}]
      },
      "stale": false,
      "apiCost": {
        "weekUSD": 12.5, "monthUSD": 40.0, "weekTokens": 1000, "monthTokens": 4000,
        "priced": 3, "unpriced": 0,
        "since": "2026-10-01T00:00:00Z",
        "estimatedThrough": "2026-10-10T23:59:59Z",
        "periods": {
          "day": {"usd": 1.25, "tokens": 100, "input": 40, "output": 30, "cacheRead": 20, "cacheWrite": 10,
                  "priced": 1, "unpriced": 0,
                  "models": [{"model": "claude-test-1", "tokens": 100, "usd": 1.25}]},
          "week": {"usd": 12.5, "tokens": 1000, "input": 400, "output": 300, "cacheRead": 200, "cacheWrite": 100,
                   "priced": 3, "unpriced": 0, "models": []}
        }
      },
      "futureField": "ignored"
    },
    {
      "id": "openai",
      "name": "ChatGPT Codex",
      "plan": "plus",
      "account": null,
      "status": "error",
      "error": "Token expired",
      "fetchedAt": null,
      "windows": [
        {"id": "five_hour", "kind": "session", "label": "5-hour", "percent": 12.0,
         "resetsAt": null, "windowSeconds": null}
      ],
      "stale": true
    },
    {
      "id": "brand_new_provider",
      "name": "Someday",
      "status": "no_plan",
      "windows": []
    }
  ]
}
"""

/// A `/v1/history` response in the companion's shape.
let sampleHistoryJSON = """
{
  "generatedAt": "2026-10-24T21:50:51Z",
  "series": [
    {
      "provider": "claude",
      "window": "five_hour",
      "resetsAt": "2026-10-25T01:40:00Z",
      "windowSeconds": 18000,
      "points": [[1793051400, 30.0], [1793051700, 35.0], [1793052000], [1793052000, 40.0]],
      "prediction": {"current": 40.0, "ratePerHour": 60.0, "projectedAtReset": 190.0,
                     "runsOutAt": "2026-10-24T22:50:51Z", "basis": "recent_trend", "trendMinutes": 15.0}
    },
    {
      "provider": "openai",
      "window": "weekly",
      "resetsAt": null,
      "windowSeconds": null,
      "points": [],
      "prediction": null
    }
  ]
}
"""

final class UsageModelsTests: XCTestCase {
    // MARK: - Decoding

    func testDecodesSampleSnapshot() throws {
        let snapshot = try decodeUsage(UsageSnapshot.self, sampleSnapshotJSON)
        XCTAssertEqual(snapshot.generatedAt, date("2026-10-24T21:50:51Z"))
        XCTAssertEqual(snapshot.host, "testbox")
        XCTAssertEqual(snapshot.companionVersion, "2.5.0")
        XCTAssertEqual(snapshot.providers.map(\.id), ["claude", "openai", "brand_new_provider"])

        let claude = try XCTUnwrap(snapshot.provider(.claude))
        XCTAssertEqual(claude.plan, "max")
        XCTAssertTrue(claude.isOK)
        XCTAssertFalse(claude.isStale)
        XCTAssertEqual(claude.providerID, .claude)
        // Fractional seconds are accepted.
        let fetchedAt = try XCTUnwrap(claude.fetchedAt)
        XCTAssertEqual(fetchedAt.timeIntervalSince(date("2026-10-24T21:50:46Z")), 0.123, accuracy: 1e-6)
        XCTAssertEqual(claude.windows.count, 3)
        XCTAssertEqual(claude.window(.weekly)?.percent, 38.5)
        XCTAssertEqual(claude.window(.fable)?.label, "Fable")
        XCTAssertNil(claude.window(.monthly))
        XCTAssertEqual(claude.details, [ProviderDetail(label: "Extra usage", value: "Off")])
        XCTAssertEqual(claude.breakdown?.rows.first?.label, "Claude Code")
        XCTAssertEqual(claude.breakdown?.asOf, date("2026-10-24T21:50:46Z"))

        let cost = try XCTUnwrap(claude.apiCost)
        XCTAssertEqual(cost.weekUSD, 12.5)
        XCTAssertEqual(cost.since, date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(cost.estimatedThrough, date("2026-10-10T23:59:59Z"))
        XCTAssertNil(cost.machines)
        let day = try XCTUnwrap(cost.period(.day))
        XCTAssertEqual(day.cacheRead, 20)
        XCTAssertEqual(day.requests, 1)
        XCTAssertEqual(day.models, [ModelTokens(model: "claude-test-1", tokens: 100, usd: 1.25)])
        // Periods present: a range the companion didn't send is missing, not derived.
        XCTAssertNil(cost.period(.month))

        let openai = try XCTUnwrap(snapshot.provider(.openai))
        XCTAssertFalse(openai.isOK)
        XCTAssertTrue(openai.isStale)
        XCTAssertEqual(openai.error, "Token expired")
        XCTAssertNil(openai.account)
        XCTAssertNil(openai.fetchedAt)
        XCTAssertNil(openai.apiCost)
        XCTAssertNil(openai.window(.fiveHour)?.resetsAt)

        // A provider this build doesn't know still decodes.
        let unknown = snapshot.providers[2]
        XCTAssertNil(unknown.providerID)
        XCTAssertTrue(unknown.isNoPlan)
        XCTAssertNil(unknown.stale)
        XCTAssertFalse(unknown.isStale)
    }

    func testSnapshotRoundTripsThroughTheUsageCoders() throws {
        // Whole-second dates survive; the encoder drops fractional seconds.
        var snapshot = try decodeUsage(UsageSnapshot.self, sampleSnapshotJSON)
        snapshot.providers[0].fetchedAt = date("2026-10-24T21:50:46Z")
        let data = try JSONEncoder.usage.encode(snapshot)
        XCTAssertEqual(try JSONDecoder.usage.decode(UsageSnapshot.self, from: data), snapshot)
    }

    func testRejectsABadDate() {
        let json = #"{"generatedAt": "yesterday", "providers": []}"#
        XCTAssertThrowsError(try decodeUsage(UsageSnapshot.self, json))
    }

    func testISO8601Parsing() {
        XCTAssertEqual(ISO8601Parsing.parse("2026-10-24T21:50:51Z"), date("2026-10-24T21:50:51Z"))
        XCTAssertEqual(ISO8601Parsing.parse("2026-10-24T23:50:51+02:00"), date("2026-10-24T21:50:51Z"))
        XCTAssertEqual(ISO8601Parsing.parse("2026-10-24T21:50:51.500Z")?.timeIntervalSince(date("2026-10-24T21:50:51Z")), 0.5)
        XCTAssertNil(ISO8601Parsing.parse("2026-10-24"))
        XCTAssertNil(ISO8601Parsing.parse(""))
    }

    func testDecodesSampleHistory() throws {
        let history = try decodeUsage(UsageHistory.self, sampleHistoryJSON)
        XCTAssertEqual(history.series.count, 2)
        let series = try XCTUnwrap(history.series(provider: "claude", window: "five_hour"))
        // The malformed one-element point is dropped.
        XCTAssertEqual(series.samples, [
            UsageSample(date: Date(timeIntervalSince1970: 1_793_051_400), percent: 30),
            UsageSample(date: Date(timeIntervalSince1970: 1_793_051_700), percent: 35),
            UsageSample(date: Date(timeIntervalSince1970: 1_793_052_000), percent: 40),
        ])
        XCTAssertEqual(series.prediction?.basis, "recent_trend")
        XCTAssertEqual(series.prediction?.runsOutAt, date("2026-10-24T22:50:51Z"))
        XCTAssertNil(history.series(provider: "claude", window: "weekly"))
        XCTAssertNil(history.series(provider: "openai", window: "weekly")?.prediction)
        XCTAssertEqual(history.series(provider: "openai", window: "weekly")?.samples, [])
    }

    // MARK: - Provider identity

    func testIdentityKeyNormalizesTheAccount() {
        XCTAssertEqual(provider(account: " User@Example.com\n").identityKey, "claude|user@example.com")
        XCTAssertEqual(provider(account: nil).identityKey, "claude|unknown")
        XCTAssertEqual(provider(account: "   ").identityKey, "claude|unknown")
        XCTAssertEqual(provider(id: "openai", account: "a@b.c").identityKey, "openai|a@b.c")
    }

    func testAlertIDIsHexOfTheIdentityKey() {
        // "claude|x" in UTF-8 hex.
        XCTAssertEqual(provider(account: "x").alertID, "claude_" + "636c617564657c78")
    }

    func testStaleFlags() {
        var usage = provider()
        XCTAssertFalse(usage.isStale)
        usage.stale = true
        XCTAssertTrue(usage.isStale)
        usage.stale = false
        usage.sourceIsStale = true
        XCTAssertTrue(usage.isStale)
    }

    // MARK: - Window maths

    func testIsResetAndEffectivePercent() {
        let w = window(percent: 140, resetsAt: referenceNow)
        XCTAssertTrue(w.isReset(at: referenceNow))
        XCTAssertFalse(w.isReset(at: referenceNow.addingTimeInterval(-1)))
        XCTAssertEqual(w.effectivePercent(at: referenceNow), 0)
        XCTAssertEqual(w.effectivePercent(at: referenceNow.addingTimeInterval(-1)), 100)
        XCTAssertEqual(window(percent: -5, resetsAt: nil).effectivePercent(at: referenceNow), 0)
        XCTAssertEqual(window(percent: 42, resetsAt: nil).effectivePercent(at: referenceNow), 42)
        XCTAssertFalse(window(percent: 42, resetsAt: nil).isReset(at: referenceNow))
    }

    func testWindowStart() {
        let resetsAt = referenceNow.addingTimeInterval(3_600)
        XCTAssertEqual(window(percent: 0, resetsAt: resetsAt).windowStart, resetsAt.addingTimeInterval(-18_000))
        XCTAssertNil(window(percent: 0, resetsAt: resetsAt, windowSeconds: nil).windowStart)
        XCTAssertNil(window(percent: 0, resetsAt: resetsAt, windowSeconds: 0).windowStart)
        XCTAssertNil(window(percent: 0, resetsAt: nil).windowStart)
    }

    func testElapsedFraction() {
        let w = window(percent: 0, resetsAt: referenceNow.addingTimeInterval(9_000))
        XCTAssertEqual(w.elapsedFraction(at: referenceNow), 0.5)
        XCTAssertEqual(w.elapsedFraction(at: referenceNow.addingTimeInterval(-9_000)), 0)
        // Before the window started (clock skew) clamps to 0.
        XCTAssertEqual(w.elapsedFraction(at: referenceNow.addingTimeInterval(-20_000)), 0)
        XCTAssertNil(w.elapsedFraction(at: referenceNow.addingTimeInterval(9_000)))
        XCTAssertNil(window(percent: 0, resetsAt: nil).elapsedFraction(at: referenceNow))
        XCTAssertNil(window(percent: 0, resetsAt: referenceNow.addingTimeInterval(60), windowSeconds: nil).elapsedFraction(at: referenceNow))
    }

    func testBarValues() {
        let w = window(percent: 30, resetsAt: referenceNow.addingTimeInterval(13_500))
        let used = w.barValues(mode: .used, at: referenceNow)
        XCTAssertEqual(used.fill, 30)
        XCTAssertEqual(try XCTUnwrap(used.marker), 0.25, accuracy: 1e-12)
        let remaining = w.barValues(mode: .remaining, at: referenceNow)
        XCTAssertEqual(remaining.fill, 70)
        XCTAssertEqual(try XCTUnwrap(remaining.marker), 0.75, accuracy: 1e-12)

        let noReset = window(percent: 30, resetsAt: nil)
        XCTAssertNil(noReset.barValues(mode: .used, at: referenceNow).marker)
        XCTAssertNil(noReset.barValues(mode: .remaining, at: referenceNow).marker)
        XCTAssertEqual(noReset.barValues(mode: .remaining, at: referenceNow).fill, 70)
    }

    func testPaceDelta() throws {
        // Halfway through the window.
        let ahead = window(percent: 70, resetsAt: referenceNow.addingTimeInterval(9_000))
        XCTAssertEqual(try XCTUnwrap(ahead.paceDelta(at: referenceNow)), 20, accuracy: 1e-9)
        let behind = window(percent: 30, resetsAt: referenceNow.addingTimeInterval(9_000))
        XCTAssertEqual(try XCTUnwrap(behind.paceDelta(at: referenceNow)), -20, accuracy: 1e-9)
        XCTAssertNil(window(percent: 30, resetsAt: nil).paceDelta(at: referenceNow))
        XCTAssertNil(window(percent: 30, resetsAt: referenceNow).paceDelta(at: referenceNow))
    }

    // MARK: - Slots and providers

    func testWindowSlotRoundTripsWindowIDs() {
        for slot in WindowSlot.allCases {
            XCTAssertEqual(WindowSlot(windowID: slot.windowID), slot)
        }
        XCTAssertEqual(WindowSlot(windowID: "weekly_fable"), .fable)
        XCTAssertNil(WindowSlot(windowID: "weekly_opus"))
        XCTAssertNil(WindowSlot(windowID: "fiveHour"))
    }

    func testEveryProviderHasADisplayName() {
        for id in ProviderID.allCases {
            XCTAssertFalse(id.displayName.isEmpty, id.rawValue)
        }
        XCTAssertEqual(ProviderID.claude.knownSlots, [.fiveHour, .weekly, .fable])
        XCTAssertEqual(ProviderID.deepseek.knownSlots, [])
    }

    // MARK: - API cost

    func testLegacyCostPeriodsComeFromWeekAndMonthTotals() {
        let cost = APICost(weekUSD: 1.5, monthUSD: 6, weekTokens: 10, monthTokens: nil, priced: 4, unpriced: 1)
        XCTAssertEqual(cost.period(.week), APICostPeriod(usd: 1.5, tokens: 10, priced: 4, unpriced: 1))
        XCTAssertEqual(cost.period(.month), APICostPeriod(usd: 6, tokens: nil, priced: 4, unpriced: 1))
        XCTAssertNil(cost.period(.day))
        XCTAssertNil(cost.period(.all))
    }

    func testAddingCostsFromTwoMachines() {
        let a = APICost(weekUSD: 1, monthUSD: 4, weekTokens: 100, monthTokens: nil, priced: 2, unpriced: 1,
                        since: date("2026-10-05T00:00:00Z"), estimatedThrough: date("2026-10-07T23:59:59Z"),
                        periods: ["week": APICostPeriod(usd: 1, tokens: 100, priced: 2, unpriced: 1)])
        let b = APICost(weekUSD: 2, monthUSD: 3, weekTokens: nil, monthTokens: 50, priced: 3, unpriced: 0,
                        since: date("2026-10-01T00:00:00Z"), estimatedThrough: nil,
                        periods: ["week": APICostPeriod(usd: 2, tokens: 50, priced: 3, unpriced: 0),
                                  "all": APICostPeriod(usd: 9, tokens: 900, priced: 9, unpriced: 0)])
        let total = a.adding(b)
        XCTAssertEqual(total.weekUSD, 3)
        XCTAssertEqual(total.monthUSD, 7)
        XCTAssertEqual(total.weekTokens, 100)
        XCTAssertEqual(total.monthTokens, 50)
        XCTAssertEqual(total.priced, 5)
        XCTAssertEqual(total.unpriced, 1)
        XCTAssertEqual(total.machines, 2)
        XCTAssertEqual(total.since, date("2026-10-01T00:00:00Z"))
        XCTAssertEqual(total.estimatedThrough, date("2026-10-07T23:59:59Z"))
        XCTAssertEqual(total.periods?["week"], APICostPeriod(usd: 3, tokens: 150, priced: 5, unpriced: 1))
        XCTAssertEqual(total.periods?["all"], APICostPeriod(usd: 9, tokens: 900, priced: 9, unpriced: 0))

        // A third machine adds to the count already summed.
        XCTAssertEqual(total.adding(a).machines, 3)
    }

    func testAddingDropsPeriodsWhenOneMachineHasNone() {
        let withPeriods = APICost(weekUSD: 1, monthUSD: 1, priced: 1, unpriced: 0,
                                  periods: ["week": APICostPeriod(usd: 1, tokens: 1, priced: 1, unpriced: 0)])
        let old = APICost(weekUSD: 1, monthUSD: 1, priced: 1, unpriced: 0)
        XCTAssertNil(withPeriods.adding(old).periods)
        XCTAssertNil(old.adding(withPeriods).periods)
        // Then the legacy week/month totals are used.
        XCTAssertEqual(old.adding(withPeriods).period(.week)?.usd, 2)
    }

    func testAddingPeriodsMergesModelsByName() {
        let a = APICostPeriod(usd: 1, tokens: 300, input: 100, output: nil, cacheRead: nil, cacheWrite: nil,
                              priced: 1, unpriced: 1,
                              models: [ModelTokens(model: "m-a", tokens: 200, usd: 1),
                                       ModelTokens(model: "m-free", tokens: 100, usd: nil)])
        let b = APICostPeriod(usd: 0.5, tokens: nil, input: 50, output: 20, cacheRead: nil, cacheWrite: nil,
                              priced: 2, unpriced: 0,
                              models: [ModelTokens(model: "m-free", tokens: 250, usd: nil),
                                       ModelTokens(model: "m-b", tokens: 10, usd: 0.5),
                                       ModelTokens(model: "m-a", tokens: 1, usd: nil)])
        let total = a.adding(b)
        XCTAssertEqual(total.usd, 1.5)
        XCTAssertEqual(total.tokens, 300)
        XCTAssertEqual(total.input, 150)
        XCTAssertEqual(total.output, 20)
        XCTAssertNil(total.cacheRead)
        XCTAssertEqual(total.priced, 3)
        XCTAssertEqual(total.unpriced, 1)
        XCTAssertEqual(total.requests, 4)
        XCTAssertEqual(total.models, [
            ModelTokens(model: "m-free", tokens: 350, usd: nil),
            ModelTokens(model: "m-a", tokens: 201, usd: 1),
            ModelTokens(model: "m-b", tokens: 10, usd: 0.5),
        ])

        let noModels = APICostPeriod(usd: 0, tokens: nil, priced: 0, unpriced: 0)
        XCTAssertNil(noModels.adding(noModels).models)
        XCTAssertEqual(noModels.adding(a).models?.count, 2)
    }

    func testAPICostRangeLabels() {
        XCTAssertEqual(APICostRange.allCases.map(\.label), ["24h", "7d", "30d", "All"])
        XCTAssertEqual(APICostRange.week.longLabel, "last 7 days")
    }
}
