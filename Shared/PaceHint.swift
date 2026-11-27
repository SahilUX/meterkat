import SwiftUI

/// Whether usage is running ahead of or behind an even pace through the window.
struct PaceHint: View {
    /// `UsageWindow.paceDelta`, in percentage points.
    let delta: Double

    /// Within this many points either way counts as on pace.
    static let tolerance: Double = 5

    var body: some View {
        Group {
            if delta > Self.tolerance {
                Text("Now: ahead of even pace").foregroundStyle(.orange)
            } else if delta < -Self.tolerance {
                Text("Now: under even pace").foregroundStyle(.green)
            } else {
                Text("Now: on even pace").foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.medium))
    }
}
