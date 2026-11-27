import BackgroundTasks
import Foundation
import WidgetKit

enum BackgroundRefresh {
    /// Call from `application(_:didFinishLaunchingWithOptions:)`.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppConstants.backgroundRefreshID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppConstants.backgroundRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("BackgroundRefresh: submit failed: \(error)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            let clients = SharedStore.clients
            guard !clients.isEmpty else {
                task.setTaskCompleted(success: false)
                return
            }
            let result = await ClientMerge.refresh(clients)
            if result.didFetch, let snapshot = ClientMerge.snapshot(result.clients, unavailable: Set(result.errors.keys)) {
                let current = SharedStore.clients
                guard current.map(\.id) == clients.map(\.id),
                      zip(current, clients).allSatisfy({ $0.0.config == $0.1.config }) else {
                    task.setTaskCompleted(success: false)
                    return
                }
                SharedStore.clients = result.clients
                SharedStore.lastSnapshot = snapshot
                await NotificationManager.process(snapshot)
                WidgetCenter.shared.reloadAllTimelines()
                task.setTaskCompleted(success: true)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}
