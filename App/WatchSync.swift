import Foundation
import WatchConnectivity

final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ snapshot: UsageSnapshot?) {
        guard let data = encodedUsage(snapshot), WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["usage": data])
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        publish(SharedStore.lastSnapshot)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["requestUsage"] as? Bool == true,
              let data = encodedUsage(SharedStore.lastSnapshot) else {
            replyHandler([:])
            return
        }
        replyHandler(["usage": data])
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private func encodedUsage(_ snapshot: UsageSnapshot?) -> Data? {
        guard let snapshot else { return nil }
        return try? JSONEncoder().encode(WatchUsage(snapshot: snapshot))
    }
}
