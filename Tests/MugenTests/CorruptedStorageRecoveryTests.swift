import XCTest
import UserNotifications
@testable import Mugen

/// Minimal synchronized box. `NotificationCenterClient` has synchronous requirements,
/// so an actor cannot back the fake directly.
private final class Locked<Value>: @unchecked Sendable {
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return body(&value)
    }
}

/// Fake OS-side notification center that records calls.
private final class FakeNotificationCenter: NotificationCenterClient, @unchecked Sendable {
    enum Call: Equatable {
        case add(String)
        case removeAll
        case remove([String])
        case pending
        case delivered
    }

    private struct State {
        var requests: [UNNotificationRequest]
        var calls: [Call] = []
        var delivered: [String]
    }

    private let state: Locked<State>

    init(pending: [UNNotificationRequest] = [], delivered: [String] = []) {
        state = Locked(State(requests: pending, delivered: delivered))
    }

    var calls: [Call] { state.withValue { $0.calls } }
    var osIdentifiers: Set<String> { state.withValue { Set($0.requests.map(\.identifier)) } }

    func add(_ request: UNNotificationRequest) async throws {
        state.withValue {
            $0.calls.append(.add(request.identifier))
            $0.requests.removeAll { $0.identifier == request.identifier }
            $0.requests.append(request)
        }
    }

    func removeAllPendingNotificationRequests() {
        state.withValue {
            $0.calls.append(.removeAll)
            $0.requests.removeAll()
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        state.withValue {
            $0.calls.append(.remove(identifiers))
            $0.requests.removeAll { identifiers.contains($0.identifier) }
        }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        state.withValue {
            $0.calls.append(.pending)
            return $0.requests
        }
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        state.withValue {
            $0.calls.append(.delivered)
            return $0.delivered
        }
    }
}

final class CorruptedStorageRecoveryTests: XCTestCase {
    private var directory: URL!
    private var suiteNames: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MugenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames = []
    }

    private static let corruptedContents: [(name: String, data: Data)] = [
        ("empty", Data()),
        ("truncated JSON", Data("{\"a".utf8)),
        ("odd-length array", Data("[\"x\"]".utf8)),
    ]

    // MARK: - Recovery on every public operation

    // Bug caught: configure() wipes the OS schedule before (or instead of) rebuilding storage,
    // or throws DecodingError on corrupted storage.
    func testConfigureOnCorruptedStorageKeepsOSRequests() async throws {
        for (name, data) in Self.corruptedContents {
            let url = makeFileURL()
            try data.write(to: url)
            let os = FakeNotificationCenter(pending: makeRequests(["a", "b", "c"]))
            let center = makeCenter(os, url)

            try await center.configure()

            XCTAssertEqual(os.osIdentifiers, ["a", "b", "c"], name)
            let calls = os.calls
            if let removeIndex = calls.firstIndex(of: .removeAll) {
                let pendingIndex = try XCTUnwrap(calls.firstIndex(of: .pending), name)
                XCTAssertLessThan(pendingIndex, removeIndex, "OS list must be read before OS is cleared (\(name))")
            }
        }
    }

    // Bug caught: rebuilt entries share one Date key, so all but one request are lost.
    func testRebuiltRequestsAreNotLostToKeyCollision() async throws {
        let url = makeFileURL()
        try Data().write(to: url)
        let ids = (0..<20).map { "id\($0)" }
        let os = FakeNotificationCenter(pending: makeRequests(ids))
        let center = makeCenter(os, url)

        let pending = try await center.pendingNotificationRequests()

        XCTAssertEqual(Set(pending.map(\.identifier)), Set(ids))
        XCTAssertEqual(pending.count, ids.count)
    }

    // Bug caught: rebuilt timestamps are not unique / not near "now" (e.g. distantPast or one reused Date()).
    func testRebuiltFileHasDistinctDatesNearRebuildTime() async throws {
        let url = makeFileURL()
        try Data().write(to: url)
        let os = FakeNotificationCenter(pending: makeRequests(["a", "b", "c", "d"]))
        let center = makeCenter(os, url)
        let before = Date()

        _ = try await center.pendingNotificationRequests()

        let stored = try JSONDecoder().decode([Date: Data].self, from: Data(contentsOf: url))
        XCTAssertEqual(stored.count, 4)
        for date in stored.keys {
            XCTAssertLessThan(abs(date.timeIntervalSince(before)), 60)
        }
    }

    // Bug caught: add() throws DecodingError, or the new request is not registered with the OS,
    // or the rebuilt entries are dropped.
    func testAddOnCorruptedStorageRebuildsAndAdds() async throws {
        for (name, data) in Self.corruptedContents {
            let url = makeFileURL()
            try data.write(to: url)
            let os = FakeNotificationCenter(pending: makeRequests(["a", "b"]))
            let center = makeCenter(os, url)

            try await center.add(makeRequest("new"))

            XCTAssertTrue(os.osIdentifiers.contains("new"), name)
            let pending = try await center.pendingNotificationRequests()
            XCTAssertEqual(Set(pending.map(\.identifier)), ["a", "b", "new"], name)
        }
    }

    // Bug caught: removing on corrupted storage throws, or removes the wrong entries.
    func testRemoveOnCorruptedStorageRemovesOnlyTarget() async throws {
        for (name, data) in Self.corruptedContents {
            let url = makeFileURL()
            try data.write(to: url)
            let os = FakeNotificationCenter(pending: makeRequests(["a", "b", "c"]))
            let center = makeCenter(os, url)

            try center.removePendingNotificationRequests(withIdentifiers: ["b"])

            let pending = try await center.pendingNotificationRequests()
            XCTAssertEqual(Set(pending.map(\.identifier)), ["a", "c"], name)
        }
    }

    // Bug caught: removeAll on corrupted storage throws, or leaves rebuilt entries behind.
    func testRemoveAllOnCorruptedStorageEmptiesList() async throws {
        for (name, data) in Self.corruptedContents {
            let url = makeFileURL()
            try data.write(to: url)
            let os = FakeNotificationCenter(pending: makeRequests(["a", "b"]))
            let center = makeCenter(os, url)

            try center.removeAllPendingNotificationRequests()

            let pending = try await center.pendingNotificationRequests()
            XCTAssertTrue(pending.isEmpty, name)
        }
    }

    // Bug caught: pendingNotificationRequests() keeps throwing DecodingError forever.
    func testPendingOnCorruptedStorageReturnsOSRequests() async throws {
        for (name, data) in Self.corruptedContents {
            let url = makeFileURL()
            try data.write(to: url)
            let os = FakeNotificationCenter(pending: makeRequests(["a", "b"]))
            let center = makeCenter(os, url)

            let pending = try await center.pendingNotificationRequests()

            XCTAssertEqual(Set(pending.map(\.identifier)), ["a", "b"], name)
        }
    }

    // MARK: - Persistence of the rebuilt storage

    // Bug caught: rebuilt data is only held in memory / not written back, so the next launch is still corrupted.
    func testRebuiltStorageIsReadableByNewInstance() async throws {
        let url = makeFileURL()
        try Data("{\"a".utf8).write(to: url)
        let first = makeCenter(FakeNotificationCenter(pending: makeRequests(["a", "b"])), url)
        _ = try await first.pendingNotificationRequests()

        let freshOS = FakeNotificationCenter()
        let second = makeCenter(freshOS, url)
        let pending = try await second.pendingNotificationRequests()

        XCTAssertEqual(Set(pending.map(\.identifier)), ["a", "b"])
        XCTAssertFalse(freshOS.calls.contains(.pending), "valid storage must not be rebuilt again")
    }

    // MARK: - Missing file is not corruption

    // Bug caught: a missing file is treated as corrupted and rebuilt from the OS.
    func testMissingFileIsEmptyAndDoesNotTouchOS() async throws {
        let url = makeFileURL()
        let os = FakeNotificationCenter(pending: makeRequests(["a"]))
        let center = makeCenter(os, url)

        let pending = try await center.pendingNotificationRequests()

        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(os.calls.contains(.pending))
    }

    // MARK: - Non-decoding errors still propagate

    // Bug caught: all errors are swallowed instead of only DecodingError.
    func testNonFileURLStillThrowsNotFileURL() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/notificationRequests"))
        let center = MugenNotificationCenter(
            notificationCenter: FakeNotificationCenter(pending: makeRequests(["a"])),
            dataSource: .fileStorage(url: url)
        )

        do {
            _ = try await center.pendingNotificationRequests()
            XCTFail("expected NotificationStorageError.notFileURL")
        } catch let error as NotificationStorageError {
            guard case .notFileURL = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - UserDefaults

    // Bug caught: recovery is implemented only for file storage, not UserDefaults.
    func testUserDefaultsCorruptedDataIsRebuilt() async throws {
        let suite = "MugenTests-\(UUID().uuidString)"
        suiteNames.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(Data("[\"x\"]".utf8), forKey: "notificationRequests")
        let os = FakeNotificationCenter(pending: makeRequests(["a", "b"]))
        let center = MugenNotificationCenter(notificationCenter: os, dataSource: .userDefaults(defaults))

        let pending = try await center.pendingNotificationRequests()

        XCTAssertEqual(Set(pending.map(\.identifier)), ["a", "b"])
        let again = MugenNotificationCenter(notificationCenter: FakeNotificationCenter(), dataSource: .userDefaults(defaults))
        let reread = try await again.pendingNotificationRequests()
        XCTAssertEqual(Set(reread.map(\.identifier)), ["a", "b"])
    }

    // MARK: - Healthy storage is unchanged

    // Bug caught: recovery path regresses add / list for valid storage.
    func testHealthyAddAppearsInList() async throws {
        let os = FakeNotificationCenter()
        let center = makeCenter(os, makeFileURL())

        try await center.add(makeRequest("a"))

        let pending = try await center.pendingNotificationRequests()
        XCTAssertEqual(pending.map(\.identifier), ["a"])
        XCTAssertTrue(os.osIdentifiers.contains("a"))
    }

    // Bug caught: recovery path regresses remove for valid storage.
    func testHealthyRemoveDeletesFromList() async throws {
        let os = FakeNotificationCenter()
        let center = makeCenter(os, makeFileURL())
        try await center.add(makeRequest("a"))
        try await center.add(makeRequest("b"))

        try center.removePendingNotificationRequests(withIdentifiers: ["a"])

        let pending = try await center.pendingNotificationRequests()
        XCTAssertEqual(pending.map(\.identifier), ["b"])
    }

    // Bug caught: configure() on healthy storage no longer reinstalls stored requests into the OS.
    func testHealthyConfigureReinstallsStoredRequests() async throws {
        let url = makeFileURL()
        let first = makeCenter(FakeNotificationCenter(), url)
        try await first.add(makeRequest("a"))
        try await first.add(makeRequest("b"))

        let freshOS = FakeNotificationCenter()
        let second = makeCenter(freshOS, url)
        try await second.configure()

        XCTAssertEqual(freshOS.osIdentifiers, ["a", "b"])
    }

    // MARK: - Helpers

    private func makeFileURL() -> URL {
        directory.appendingPathComponent("notificationRequests-\(UUID().uuidString)")
    }

    private func makeCenter(_ os: FakeNotificationCenter, _ url: URL) -> MugenNotificationCenter {
        MugenNotificationCenter(notificationCenter: os, dataSource: .fileStorage(url: url))
    }

    private func makeRequest(_ identifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = identifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    private func makeRequests(_ identifiers: [String]) -> [UNNotificationRequest] {
        identifiers.map(makeRequest)
    }
}
