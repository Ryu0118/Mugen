import Foundation
import UserNotifications

/// The parts of `UNUserNotificationCenter` that Mugen uses, so tests can replace the system center.
protocol NotificationCenterClient: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removeAllPendingNotificationRequests()
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredNotificationIdentifiers() async -> [String]
}

// UNUserNotificationCenter is thread-safe but not annotated as Sendable.
struct SystemNotificationCenter: NotificationCenterClient, @unchecked Sendable {
    let base: UNUserNotificationCenter

    func add(_ request: UNNotificationRequest) async throws {
        try await base.add(request)
    }

    func removeAllPendingNotificationRequests() {
        base.removeAllPendingNotificationRequests()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        base.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await base.pendingNotificationRequests()
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await base.deliveredNotifications().map(\.request.identifier)
    }
}
