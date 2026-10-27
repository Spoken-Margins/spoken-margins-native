import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1970: the text of a written Margin survives the app being closed. These use real files and a real SQLite
/// library; the "relaunch" is a second engine over the same library and the same journal folder.
final class WrittenMarginDraftJournalTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts"],
            "interjection": ["record_audio", "capture_text_anchor"]
        ]
    )

    private var directory: URL!
    private var journal: WrittenMarginDraftJournal!
    private var store: SQLiteSessionStore!

    private func article(_ id: String) -> Item {
        Item(id: id, title: "Article \(id)", mediaType: "text", text: "First sentence. Second sentence carries the thought on. Third sentence.", externalReference: nil, status: "ready")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "written-margin-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = WrittenMarginDraftJournal(directory: WrittenMarginDraftJournal.standardDirectory(applicationSupport: directory))
        store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        try store.saveItem(article("item-a"))
        try store.saveItem(article("item-b"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func newEngine() -> SessionEngine {
        SessionEngine(profile: profile, repository: store)
    }

    private func capture(of engine: SessionEngine, itemId: String) throws -> WrittenInterjectionCapture {
        _ = try engine.startSession(itemId: itemId)
        return try engine.beginWrittenInterjection()
    }

    func testADraftWrittenIsReadBack() throws {
        let capture = try capture(of: newEngine(), itemId: "item-a")
        let record = WrittenMarginDraftRecord(capture: capture, text: "Half a thought", updatedAt: Date(timeIntervalSince1970: 1_000))
        try journal.write(record)

        let loaded = try journal.load()
        XCTAssertEqual(loaded.drafts, [record])
        XCTAssertEqual(loaded.drafts.first?.capture.id, capture.id)
        XCTAssertEqual(loaded.drafts.first?.capture.anchor, capture.anchor)
    }

    func testAnEmptyDraftIsNotKeptAndClearsAnEarlierOne() throws {
        let capture = try capture(of: newEngine(), itemId: "item-a")
        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "   \n", updatedAt: Date()))
        XCTAssertTrue(try journal.load().drafts.isEmpty)

        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "Something", updatedAt: Date()))
        XCTAssertEqual(try journal.load().drafts.count, 1)
        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "", updatedAt: Date()))
        XCTAssertTrue(try journal.load().drafts.isEmpty, "Clearing the text clears the kept draft")
    }

    func testACorruptFileIsIgnoredNotACrash() throws {
        let capture = try capture(of: newEngine(), itemId: "item-a")
        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "Kept", updatedAt: Date()))
        try Data("{ not json".utf8).write(to: journal.directory.appending(path: "broken.json"))

        let loaded = try journal.load()
        XCTAssertEqual(loaded.drafts.map(\.text), ["Kept"])
        XCTAssertEqual(loaded.unreadableFileNames, ["broken.json"])
    }

    func testSavingOrDiscardingRemovesTheDraft() throws {
        let capture = try capture(of: newEngine(), itemId: "item-a")
        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "Words", updatedAt: Date()))
        try journal.remove(id: capture.id)
        XCTAssertTrue(try journal.load().drafts.isEmpty)
        XCTAssertNoThrow(try journal.remove(id: capture.id), "Removing what is not there is not an error")
    }

    func testTwoItemsKeepTwoSeparateDrafts() throws {
        let first = try capture(of: newEngine(), itemId: "item-a")
        let second = try capture(of: newEngine(), itemId: "item-b")
        try journal.write(WrittenMarginDraftRecord(capture: first, text: "About A", updatedAt: Date(timeIntervalSince1970: 1)))
        try journal.write(WrittenMarginDraftRecord(capture: second, text: "About B", updatedAt: Date(timeIntervalSince1970: 2)))

        XCTAssertEqual(try journal.load().drafts.map(\.text), ["About B", "About A"])
        try journal.remove(id: first.id)
        XCTAssertEqual(try journal.load().drafts.map(\.text), ["About B"])
    }

    /// The case the audit found: typed text, app closed, next launch. Without the journal the second engine has no
    /// capture to save into and the text is gone.
    func testARelaunchGetsTheTextBackAndSavesItAtTheSamePlace() throws {
        let first = newEngine()
        let capture = try capture(of: first, itemId: "item-a")
        let sessionId = try XCTUnwrap(first.currentSession?.id)
        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "The thought I was typing", updatedAt: Date()))

        // The app is closed here: the first engine and its in-memory capture are gone.
        let relaunched = newEngine()
        _ = try relaunched.inspectSession(sessionId: sessionId)
        XCTAssertThrowsError(try relaunched.saveWrittenInterjection(captureId: capture.id, text: "x"), "nothing is pending yet")

        let record = try XCTUnwrap(journal.load().drafts.first { $0.sessionId == sessionId })
        let restored = try relaunched.restoreWrittenInterjection(record.capture)
        XCTAssertEqual(relaunched.snapshot.status, .paused)
        XCTAssertFalse(restored.wasPlaying)
        _ = try relaunched.saveWrittenInterjection(captureId: restored.id, text: record.text)

        let saved = try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first)
        XCTAssertEqual(saved.displayText, "The thought I was typing")
        XCTAssertEqual(saved.anchor, capture.anchor, "the Margin lands where it was started, not where the listener was after relaunch")
        XCTAssertEqual(saved.captureKind, .written)
    }

    /// Audit finding 1: a source played to the end is stored as finished, so no "resume" opens it. Its draft must
    /// still come back, by opening that session first.
    func testADraftOnAFinishedSourceComesBackAfterARelaunch() throws {
        let first = newEngine()
        let capture = try capture(of: first, itemId: "item-a")
        let sessionId = try XCTUnwrap(first.currentSession?.id)
        var session = try XCTUnwrap(try store.loadSession(id: sessionId))
        session.status = "finished"
        session.completionPercent = 100
        try store.saveSession(session)
        try journal.write(WrittenMarginDraftRecord(capture: capture, text: "A closing thought", updatedAt: Date()))

        let relaunched = newEngine()
        let record = try XCTUnwrap(
            WrittenMarginDraftJournal.restoreOrder(try journal.load().drafts, restoredSessionId: nil).first
        )
        _ = try relaunched.inspectSession(sessionId: record.sessionId)
        let restored = try relaunched.restoreWrittenInterjection(record.capture)
        _ = try relaunched.saveWrittenInterjection(captureId: restored.id, text: record.text)
        XCTAssertEqual(try store.loadInterjections(sessionId: sessionId).first?.displayText, "A closing thought")
    }

    /// Audit finding 2: nothing is dropped for age, and the restored session's draft is not displaced by a newer one.
    func testAnOldDraftIsKeptAndTheRestoredSessionsDraftComesFirst() throws {
        let a = try capture(of: newEngine(), itemId: "item-a")
        let b = try capture(of: newEngine(), itemId: "item-b")
        let old = WrittenMarginDraftRecord(capture: a, text: "Five weeks old", updatedAt: Date(timeIntervalSinceNow: -35 * 24 * 3600))
        let new = WrittenMarginDraftRecord(capture: b, text: "Yesterday", updatedAt: Date(timeIntervalSinceNow: -24 * 3600))
        try journal.write(old)
        try journal.write(new)

        let drafts = try journal.load().drafts
        XCTAssertEqual(drafts.count, 2, "the journal itself never expires a draft")
        XCTAssertEqual(WrittenMarginDraftJournal.restoreOrder(drafts, restoredSessionId: nil).map(\.text), ["Yesterday", "Five weeks old"])
        XCTAssertEqual(WrittenMarginDraftJournal.restoreOrder(drafts, restoredSessionId: old.sessionId).map(\.text), ["Five weeks old", "Yesterday"])
    }

    func testARestoreForAnotherSessionIsRefused() throws {
        let first = newEngine()
        let capture = try capture(of: first, itemId: "item-a")
        let other = newEngine()
        _ = try other.startSession(itemId: "item-b")
        XCTAssertThrowsError(try other.restoreWrittenInterjection(capture))
    }
}

/// #1970: writes follow pauses in typing, not keystrokes.
@MainActor
final class WrittenMarginDraftSaverTests: XCTestCase {
    private func capture() -> WrittenInterjectionCapture {
        WrittenInterjectionCapture(
            id: "capture-1", sessionId: "s", itemId: "i", targetType: .item, targetId: "t",
            anchor: Anchor(anchorType: .text, startChar: 3, endChar: 3, anchorBefore: "a", anchorAfter: "b"), roughPercent: 10, wasPlaying: true
        )
    }

    private func journal() -> WrittenMarginDraftJournal {
        WrittenMarginDraftJournal(directory: FileManager.default.temporaryDirectory
            .appending(path: "written-saver-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    func testTypingWritesOnlyTheLatestTextOncePauseHasPassed() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        let saver = WrittenMarginDraftSaver(journal: journal, pause: .milliseconds(50))
        saver.textChanged("H", capture: capture())
        saver.textChanged("He", capture: capture())
        saver.textChanged("Hello", capture: capture())
        XCTAssertTrue(try journal.load().drafts.isEmpty, "nothing is written mid-typing")
        try await Task.sleep(for: .milliseconds(300))
        saver.waitForWrites()
        XCTAssertEqual(try journal.load().drafts.map(\.text), ["Hello"])
    }

    func testFlushWritesAtOnceAndDiscardClears() throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        let saver = WrittenMarginDraftSaver(journal: journal, pause: .seconds(60))
        saver.textChanged("pending", capture: capture())
        saver.flush("flushed", capture: capture())
        saver.waitForWrites()
        XCTAssertEqual(try journal.load().drafts.map(\.text), ["flushed"])
        saver.discard(captureId: "capture-1")
        saver.waitForWrites()
        XCTAssertTrue(try journal.load().drafts.isEmpty)
    }

    /// The file calls run on a queue (#2510), so a discard right behind a flush must land after it, not before.
    func testADiscardQueuedBehindAFlushLeavesNothing() throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        let saver = WrittenMarginDraftSaver(journal: journal, pause: .seconds(60))
        for round in 0..<20 {
            saver.flush("text \(round)", capture: capture())
            saver.discard(captureId: "capture-1")
        }
        saver.waitForWrites()
        XCTAssertTrue(try journal.load().drafts.isEmpty)
        saver.flush("kept", capture: capture())
        saver.waitForWrites()
        XCTAssertEqual(try journal.load().drafts.map(\.text), ["kept"])
    }

    func testAFailedWriteIsReportedOnTheMainActor() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "written-saver-file-\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        var reported: (detail: String, onMain: Bool)?
        let saver = WrittenMarginDraftSaver(
            journal: WrittenMarginDraftJournal(directory: blocker.appending(path: "drafts", directoryHint: .isDirectory)),
            pause: .seconds(60),
            onFailure: { detail in reported = (detail, Thread.isMainThread) }
        )
        saver.flush("will not land", capture: capture())
        for _ in 0..<250 where reported == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(reported?.detail.hasPrefix("write:") == true)
        XCTAssertEqual(reported?.onMain, true)
    }

    func testADiscardStopsALaterWrite() async throws {
        let journal = journal()
        defer { try? FileManager.default.removeItem(at: journal.directory) }
        let saver = WrittenMarginDraftSaver(journal: journal, pause: .milliseconds(50))
        saver.textChanged("about to be discarded", capture: capture())
        saver.discard(captureId: "capture-1")
        try await Task.sleep(for: .milliseconds(250))
        saver.waitForWrites()
        XCTAssertTrue(try journal.load().drafts.isEmpty, "a discarded Margin is not written back")
    }
}
