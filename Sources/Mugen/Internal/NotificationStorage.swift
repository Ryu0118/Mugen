import Foundation
import UserNotifications

struct NotificationStorage: @unchecked Sendable {
    private enum Const {
        static let notificationRequests = "notificationRequests"
    }

    let dataSource: DataSource

    private let lock = NSRecursiveLock()

    func append(_ request: UNNotificationRequest) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var pendingRequests = try get()
        pendingRequests.updateValue(request, forKey: now)
        try save(pendingRequests)
    }

    func remove(withIdentifiers identifiers: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        let pendingRequests = try get()
        let specifiedRequests = pendingRequests.filter { !identifiers.contains($0.value.identifier) }
        try save(specifiedRequests)
    }

    func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        switch dataSource {
        case .userDefaults(let userDefaults):
            userDefaults.set(nil, forKey: Const.notificationRequests)
        case .fileStorage(let url):
            try FileManager.default.removeItem(at: url)
        }
    }

    func save(_ requests: [Date: UNNotificationRequest]) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try requests.reduce(into: [Date: Data]()) { partialResult, request in
            partialResult.updateValue(
                try NSKeyedArchiver.archivedData(
                    withRootObject: request.value,
                    requiringSecureCoding: true
                ), 
                forKey: request.key
            )
        }
        let combinedData = try JSONEncoder().encode(data)
        switch dataSource {
        case .userDefaults(let userDefaults):
            userDefaults.set(combinedData, forKey: Const.notificationRequests)
        case .fileStorage(let url):
            try FileManager.default
              .createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try combinedData.write(to: url)
        }
    }

    func get() throws -> [Date: UNNotificationRequest] {
        lock.lock()
        defer { lock.unlock() }
        switch dataSource {
        case .userDefaults(let userDefaults):
            guard let combinedData = userDefaults.data(forKey: Const.notificationRequests) else {
                return [:]
            }
            return try decode(combinedData: combinedData)

        case .fileStorage(let url):
            guard url.isFileURL else {
                throw NotificationStorageError.notFileURL
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return [:]
            }

            let combinedData = try Data(contentsOf: url)
            return try decode(combinedData: combinedData)
        }
    }

    private func decode(combinedData: Data) throws -> [Date: UNNotificationRequest] {
        lock.lock()
        defer { lock.unlock() }
        let dataDictionary = try JSONDecoder().decode(
            [Date: Data].self,
            from: combinedData
        )

        return try dataDictionary.reduce(into: [Date: UNNotificationRequest]()) { partialResult, request in
            if let unarchivedObject =  try NSKeyedUnarchiver.unarchivedObject(
                ofClass: UNNotificationRequest.self,
                from: request.value
            ) {
                partialResult.updateValue(
                    unarchivedObject,
                    forKey: request.key
                )
            }
        }
    }
}

public enum NotificationStorageError: Error, Sendable {
    case notFileURL
}

struct MugenNotificationRequest: Codable {
    let date: Date
    let requestData: [Data]
}
