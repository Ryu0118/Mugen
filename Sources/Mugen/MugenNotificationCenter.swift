import Foundation
import UserNotifications
import CoreLocation

public struct MugenNotificationCenter: Sendable {
    @_spi(Internal)
    public var userNotificationCenter: UNUserNotificationCenter {
        (notificationCenter as? SystemNotificationCenter)?.base ?? .current()
    }

    let notificationCenter: any NotificationCenterClient
    let storage: NotificationStorage

    public init(
        userNotificationCenter: UNUserNotificationCenter,
        dataSource: DataSource
    ) {
        self.init(
            notificationCenter: SystemNotificationCenter(base: userNotificationCenter),
            dataSource: dataSource
        )
    }

    init(
        notificationCenter: any NotificationCenterClient,
        dataSource: DataSource
    ) {
        self.notificationCenter = notificationCenter
        self.storage = NotificationStorage(dataSource: dataSource)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await notificationCenter.add(request)
        _ = try await readStorage()
        try storage.append(request)
    }

    public func removeAllPendingNotificationRequests() throws {
        notificationCenter.removeAllPendingNotificationRequests()
        try storage.removeAll()
    }

    public func removePendingNotificationRequests(
        withIdentifiers identifiers: [String]
    ) throws {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        do {
            try storage.remove(withIdentifiers: identifiers)
        } catch is DecodingError {
            // The storage can only be rebuilt asynchronously. It is left as is here,
            // and the next asynchronous read rebuilds it from the system's pending requests,
            // which no longer contain the removed identifiers.
        }
    }

    @_disfavoredOverload
    public func pendingNotificationRequests() async throws -> [UNNotificationRequest] {
        try await pendingNotificationRequests()
            .sorted(by: { $0.key < $1.key })
            .map(\.value)
    }

    public func configure() async throws {
        // Reading first also rebuilds corrupted storage, so the system's pending requests
        // are never removed while the storage has nothing to reinstall.
        let allPendingNotifications = try await pendingNotificationRequests()
        notificationCenter.removeAllPendingNotificationRequests()
        for request in allPendingNotifications.sorted(by: { $0.key > $1.key }).prefix(64) {
            try? await notificationCenter.add(request.value)
        }
        try storage.save(allPendingNotifications)
    }

    private func pendingNotificationRequests() async throws -> [Date: UNNotificationRequest] {
        let deliveredNotificationIdentifiers = await notificationCenter.deliveredNotificationIdentifiers()

        return try await readStorage()
            .filter {
                !deliveredNotificationIdentifiers.contains($0.value.identifier) &&
                !($0.value.trigger?.isExpired(for: $0.key) ?? true)
            }
    }

    /// Reads the storage. When it cannot be decoded, rebuilds it from the system's pending requests.
    ///
    /// A corrupted storage never recovers by itself, and every operation would keep failing.
    /// The system's pending requests are the best remaining source of truth.
    private func readStorage() async throws -> [Date: UNNotificationRequest] {
        do {
            return try storage.get()
        } catch is DecodingError {
            let requests = await notificationCenter.pendingNotificationRequests()
            let now = Date()
            // Each request needs its own key, or requests sharing a date would overwrite each other.
            let rebuilt = Dictionary(
                uniqueKeysWithValues: requests.enumerated().map { index, request in
                    (now.addingTimeInterval(Double(index) * 0.001), request)
                }
            )
            try storage.save(rebuilt)
            return rebuilt
        }
    }
}

public enum DataSource {
    case userDefaults(UserDefaults)
    case fileStorage(
        url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notificationRequests")
    )
}


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
