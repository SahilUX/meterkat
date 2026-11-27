import SwiftUI

/// "Last updated 9 hours ago. Claude token expired — run `claude` …" for
/// usage the companion re-served after the CLI's token expired.
struct StaleNote: View {
    let provider: ProviderUsage

    var body: some View {
        Label {
            if let fetchedAt = provider.fetchedAt {
                Text("Last updated \(fetchedAt, format: .relative(presentation: .named)). \(reason)")
            } else {
                Text(reason)
            }
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
    }

    private var reason: String {
        provider.error ?? "Couldn't refresh usage."
    }
}
