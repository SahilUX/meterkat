import SwiftUI

/// Local CLI tokens and what they would cost at standard API rates. Shown
/// in the app windows only, not the menu bar panel.
struct APICostView: View {
    let cost: APICost

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(showsTokens ? "Tokens and API rates" : "At standard API rates")
                .font(.subheadline.weight(.semibold))
            if cost.priced > 0 || showsTokens {
                HStack(spacing: 14) {
                    amount("7 days", cost.weekUSD, tokens: cost.weekTokens)
                    amount("30 days", cost.monthUSD, tokens: cost.monthTokens)
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Companions before 2.1 send no token counts.
    private var showsTokens: Bool { cost.weekTokens != nil || cost.monthTokens != nil }

    private func amount(_ period: String, _ value: Double, tokens: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(period).font(.caption).foregroundStyle(.secondary)
            if cost.priced > 0 {
                Text(value > 0 && value < 0.01 ? "<$0.01" : value.formatted(.currency(code: "USD")))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            if let tokens {
                Text("\(tokens.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))) tokens")
                    .font(cost.priced > 0 ? .caption : .subheadline.weight(.semibold))
                    .foregroundStyle(cost.priced > 0 ? .secondary : .primary)
                    .monospacedDigit()
            }
        }
    }

    private var caption: String {
        let machines = cost.machines ?? 1
        let source = machines > 1 ? "CLI tokens from \(machines) computers" : "Local CLI tokens"
        let basis = "\(source), priced at standard API rates (October 2026). Not a bill."
        if cost.unpriced > 0 {
            return "\(basis) \(cost.unpriced) records use models without listed prices."
        }
        return basis
    }
}
