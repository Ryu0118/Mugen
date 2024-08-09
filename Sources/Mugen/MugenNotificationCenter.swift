import Foundation
import UserNotifications
import CoreLocation

public struct MugenNotificationCenter: Sendable {
    let userNotificationCenter: UNUserNotificationCenter
    let storage: NotificationStorage

    public init(
        userNotificationCenter: UNUserNotificationCenter,
        dataSource: DataSource
    ) {
        self.userNotificationCenter = userNotificationCenter
        self.storage = NotificationStorage(dataSource: dataSource)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await userNotificationCenter.add(request)
        try storage.append(request)
    }

    public func removeAllPendingNotificationRequests() throws {
        userNotificationCenter.removeAllPendingNotificationRequests()
        try storage.removeAll()
    }

    public func removePendingNotificationRequests(
        withIdentifiers identifiers: [String]
    ) throws {
        userNotificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        try storage.remove(withIdentifiers: identifiers)
    }

    @_disfavoredOverload
    public func pendingNotificationRequests() async throws -> [UNNotificationRequest] {
        try await pendingNotificationRequests()
            .sorted(by: { $0.key < $1.key })
            .map(\.value)
    }

    public func configure() async throws {
        let allPendingNotifications = try await pendingNotificationRequests()
        userNotificationCenter.removeAllPendingNotificationRequests()
        allPendingNotifications
            .sorted(by: { $0.key > $1.key })
            .prefix(64)
            .forEach { userNotificationCenter.add($0.value) }
        try storage.save(allPendingNotifications)
    }

    private func pendingNotificationRequests() async throws -> [Date: UNNotificationRequest] {
        let deliveredNotificationIdentifiers = await userNotificationCenter
            .deliveredNotifications()
            .map(\.request.identifier)

        return try storage
            .get()
            .filter {
                !deliveredNotificationIdentifiers.contains($0.value.identifier) &&
                !($0.value.trigger?.isExpired(for: $0.key) ?? true)
            }
    }
}

public enum DataSource: Sendable {
    case userDefaults(UserDefaults)
    case fileStorage(
        url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notificationRequests")
    )
}

extension UserDefaults: @unchecked Sendable {}
extension UNUserNotificationCenter: @unchecked Sendable {}

extension UNNotificationTrigger {
    func isExpired(for addedDate: Date) -> Bool {
        guard !repeats else {
            return false
        }

        let now = Date()

        return switch self {
        case let trigger as UNTimeIntervalNotificationTrigger:
            addedDate.addingTimeInterval(trigger.timeInterval) < now
        case let calendar as UNCalendarNotificationTrigger:
            if let date = calendar.dateComponents.date {
                date < now
            } else {
                false
            }
        default: false
        }
    }
}
