import Foundation

/// JSON contract served by the companion at `GET /v1/usage`.
/// Keep in sync with `companion/meterkat.py`.
struct UsageSnapshot: Codable, Equatable {
    var generatedAt: Date
    var host: String?
    var companionVersion: String?
    var providers: [ProviderUsage]

    func provider(_ id: ProviderID) -> ProviderUsage? {
        providers.first { $0.id == id.rawValue }
    }
}

enum ProviderID: String, CaseIterable, Codable, Identifiable {
    case claude
    case openai
    case opencode
    case openrouter
    case copilot
    case gemini
    case cursor
    case zai
    case kimi
    case minimax
    case bailian
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .opencode: return "OpenCode"
        case .openrouter: return "OpenRouter"
        case .copilot: return "Copilot"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .zai: return "Z.ai"
        case .kimi: return "Moonshot Kimi"
        case .minimax: return "MiniMax"
        case .bailian: return "Alibaba Coding Plan"
        case .deepseek: return "DeepSeek API"
        }
    }

    /// Windows this provider can report, in display order. Used for
    /// settings (e.g. which resets to announce) before any data arrives.
    var knownSlots: [WindowSlot] {
        switch self {
        case .claude: return [.fiveHour, .weekly, .fable]
        case .openai: return [.fiveHour, .weekly]
        case .opencode: return [.fiveHour, .weekly, .monthly]
        case .openrouter: return [.daily]
        case .copilot: return [.monthly]
        case .gemini: return [.daily]
        case .cursor: return [.monthly]
        case .zai: return [.fiveHour, .monthly]
        case .kimi: return [.fiveHour, .weekly]
        case .minimax: return [.fiveHour, .weekly]
        case .bailian: return [.fiveHour, .weekly, .monthly]
        case .deepseek: return []
        }
    }
}

struct ProviderUsage: Codable, Equatable, Identifiable {
    var id: String            // "claude" | "openai" | "opencode"
    var name: String          // "Claude" | "ChatGPT Codex" | "OpenCode Go"
    var plan: String?         // "max", "pro", "plus", "go", ...
    var account: String?      // email if known
    var status: String        // "ok" | "error" | "not_signed_in" | "no_plan"
    var error: String?        // human-readable detail for any non-ok status
    var fetchedAt: Date?
    var windows: [UsageWindow]
    /// Extra facts worth showing (credits, spend, local stats). Companion 1.3+.
    var details: [ProviderDetail]?
    /// Where usage went, e.g. Claude's 7-day split across Claude Code,
    /// Chats and Cowork. Companion 1.3+.
    var breakdown: UsageBreakdown?
    /// Estimated standard API cost from CLI token logs, summed across every
    /// computer signed in to this account.
    var apiCost: APICost? = nil
    /// The last good usage, re-served because the CLI's token expired
    /// (`error` says so). `fetchedAt` is when it was fetched.
    var stale: Bool? = nil
    /// Added by the phone when combining multiple companions.
    var sourceClientID: UUID? = nil
    var sourceClientName: String? = nil
    var sourceIsStale: Bool? = nil

    /// Same provider and account on two computers represent one usage source.
    var identityKey: String {
        let accountKey = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(id)|\(accountKey.isEmpty ? "unknown" : accountKey)"
    }

    var alertID: String {
        id + "_" + identityKey.utf8.map { String(format: "%02x", $0) }.joined()
    }

    var isOK: Bool { status == "ok" }
    /// Old data: the companion's token expired, or the phone couldn't reach that computer.
    var isStale: Bool { stale == true || sourceIsStale == true }
    /// Signed in, but the account has no plan with limits (e.g. OpenCode
    /// Zen pay-as-you-go without Go). Show neutrally, not as an error.
    var isNoPlan: Bool { status == "no_plan" }
    var providerID: ProviderID? { ProviderID(rawValue: id) }

    func window(_ slot: WindowSlot) -> UsageWindow? {
        windows.first { $0.id == slot.windowID }
    }
}

struct APICost: Codable, Equatable {
    var weekUSD: Double
    var monthUSD: Double
    /// All tokens in the period, priced or not. Companion 2.1+.
    var weekTokens: Int? = nil
    var monthTokens: Int? = nil
    var priced: Int
    var unpriced: Int
    /// Computers summed into this total. Set by the phone when combining.
    var machines: Int? = nil
    /// The oldest log entry counted in the all-time period. Companion 2.2+.
    var since: Date? = nil
    /// The last day whose all-time totals come from Claude Code's /stats
    /// history rather than its logs, which it deletes after a while.
    var estimatedThrough: Date? = nil
    /// Totals keyed by `APICostRange.rawValue`. Companion 2.2+.
    var periods: [String: APICostPeriod]? = nil

    /// The totals for a range, if the companion reports them. Companions
    /// before 2.2 only cover 7 and 30 days, without the token split.
    func period(_ range: APICostRange) -> APICostPeriod? {
        if let periods { return periods[range.rawValue] }
        switch range {
        case .week: return APICostPeriod(usd: weekUSD, tokens: weekTokens, priced: priced, unpriced: unpriced)
        case .month: return APICostPeriod(usd: monthUSD, tokens: monthTokens, priced: priced, unpriced: unpriced)
        case .day, .all: return nil
        }
    }

    /// Two computers' totals for the same account, summed.
    func adding(_ other: APICost) -> APICost {
        var total = self
        total.weekUSD += other.weekUSD
        total.monthUSD += other.monthUSD
        if let tokens = other.weekTokens { total.weekTokens = (total.weekTokens ?? 0) + tokens }
        if let tokens = other.monthTokens { total.monthTokens = (total.monthTokens ?? 0) + tokens }
        total.priced += other.priced
        total.unpriced += other.unpriced
        total.machines = (machines ?? 1) + (other.machines ?? 1)
        total.since = [since, other.since].compactMap { $0 }.min()
        total.estimatedThrough = [estimatedThrough, other.estimatedThrough].compactMap { $0 }.max()
        if let mine = periods, let theirs = other.periods {
            total.periods = mine.merging(theirs) { $0.adding($1) }
        } else {
            // A machine on an older companion can't fill in every range.
            total.periods = nil
        }
        return total
    }
}

/// The ranges the API cost and token stats can be shown for.
enum APICostRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "24h"
        case .week: return "7d"
        case .month: return "30d"
        case .all: return "All"
        }
    }

    var longLabel: String {
        switch self {
        case .day: return "last 24 hours"
        case .week: return "last 7 days"
        case .month: return "last 30 days"
        case .all: return "all time"
        }
    }
}

/// Tokens and estimated cost for one range of local CLI logs.
struct APICostPeriod: Codable, Equatable {
    var usd: Double
    /// All tokens, priced or not. Nil from companions before 2.1.
    var tokens: Int?
    /// The split by kind. Companion 2.2+.
    var input: Int? = nil
    var output: Int? = nil
    var cacheRead: Int? = nil
    var cacheWrite: Int? = nil
    /// Requests whose model has a listed price, and those without one.
    var priced: Int
    var unpriced: Int
    /// The models with the most tokens, most first. Companion 2.2+.
    var models: [ModelTokens]? = nil

    var requests: Int { priced + unpriced }

    func adding(_ other: APICostPeriod) -> APICostPeriod {
        func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        var byName: [String: ModelTokens] = [:]
        for model in (models ?? []) + (other.models ?? []) {
            if let existing = byName[model.model] {
                byName[model.model] = ModelTokens(
                    model: model.model,
                    tokens: existing.tokens + model.tokens,
                    usd: existing.usd == nil && model.usd == nil ? nil : (existing.usd ?? 0) + (model.usd ?? 0))
            } else {
                byName[model.model] = model
            }
        }
        return APICostPeriod(
            usd: usd + other.usd,
            tokens: sum(tokens, other.tokens),
            input: sum(input, other.input),
            output: sum(output, other.output),
            cacheRead: sum(cacheRead, other.cacheRead),
            cacheWrite: sum(cacheWrite, other.cacheWrite),
            priced: priced + other.priced,
            unpriced: unpriced + other.unpriced,
            models: models == nil && other.models == nil ? nil : byName.values.sorted { $0.tokens > $1.tokens })
    }
}

struct ModelTokens: Codable, Equatable, Identifiable {
    var model: String
    var tokens: Int
    /// Nil when the model has no listed price.
    var usd: Double?

    var id: String { model }
}

struct ProviderDetail: Codable, Equatable, Identifiable {
    var label: String         // "Extra usage"
    var value: String         // "Off · $0.00 of $76.26 this month"

    var id: String { label }
}

struct UsageBreakdown: Codable, Equatable {
    var title: String         // "Weekly usage by product"
    var window: String?       // window id the split applies to, e.g. "weekly"
    var asOf: Date?
    var rows: [BreakdownRow]
}

struct BreakdownRow: Codable, Equatable, Identifiable {
    var key: String           // "claude_code"
    var label: String         // "Claude Code"
    var percent: Double       // share of the window's usage, 0...100

    var id: String { key }
}

struct UsageWindow: Codable, Equatable, Identifiable {
    var id: String            // "five_hour" | "weekly" | "monthly" | "weekly_fable" | "weekly_opus" | ...
    var kind: String          // "session" | "weekly" | "monthly" | "model"
    var label: String         // "5-hour" | "Weekly" | "Monthly" | "Fable"
    var percent: Double       // 0...100, as reported at fetch time
    var resetsAt: Date?
    var windowSeconds: Int?

    /// A window whose reset time has passed is back to 0% even if we
    /// haven't fetched since.
    func isReset(at date: Date = .now) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= date
    }

    func effectivePercent(at date: Date = .now) -> Double {
        isReset(at: date) ? 0 : min(max(percent, 0), 100)
    }

    /// When the current cycle began, if the window length is known.
    var windowStart: Date? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        return resetsAt.addingTimeInterval(-Double(windowSeconds))
    }

    /// Share of the window that has elapsed, 0...1: 2.5h into a 5h window
    /// is 0.5. Nil when the reset time or window length is unknown, or the
    /// window has already reset.
    func elapsedFraction(at date: Date = .now) -> Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0, resetsAt > date else { return nil }
        let remaining = resetsAt.timeIntervalSince(date)
        return min(max(1 - remaining / Double(windowSeconds), 0), 1)
    }

    /// Fill (0...100) and marker (0...1) for a bar in the given mode. In
    /// `.remaining` the fill is what's left and the marker is the time left.
    func barValues(mode: BarMode, at date: Date = .now) -> (fill: Double, marker: Double?) {
        let used = effectivePercent(at: date)
        let elapsed = elapsedFraction(at: date)
        switch mode {
        case .used: return (used, elapsed)
        case .remaining: return (100 - used, elapsed.map { 1 - $0 })
        }
    }

    /// Usage minus even pace, in percentage points. Positive means usage is
    /// running ahead of time (on track to hit the limit before the reset).
    func paceDelta(at date: Date = .now) -> Double? {
        guard let elapsed = elapsedFraction(at: date) else { return nil }
        return effectivePercent(at: date) - elapsed * 100
    }
}

/// The three windows the widgets surface.
/// The windows the widgets and settings surface.
enum WindowSlot: String, CaseIterable, Codable, Identifiable {
    case fiveHour
    case weekly
    case fable
    case monthly
    case daily

    var id: String { rawValue }

    init?(windowID: String) {
        guard let slot = Self.allCases.first(where: { $0.windowID == windowID }) else { return nil }
        self = slot
    }

    var windowID: String {
        switch self {
        case .fiveHour: return "five_hour"
        case .weekly: return "weekly"
        case .fable: return "weekly_fable"
        case .monthly: return "monthly"
        case .daily: return "daily"
        }
    }

    var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "Week"
        case .fable: return "Fable"
        case .monthly: return "Month"
        case .daily: return "Day"
        }
    }

    var longLabel: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .weekly: return "Weekly limit"
        case .fable: return "Fable weekly"
        case .monthly: return "Monthly limit"
        case .daily: return "Daily limit"
        }
    }
}

/// Response of `GET /v1/history`: usage samples the companion recorded for
/// each window's current cycle, oldest first.
struct UsageHistory: Codable, Equatable {
    var generatedAt: Date
    var series: [UsageSeries]

    func series(provider: String, window: String) -> UsageSeries? {
        series.first { $0.provider == provider && $0.window == window }
    }
}

struct UsageSeries: Codable, Equatable {
    var provider: String
    var window: String
    var resetsAt: Date?
    var windowSeconds: Int?
    /// `[epochSeconds, percentUsed]` pairs, oldest first.
    var points: [[Double]]
    var prediction: UsagePredictionData?

    var samples: [UsageSample] {
        points.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return UsageSample(date: Date(timeIntervalSince1970: pair[0]), percent: pair[1])
        }
    }
}

struct UsagePredictionData: Codable, Equatable {
    var current: Double
    var ratePerHour: Double
    var projectedAtReset: Double
    var runsOutAt: Date?
    var basis: String
    var trendMinutes: Double
}

struct UsageSample: Equatable, Identifiable {
    var date: Date
    var percent: Double

    var id: Date { date }
}

extension JSONDecoder {
    /// Accepts ISO-8601 with or without fractional seconds.
    static let usage: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601Parsing.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(raw)")
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let usage: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

enum ISO8601Parsing {
    static func parse(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }
}
