import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2103: the store has one connection behind one lock, and a read held that lock while it JSON-decoded every row.
/// A tiny read on the main thread then waited for a background whole-Library read to finish decoding.
final class SQLiteStoreLockContentionTests: XCTestCase {
    private final class Seconds: @unchecked Sendable { var value = 0.0 }

    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    private func makeStore() throws -> (store: SQLiteSessionStore, path: String) {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-lock-contention-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return (try SQLiteSessionStore(path: path), path)
    }

    private func item(_ id: String, text: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: text, externalReference: nil, status: "Ready")
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// The small read has to finish well inside the time the big read takes. Before the fix it waited for the whole
    /// decode, so it took about as long as the big read.
    func testASmallReadDoesNotWaitForABackgroundReadToDecode() throws {
        let (store, _) = try makeStore()
        let article = String(repeating: "word ", count: 400_000)
        for index in 0..<40 { try store.saveItem(item("big-\(index)", text: article)) }
        try store.saveItem(item("small", text: "Hi"))
        _ = try store.listItems()

        let background = Seconds()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            started.signal()
            let begin = DispatchTime.now()
            _ = try? store.listItems()
            background.value = Double(DispatchTime.now().uptimeNanoseconds - begin.uptimeNanoseconds) / 1_000_000_000
            finished.signal()
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.005)
        let begin = DispatchTime.now()
        _ = try store.loadItem(id: "small")
        let small = elapsed(since: begin)
        finished.wait()

        try XCTSkipIf(background.value < 0.08, "the background read was too quick (\(background.value) s) to show contention here")
        XCTAssertLessThan(small, background.value / 2, "a small read took \(small) s while a Library read took \(background.value) s")
    }

    /// Decoding now happens after the lock is released: a row that fails is still set aside exactly once, and the
    /// rows beside it are still returned.
    func testAnUndecodableRowIsQuarantinedAndTheOthersAreStillRead() throws {
        let (store, path) = try makeStore()
        try store.saveItem(item("good", text: "Hello"))
        try StoreRawSQL.execute(
            "INSERT INTO records(kind,id,payload) VALUES('item','broken','not json')", at: path)

        XCTAssertEqual(try store.listItems().map(\.id), ["good"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertEqual(try store.listItems().map(\.id), ["good"], "the broken row is gone from the table, not quarantined twice")
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
    }
}
