import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2103: the store had one connection behind one lock, and a read held that lock while it JSON-decoded every row.
/// A tiny read on the main thread then waited for a background whole-Library read to finish decoding. Reads now run
/// on connections of their own, so they wait for neither the lock nor each other.
final class SQLiteStoreLockContentionTests: XCTestCase {
    private final class Seconds: @unchecked Sendable { var value = 0.0 }
    private final class Flag: @unchecked Sendable { var value = false }

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

    private func item(_ id: String, text: String) -> Item { Self.item(id, text: text) }

    private static func item(_ id: String, text: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: text, externalReference: nil, status: "Ready")
    }

    private func elapsed(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// The small read has to finish well inside the time the big read takes. Before the fix it waited for the whole
    /// decode, so it took about as long as the big read.
    func testASmallReadDoesNotWaitForABackgroundReadToDecode() throws {
        let (store, _) = try makeStore()
        // Escaped quotes, newlines and non-ASCII make the JSON slower to decode than to copy, as real articles do.
        let article = String(repeating: "w\u{00F6}rd \"quoted\"\n", count: 150_000)
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

    /// A background read that is still open, with its rows not yet all handed over, must not hold up a small read or a
    /// write on another thread. The held read waits on a semaphore, not a clock, so this fails the same way on a fast
    /// machine as on a slow one: before the fix the other thread waits for the lock the held read has, and times out.
    func testASmallReadAndAWriteProceedWhileABackgroundReadIsStillOpen() throws {
        let (store, _) = try makeStore()
        try store.saveItem(item("small", text: "Hi"))
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let backgroundDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? store.readTexts("SELECT 'row';", [], name: "held_read") { _ in
                holding.signal()
                _ = release.wait(timeout: .now() + 30)
            }
            backgroundDone.signal()
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 10), .success, "the background read never started")

        let finished = DispatchSemaphore(value: 0)
        let sawWrite = Flag()
        Thread.detachNewThread {
            _ = try? store.loadItem(id: "small")
            try? store.saveItem(Self.item("written-meanwhile", text: "Yes"))
            sawWrite.value = (try? store.loadItem(id: "written-meanwhile")) != nil
            finished.signal()
        }
        let outcome = finished.wait(timeout: .now() + 10)
        release.signal()

        XCTAssertEqual(outcome, .success, "a small read and a save waited for a background read that was still open")
        XCTAssertTrue(sawWrite.value, "a read right after a save must see it")
        XCTAssertEqual(backgroundDone.wait(timeout: .now() + 10), .success)
    }

    /// A reader on another thread sees what is committed, never a half-done transaction. The thread that owns the
    /// transaction sees its own writes, as it did on the single connection.
    func testAnotherThreadReadsOnlyCommittedRowsWhileTheOwnerSeesItsOwn() throws {
        let (store, _) = try makeStore()
        try store.saveItem(item("committed", text: "Before"))
        let inside = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let ownerSawPending = Flag()
        Thread.detachNewThread {
            try? store.withSessionTransaction {
                try store.saveItem(Self.item("pending", text: "Not yet"))
                ownerSawPending.value = (try? store.loadItem(id: "pending")) != nil
                inside.signal()
                _ = finish.wait(timeout: .now() + 10)
            }
            done.signal()
        }
        XCTAssertEqual(inside.wait(timeout: .now() + 10), .success)

        let otherSawPending = (try? store.loadItem(id: "pending")) != nil
        let listedDuringTransaction = try store.listItems().map(\.id)
        finish.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)

        XCTAssertTrue(ownerSawPending.value, "the owner of the transaction must read its own uncommitted write")
        XCTAssertFalse(otherSawPending, "another thread read a row from a transaction that had not committed")
        XCTAssertEqual(listedDuringTransaction, ["committed"])
        XCTAssertEqual(Set(try store.listItems().map(\.id)), ["committed", "pending"], "after the commit both are there")
    }

    /// A reader that looked at an item mid-transaction got the rows from before it, under the revision the save had
    /// already moved. The commit moves it again, so what the reader cached under the first number is read afresh.
    func testTheItemRevisionMovesAgainWhenATransactionThatSavedTheItemCommits() throws {
        let (store, _) = try makeStore()
        try store.saveItem(item("item", text: "Old"))
        let inside = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? store.withSessionTransaction {
                try store.saveItem(Self.item("item", text: "New"))
                inside.signal()
                _ = finish.wait(timeout: .now() + 10)
            }
            done.signal()
        }
        XCTAssertEqual(inside.wait(timeout: .now() + 10), .success)
        let revisionSeenMidTransaction = store.itemRevision(id: "item")
        XCTAssertEqual(try store.loadItem(id: "item").text, "Old", "another thread reads what is committed")
        finish.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)

        XCTAssertNotEqual(store.itemRevision(id: "item"), revisionSeenMidTransaction)
        XCTAssertEqual(try store.loadItem(id: "item").text, "New")
    }

    /// A database that can't be read beside the writer (in memory: a second connection would open a different, empty
    /// one) keeps reading on the one connection.
    func testAnInMemoryStoreStillReadsWhatItSaved() throws {
        let store = try SQLiteSessionStore(path: ":memory:")
        try store.saveItem(item("memory", text: "Hi"))
        XCTAssertEqual(try store.loadItem(id: "memory").id, "memory")
        XCTAssertEqual(try store.listItems().map(\.id), ["memory"])
    }
}
