import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #4227: the listener's own spoken Margin recordings go through the purge journal, so a quit part way through a
/// permanent delete no longer leaves the voice files on the phone. Real temporary files and a real SQLite store; the
/// only fakes are the one removal call (to fail it) and the "surviving paths" read (to fail it).
final class PermanentDeleteRecordingsTests: XCTestCase {
    private var support: URL!
    private let manager = FileManager.default
    private var recordings: URL { support.appending(path: "SpokenMargins", directoryHint: .isDirectory) }
    private var journal: URL { recordings.appending(path: "PurgeJournal", directoryHint: .isDirectory) }
    private var voices: URL { recordings.appending(path: "interjections", directoryHint: .isDirectory) }

    private let gone = "item-6f1c2d3e-0000-4000-8000-000000000001"
    private let kept = "item-6f1c2d3e-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        support = manager.temporaryDirectory.appending(path: "recordings-purge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: voices, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? manager.removeItem(at: support) }

    private struct Failure: Error {}

    /// Thread-safe list of the files `beforeRemoving` saw, in order.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        private var present: [Bool] = []
        func add(_ url: URL) {
            let there = FileManager.default.fileExists(atPath: url.path)
            lock.withLock { names.append(url.lastPathComponent); present.append(there) }
        }
        var all: [String] { lock.withLock { names } }
        /// Whether each file still existed when the hook saw it.
        var allWereThere: Bool { lock.withLock { present.allSatisfy { $0 } } }
    }

    /// Holds the work of a delete until the caller has got `deleting` back. A hook that runs while the caller is still
    /// inside `deleting` (the work done inline, or the caller waiting on it) can never be released, so it times out and
    /// says so. Nothing here compares threads: on Swift's cooperative pool a background task may well land on the thread
    /// the caller just gave up, which proves nothing about whether the caller waited.
    private final class CallerHold: @unchecked Sendable {
        private let condition = NSCondition()
        private var released = false
        private var timeouts = 0
        private var arrivals = 0
        /// How long a hook waits for the caller to release it. Long enough to never fire on a loaded runner when the
        /// work is off the caller; the wait only runs to its end when the work is wrongly on the caller.
        private let patience: TimeInterval = 5

        /// Called by a hook, wherever it runs. Returns once the caller has released it, or after `patience`.
        func waitForCaller() {
            condition.lock(); defer { condition.unlock() }
            arrivals += 1
            let deadline = Date(timeIntervalSinceNow: patience)
            while !released {
                if !condition.wait(until: deadline), !released { timeouts += 1; return }
            }
        }

        /// Called by the caller once `deleting` has returned.
        func release() {
            condition.lock(); defer { condition.unlock() }
            released = true
            condition.broadcast()
        }

        /// How many times a hook ran, and how many of those ran to the end of their wait with no release.
        var hookRuns: Int { condition.lock(); defer { condition.unlock() }; return arrivals }
        var hooksNeverReleased: Int { condition.lock(); defer { condition.unlock() }; return timeouts }
    }

    private func store() throws -> SQLiteSessionStore {
        let store = try SQLiteSessionStore(path: support.appending(path: "store.sqlite").path)
        for id in [gone, kept] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        return store
    }

    private func margin(_ id: String, item: String, audioPath: String) -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: "session-\(item)", targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: audioPath, audioStatus: "recorded",
            transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A Margin", status: "active"
        )
    }

    /// Writes a recording and returns the path a Margin row stores for it.
    private func record(_ name: String) throws -> String {
        try Data("voice \(name)".utf8).write(to: voices.appending(path: name))
        return "SpokenMargins/interjections/\(name)"
    }

    private func exists(_ name: String) -> Bool { manager.fileExists(atPath: voices.appending(path: name).path) }

    private func journalCount() -> Int {
        ((try? manager.contentsOfDirectory(atPath: journal.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    private func resolve(_ path: String) -> URL? {
        let url = support.appending(path: path)
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    private func purge(
        store: SQLiteSessionStore, seen: Seen = Seen(), surviving: (@Sendable () throws -> [String])? = nil,
        removeFile: (@Sendable (URL) throws -> Void)? = nil
    ) -> PermanentDeletePurge {
        let support = self.support!
        let config = PermanentDeletePurge.MarginRecordings(
            directory: recordings,
            resolve: { path in
                let url = support.appending(path: path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            survivingAudioPaths: surviving ?? { try store.allMarginAudioPaths() },
            beforeRemoving: { seen.add($0) })
        if let removeFile {
            return PermanentDeletePurge(journalDirectory: journal, roots: [], marginRecordings: config, removeFile: removeFile)
        }
        return PermanentDeletePurge(journalDirectory: journal, roots: [], marginRecordings: config)
    }

    /// The paths a delete reads before it runs: the item's own Margins, live and quarantined.
    private func pathsOf(_ item: String, in store: SQLiteSessionStore) throws -> [String] {
        try store.loadInterjections(itemId: item).compactMap(\.audioPath) + (try store.quarantinedMarginAudioPaths(itemId: item))
    }

    // MARK: The order of a delete

    func testADeleteRemovesTheItemsRecordingsAndOnlyThose() async throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        try store.saveInterjection(margin("g2", item: gone, audioPath: try record("g2.m4a")))
        try store.saveInterjection(margin("k1", item: kept, audioPath: try record("k1.m4a")))
        let seen = Seen()
        let paths = try pathsOf(gone, in: store)

        let outcome = try await purge(store: store, seen: seen)
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertEqual(outcome.recordingsDone, 2)
        XCTAssertEqual(outcome.recordingsKept, 0)
        XCTAssertFalse(exists("g1.m4a")); XCTAssertFalse(exists("g2.m4a"))
        XCTAssertTrue(exists("k1.m4a"), "a Margin that stays keeps its recording")
        XCTAssertEqual(seen.all.sorted(), ["g1.m4a", "g2.m4a"], "the leveled copies are looked for before each file goes")
        XCTAssertTrue(seen.allWereThere, "the hook runs while the file can still be read, since copies are found by content")
        XCTAssertEqual(journalCount(), 0, "the record goes when every recording is gone")
    }

    /// Starts a delete whose survivors read and file removal each wait for the caller to get `deleting` back, then
    /// releases them. The caller is not suspended between the two, so only work that waits on the caller (or runs inline
    /// on it) can be left waiting.
    private func deleteHeldUntilCallerReturns(
        _ paths: [String], in store: SQLiteSessionStore
    ) throws -> (task: Task<PermanentDeletePurge.Outcome, Never>, hold: CallerHold) {
        let hold = CallerHold()
        let task = try purge(
            store: store,
            surviving: { hold.waitForCaller(); return try store.allMarginAudioPaths() },
            removeFile: { url in hold.waitForCaller(); try FileManager.default.removeItem(at: url) }
        ).deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }
        hold.release()
        return (task, hold)
    }

    func testTheSurvivorsReadAndTheRemovalNeverWaitOnTheCaller() async throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let (task, hold) = try deleteHeldUntilCallerReturns(try pathsOf(gone, in: store), in: store)
        let outcome = await task.value

        XCTAssertEqual(outcome.recordingsDone, 1)
        XCTAssertFalse(exists("g1.m4a"))
        XCTAssertGreaterThanOrEqual(hold.hookRuns, 2, "both the survivors read and the removal ran, so the check is not vacuous")
        XCTAssertEqual(hold.hooksNeverReleased, 0, "the read of every remaining Margin and the file work never wait on the caller")
    }

    func testTheRecordNamesTheRecordingsBeforeTheRowsGo() throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)
        var recordsDuringDelete = -1
        _ = try purge(store: store).deleting(itemIds: [gone], targets: [], recordingPaths: paths) {
            recordsDuringDelete = journalCount()
            try store.deleteItem(id: gone)
        }
        XCTAssertEqual(recordsDuringDelete, 1)
    }

    func testARecordingAMarginThatStaysStillNamesIsKeptEvenWhenTwoMarginsShareIt() async throws {
        let store = try store()
        let shared = try record("shared.m4a")
        try store.saveInterjection(margin("g1", item: gone, audioPath: shared))
        try store.saveInterjection(margin("k1", item: kept, audioPath: shared))
        let paths = try pathsOf(gone, in: store)

        let outcome = try await purge(store: store)
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertTrue(exists("shared.m4a"))
        XCTAssertEqual(outcome.recordingsDone, 1, "finished: nothing to remove for it")
        XCTAssertEqual(journalCount(), 0)
    }

    func testAFileOutsideTheRecordingsFolderIsNeverRemoved() async throws {
        let store = try store()
        let outside = support.appending(path: "precious.m4a")
        try Data("not a recording".utf8).write(to: outside)
        try store.saveInterjection(margin("g1", item: gone, audioPath: "precious.m4a"))
        let paths = try pathsOf(gone, in: store)

        _ = try await purge(store: store)
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertTrue(manager.fileExists(atPath: outside.path))
        XCTAssertEqual(journalCount(), 0)
    }

    // MARK: A delete that does not finish

    func testAKilledDeleteIsFinishedAtTheNextLaunch() throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        try store.saveInterjection(margin("k1", item: kept, audioPath: try record("k1.m4a")))
        let paths = try pathsOf(gone, in: store)
        // The rows go, and the app is killed before a file does: the record is all that is left.
        _ = try purge(store: store).begin(itemIds: [gone], targets: [], recordingPaths: paths)
        try store.deleteItem(id: gone)
        XCTAssertTrue(exists("g1.m4a"))

        let launch = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)

        XCTAssertEqual(launch.recordingsDone, 1)
        XCTAssertFalse(exists("g1.m4a"), "the owner's voice is off the phone after the next launch")
        XCTAssertTrue(exists("k1.m4a"))
        XCTAssertEqual(journalCount(), 0)
    }

    func testAKillBeforeTheRowsWentRemovesNothing() throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)
        _ = try purge(store: store).begin(itemIds: [gone], targets: [], recordingPaths: paths)

        let launch = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)

        XCTAssertEqual(launch.abandonedRecords, 1)
        XCTAssertTrue(exists("g1.m4a"), "the delete never happened, so the Margin still has its voice")
        XCTAssertEqual(journalCount(), 0)
    }

    func testAFailedRemovalStaysInTheRecordAndIsRetried() async throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        try store.saveInterjection(margin("g2", item: gone, audioPath: try record("g2.m4a")))
        let paths = try pathsOf(gone, in: store)

        let first = try await purge(store: store, removeFile: { url in
            if url.lastPathComponent == "g1.m4a" { throw Failure() }
            try FileManager.default.removeItem(at: url)
        }).deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertEqual(first.recordingsDone, 1)
        XCTAssertEqual(first.recordingsKept, 1)
        XCTAssertTrue(exists("g1.m4a")); XCTAssertFalse(exists("g2.m4a"))
        XCTAssertEqual(journalCount(), 1, "the one that stuck stays in the record")

        let launch = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)

        XCTAssertEqual(launch.recordingsDone, 1, "only the one left is tried again")
        XCTAssertFalse(exists("g1.m4a"))
        XCTAssertEqual(journalCount(), 0)
    }

    func testMarginsThatCannotBeReadRemoveNothingAndKeepTheRecord() async throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)

        let outcome = try await purge(store: store, surviving: { throw Failure() })
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertEqual(outcome.recordingsKept, 1)
        XCTAssertTrue(exists("g1.m4a"), "a recording goes only once no remaining Margin is known to use it")
        XCTAssertEqual(journalCount(), 1)

        let launch = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)
        XCTAssertEqual(launch.recordingsDone, 1)
        XCTAssertFalse(exists("g1.m4a"))
    }

    func testARowThatCannotBeReadAtLaunchKeepsTheRecordingsAndTheRecord() throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)
        _ = try purge(store: store).begin(itemIds: [gone], targets: [], recordingPaths: paths)
        try store.deleteItem(id: gone)

        let busy = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), rowState: { _ in .unknown })

        XCTAssertEqual(busy.deferredRecords, 1)
        XCTAssertEqual(busy.recordingsKept, 1)
        XCTAssertTrue(exists("g1.m4a"), "a busy database at launch removes nothing")
        XCTAssertEqual(journalCount(), 1)

        let later = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)
        XCTAssertEqual(later.recordingsDone, 1)
        XCTAssertFalse(exists("g1.m4a"))
    }

    func testABuildThatCannotFindRecordingsKeepsThePathsForOneThatCan() async throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)

        let bare = PermanentDeletePurge(journalDirectory: journal, roots: [])
        let outcome = try await bare.deleting(itemIds: [gone], targets: [], recordingPaths: paths) {
            try store.deleteItem(id: gone)
        }.value

        XCTAssertEqual(outcome.recordingsKept, 1)
        XCTAssertTrue(exists("g1.m4a"))
        XCTAssertEqual(journalCount(), 1)
    }

    func testAFailedDeleteTouchesNoRecording() throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)

        XCTAssertThrowsError(
            try purge(store: store).deleting(itemIds: [gone], targets: [], recordingPaths: paths) { throw Failure() })
        XCTAssertTrue(exists("g1.m4a"))
        let launch = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)
        XCTAssertEqual(launch.abandonedRecords, 1, "the rows are still there, so the delete is dropped")
        XCTAssertTrue(exists("g1.m4a"))
        XCTAssertEqual(journalCount(), 0)
    }

    func testAJournalThatCannotBeWrittenStillRemovesTheRecordings() async throws {
        let store = try store()
        try store.saveInterjection(margin("g1", item: gone, audioPath: try record("g1.m4a")))
        let paths = try pathsOf(gone, in: store)
        try Data("a file where the journal folder should be".utf8).write(to: journal)

        let outcome = try await purge(store: store)
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertEqual(outcome.recordingsDone, 1)
        XCTAssertFalse(exists("g1.m4a"), "recordings were removed with no record before the journal, and still are")
    }

    // MARK: Compatibility

    func testARecordWrittenWithoutRecordingPathsStillReads() throws {
        let store = try store()
        try manager.createDirectory(at: journal, withIntermediateDirectories: true)
        let old = """
            {"id":"old-record","itemIds":["\(gone)"],"targets":[],"createdAt":1700000000000}
            """
        try Data(old.utf8).write(to: journal.appending(path: "old-record.json"))

        let launch = purge(store: store).resumePending(recordsBefore: Date().addingTimeInterval(60), store: store)

        XCTAssertEqual(launch.unreadableRecords, 0)
        XCTAssertEqual(journalCount(), 0, "a record with nothing left to remove is finished")
    }

    func testTheSameRecordingNamedTwiceIsRemovedOnceAndCountedOnce() async throws {
        let store = try store()
        let path = try record("g1.m4a")
        try store.saveInterjection(margin("g1", item: gone, audioPath: path))
        try store.saveInterjection(margin("g2", item: gone, audioPath: path))
        let paths = try pathsOf(gone, in: store)
        XCTAssertEqual(paths.count, 2)

        let outcome = try await purge(store: store)
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertEqual(outcome.recordingsDone, 1)
        XCTAssertFalse(exists("g1.m4a"))
    }

    func testManyRecordingsOfABulkDeleteAreAllRemoved() async throws {
        let store = try store()
        for index in 0..<300 {
            try store.saveInterjection(margin("g\(index)", item: gone, audioPath: try record("g\(index).m4a")))
        }
        let paths = try pathsOf(gone, in: store)

        let outcome = try await purge(store: store)
            .deleting(itemIds: [gone], targets: [], recordingPaths: paths) { try store.deleteItem(id: gone) }.value

        XCTAssertEqual(outcome.recordingsDone, 300)
        XCTAssertEqual((try manager.contentsOfDirectory(atPath: voices.path)).count, 0)
    }
}
