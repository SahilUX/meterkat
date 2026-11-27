import Foundation
import XCTest

/// A fixed instant from an ISO-8601 string. Tests never read the clock.
func date(_ iso: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let value = formatter.date(from: iso) else {
        XCTFail("Bad test date \(iso)", file: file, line: line)
        return Date(timeIntervalSince1970: 0)
    }
    return value
}

/// The reference "now" most tests use: Saturday 24 October 2026, 21:50:51 UTC.
let referenceNow = date("2026-10-24T21:50:51Z")

func window(
    id: String = "five_hour",
    kind: String = "session",
    label: String = "5-hour",
    percent: Double,
    resetsAt: Date?,
    windowSeconds: Int? = 18_000
) -> UsageWindow {
    UsageWindow(id: id, kind: kind, label: label, percent: percent, resetsAt: resetsAt, windowSeconds: windowSeconds)
}

func provider(
    id: String = "claude",
    account: String? = "user@example.com",
    status: String = "ok",
    windows: [UsageWindow] = [],
    apiCost: APICost? = nil,
    breakdown: UsageBreakdown? = nil,
    stale: Bool? = nil
) -> ProviderUsage {
    ProviderUsage(id: id, name: id.capitalized, plan: nil, account: account, status: status, error: nil,
                  fetchedAt: nil, windows: windows, details: nil, breakdown: breakdown,
                  apiCost: apiCost, stale: stale)
}

func decodeUsage<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder.usage.decode(type, from: Data(json.utf8))
}
