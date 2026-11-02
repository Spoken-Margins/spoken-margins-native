import Foundation
import SessionKit
import XCTest
@testable import SessionKitPersistence

/// #2818, third time: app tests build a model that stays alive after the test, so its store stays open and holds a
/// database, `-wal` and `-shm` descriptor (plus idle readers). The app test bundle releases them at the end of each test.
final class ReleasingStoreConnectionsTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func openDescriptorCount() throws -> Int {
        let directory = FileManager.default.fileExists(atPath: "/dev/fd") ? "/dev/fd" : "/proc/self/fd"
        return try FileManager.default.contentsOfDirectory(atPath: directory).count
    }

    private func item(_ id: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: "Source text.", externalReference: nil, status: "ready")
    }

    /// Opens a store, writes, and reads from several threads so the reader pool opens connections too.
    private func makeBusyStore(_ name: String) throws -> SQLiteSessionStore {
        let store = try SQLiteSessionStore(path: directory.appending(path: "\(name).sqlite").path)
        try store.saveItem(item("a"))
        DispatchQueue.concurrentPerform(iterations: 6) { _ in _ = try? store.loadItem(id: "a") }
        return store
    }

    func testReleasingGivesBackTheDescriptorsOfAStoreThatIsStillReferenced() throws {
        let baseline = try openDescriptorCount()
        let stores = try (0..<5).map { try makeBusyStore("store-\($0)") }
        XCTAssertGreaterThan(try openDescriptorCount(), baseline + 5, "each live store holds files open")

        stores.forEach { $0.releaseConnections() }
        XCTAssertEqual(try openDescriptorCount(), baseline, "released stores hold nothing, though they are still referenced")
        withExtendedLifetime(stores) {}
    }

    func testAReleasedStoreFailsOrReadsNothingInsteadOfCrashingAndNeverTouchesTheFileAgain() throws {
        let path = directory.appending(path: "kept.sqlite").path
        let store = try makeBusyStore("kept")
        store.releaseConnections()
        store.releaseConnections() // twice is fine
        XCTAssertThrowsError(try store.saveItem(item("late")))
        XCTAssertThrowsError(try store.loadItem(id: "a"), "the placeholder database is empty")

        let reopened = try SQLiteSessionStore(path: directory.appending(path: "kept.sqlite").path)
        XCTAssertEqual(try reopened.loadItem(id: "a").id, "a", "what was saved before the release is on disk")
        XCTAssertThrowsError(try reopened.loadItem(id: "late"), "nothing late was added")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testTrackedStoresAreReleasedTogetherAndDeallocatedOnesAreSkipped() throws {
        let baseline = try openDescriptorCount()
        let outsideTheWindow = try makeBusyStore("outside") // opened before tracking starts: never released
        SQLiteSessionStore.trackOpenStores()
        defer { SQLiteSessionStore.releaseTrackedStores() }
        var gone: SQLiteSessionStore? = try makeBusyStore("gone")
        let kept = try (0..<3).map { try makeBusyStore("tracked-\($0)") }
        gone = nil // deinit closes this one itself

        XCTAssertEqual(SQLiteSessionStore.releaseTrackedStores(), 3)
        XCTAssertNoThrow(try outsideTheWindow.saveItem(item("still-open")), "a store opened outside the window is untouched")
        XCTAssertEqual(SQLiteSessionStore.releaseTrackedStores(), 0, "the window ended, so nothing is left to release")
        let afterClosing = try makeBusyStore("after") // the window is over, so this one is not tracked either
        XCTAssertEqual(SQLiteSessionStore.releaseTrackedStores(), 0)
        withExtendedLifetime([kept, [outsideTheWindow, afterClosing]]) {}
        _ = gone
    }
}
