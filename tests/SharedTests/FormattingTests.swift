import SwiftUI
import XCTest

final class FormattingTests: XCTestCase {
    /// Newer ICU puts a narrow no-break space before AM/PM.
    private func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func requirePinnedLocale() throws {
        // The SharedTests scheme sets TZ=UTC and -AppleLocale en_US.
        XCTAssertEqual(TimeZone.current.secondsFromGMT(for: referenceNow), 0, "Run with the SharedTests scheme (TZ=UTC)")
        XCTAssertEqual(Locale.current.identifier, "en_US", "Run with the SharedTests scheme (-AppleLocale en_US)")
    }

    // MARK: - Percent

    func testPercentRoundsToWholeNumbers() {
        XCTAssertEqual(UsageFormat.percent(0), "0%")
        XCTAssertEqual(UsageFormat.percent(37.4), "37%")
        XCTAssertEqual(UsageFormat.percent(37.5), "38%")
        XCTAssertEqual(UsageFormat.percent(99.6), "100%")
        XCTAssertEqual(UsageFormat.percent(120), "120%")
        XCTAssertEqual(UsageFormat.percent(-0.4), "0%")
    }

    // MARK: - Countdowns

    func testCountdown() {
        func text(_ seconds: TimeInterval) -> String {
            UsageFormat.countdown(to: referenceNow.addingTimeInterval(seconds), from: referenceNow)
        }
        XCTAssertEqual(text(2 * 3_600 + 14 * 60), "2h 14m")
        XCTAssertEqual(text(2 * 3_600 + 14 * 60 + 59), "2h 14m")
        XCTAssertEqual(text(3 * 86_400 + 4 * 3_600 + 30 * 60), "3d 4h")
        XCTAssertEqual(text(86_400), "1d 0h")
        XCTAssertEqual(text(3_600), "1h 0m")
        XCTAssertEqual(text(12 * 60), "12m")
        // Under a minute, and in the past, show the floor of one minute.
        XCTAssertEqual(text(30), "1m")
        XCTAssertEqual(text(0), "1m")
        XCTAssertEqual(text(-600), "1m")
    }

    func testLongCountdown() {
        func text(_ seconds: TimeInterval) -> String {
            UsageFormat.longCountdown(to: referenceNow.addingTimeInterval(seconds), from: referenceNow)
        }
        XCTAssertEqual(text(4 * 3_600 + 43 * 60), "4 hr 43 min")
        XCTAssertEqual(text(5 * 86_400 + 22 * 3_600 + 59 * 60), "5 days 22 hr")
        XCTAssertEqual(text(86_400 + 3_600), "1 day 1 hr")
        XCTAssertEqual(text(12 * 60), "12 min")
        XCTAssertEqual(text(59), "1 min")
        XCTAssertEqual(text(-1), "1 min")
    }

    // MARK: - Reset text

    func testResetText() {
        XCTAssertEqual(UsageFormat.resetText(window(percent: 10, resetsAt: nil), now: referenceNow), "No reset time")
        XCTAssertEqual(UsageFormat.resetText(window(percent: 10, resetsAt: referenceNow), now: referenceNow), "Reset")
        XCTAssertEqual(UsageFormat.resetText(window(percent: 10, resetsAt: referenceNow.addingTimeInterval(-60)), now: referenceNow), "Reset")
        let soon = window(percent: 10, resetsAt: referenceNow.addingTimeInterval(2 * 3_600 + 14 * 60))
        XCTAssertEqual(UsageFormat.resetText(soon, now: referenceNow), "Resets in 2h 14m")
    }

    func testResetTextDetailed() throws {
        try requirePinnedLocale()
        XCTAssertEqual(UsageFormat.resetTextDetailed(window(percent: 10, resetsAt: nil), now: referenceNow), "No reset time")
        XCTAssertEqual(UsageFormat.resetTextDetailed(window(percent: 10, resetsAt: referenceNow), now: referenceNow), "Reset")
        // 21:50:51 Saturday + 4 h 43 min = 02:33:51 Sunday (UTC).
        let w = window(percent: 10, resetsAt: referenceNow.addingTimeInterval(4 * 3_600 + 43 * 60))
        XCTAssertEqual(plainSpaces(UsageFormat.resetTextDetailed(w, now: referenceNow)),
                       "Resets in 4 hr 43 min (Sun, 2:33 AM)")
    }

    // MARK: - Money and tokens

    func testUSD() throws {
        try requirePinnedLocale()
        XCTAssertEqual(UsageFormat.usd(12.34), "$12.34")
        XCTAssertEqual(UsageFormat.usd(1_234.5), "$1,234.50")
        XCTAssertEqual(UsageFormat.usd(0), "$0.00")
        XCTAssertEqual(UsageFormat.usd(0.004), "<$0.01")
        XCTAssertEqual(UsageFormat.usd(0.01), "$0.01")
    }

    func testTokens() throws {
        try requirePinnedLocale()
        XCTAssertEqual(UsageFormat.tokens(38), "38")
        XCTAssertEqual(UsageFormat.tokens(1_500), "1.5K")
        XCTAssertEqual(UsageFormat.tokens(512_000), "512K")
        XCTAssertEqual(UsageFormat.tokens(1_240_000_000), "1.24B")
        XCTAssertEqual(UsageFormat.tokens(1_234_567), "1.23M")
    }

    // MARK: - Tints

    func testTintThresholds() {
        XCTAssertEqual(UsageFormat.tint(for: 0), .green)
        XCTAssertEqual(UsageFormat.tint(for: 59.9), .green)
        XCTAssertEqual(UsageFormat.tint(for: 60), .orange)
        XCTAssertEqual(UsageFormat.tint(for: 84.9), .orange)
        XCTAssertEqual(UsageFormat.tint(for: 85), .red)
        XCTAssertEqual(UsageFormat.tint(for: 150), .red)
    }

    func testProviderTint() {
        XCTAssertEqual(UsageFormat.providerTint("claude"), Color(red: 0.85, green: 0.47, blue: 0.34))
        XCTAssertEqual(UsageFormat.providerTint("not-a-provider"), .accentColor)
    }

    // MARK: - Bar mode text (SharedStore.swift)

    func testBarModeText() {
        XCTAssertEqual(BarMode.used.percentText(used: 32), "32% used")
        XCTAssertEqual(BarMode.remaining.percentText(used: 32), "68% left")
        XCTAssertEqual(BarMode.used.value(used: 32), 32)
        XCTAssertEqual(BarMode.remaining.value(used: 32), 68)
    }
}
