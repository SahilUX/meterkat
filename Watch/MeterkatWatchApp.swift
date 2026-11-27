import SwiftUI
import WatchConnectivity

@main
struct MeterkatWatchApp: App {
    @StateObject private var store = WatchStore()

    var body: some Scene {
        WindowGroup { WatchHomeView().environmentObject(store) }
    }
}

@MainActor
final class WatchStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published var usage: WatchUsage?

    override init() {
        super.init()
        if let data = WCSession.default.receivedApplicationContext["usage"] as? Data {
            usage = try? JSONDecoder().decode(WatchUsage.self, from: data)
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receiveUsage(from: applicationContext)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        requestUsageIfReachable(session)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        requestUsageIfReachable(session)
    }

    private nonisolated func requestUsageIfReachable(_ session: WCSession) {
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["requestUsage": true], replyHandler: { [weak self] reply in
            self?.receiveUsage(from: reply)
        }, errorHandler: { _ in })
    }

    private nonisolated func receiveUsage(from payload: [String: Any]) {
        guard let data = payload["usage"] as? Data,
              let decoded = try? JSONDecoder().decode(WatchUsage.self, from: data) else { return }
        Task { @MainActor in usage = decoded }
    }
}

private struct WatchHomeView: View {
    @EnvironmentObject private var store: WatchStore

    var body: some View {
        Group {
            if let usage = store.usage {
                List {
                    Section {
                        Text("AI usage")
                            .font(.headline)
                        Text("Updated \(usage.updatedAt, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(usage.providers) { provider in
                        NavigationLink {
                            ProviderDetailView(provider: provider)
                        } label: {
                            ProviderRow(provider: provider)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "applewatch")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Open Meterkat on iPhone")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Usage appears after your iPhone syncs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
            }
        }
        .tint(.green)
    }
}

private struct ProviderRow: View {
    let provider: WatchProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.name).font(.headline)
                Spacer(minLength: 2)
                if let window = provider.windows.first {
                    Text("\(Int(window.percent.rounded()))%")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(tint(window.percent))
                }
            }
            if let window = provider.windows.first {
                ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                    .tint(tint(window.percent))
            } else {
                Text(provider.status == "ok" ? "No limit data" : provider.status.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func tint(_ percent: Double) -> Color {
        percent >= 85 ? .red : percent >= 60 ? .orange : .green
    }
}

private struct ProviderDetailView: View {
    let provider: WatchProvider

    var body: some View {
        List {
            Section(provider.name) {
                ForEach(provider.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.label)
                            Spacer()
                            Text("\(Int(window.percent.rounded()))%")
                                .fontWeight(.semibold)
                        }
                        ProgressView(value: min(max(window.percent, 0), 100), total: 100)
                            .tint(window.percent >= 85 ? .red : window.percent >= 60 ? .orange : .green)
                        if let reset = window.resetsAt {
                            Text(reset <= .now ? "Reset" : "Resets \(reset, style: .relative)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(provider.name)
    }
}
