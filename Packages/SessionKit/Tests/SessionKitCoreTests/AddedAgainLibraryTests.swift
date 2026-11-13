import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4178: an article shared from Safari (share sheet or extension) said "Added to Library" and never showed in it.
/// The article had been heard before, so the import brought back the old copy: finished, so the Library's default
/// "Unfinished" view hid it, and with its old "added" date, so it sorted far down. These tests run the real import on a
/// real SQLite store and read the Library rows the way the screen does, with its default query.
final class AddedAgainLibraryTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private var engine: SessionEngine!
    private let rowContext = StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test",
            capabilities: ["sync": ["canonical_persistence", "browser_session_handoff"]]), repository: store)
    }

    override func tearDownWithError() throws {
        engine = nil
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private let essay = BrowserTextHandoff(
        captureMode: .readablePage,
        source: BrowserTextSource(url: "https://institute.example/essays/the-economics-of-intelligence/",
                                  title: "AGI Economics: Coordination vs. Competence"),
        text: "# The Economics of Intelligence\n\nSmarter AI will increase productivity.\n\nThe rest of the essay.",
        contentFormat: .markdown)

    /// What the Library screen lists with its default filters and sort.
    private func visibleRows() throws -> [LibraryItemRow] {
        let rows = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: rowContext)
        return LibraryQueryEngine.visibleLibraryItems(rows, query: LibraryQuery())
    }

    /// An older Library item, so "Recently Added" has something to sort the new one above.
    private func addOlderItem(daysAgo: Double) throws {
        var older = try engine.importBrowserTextInBackground(BrowserTextHandoff(
            captureMode: .readablePage, source: BrowserTextSource(url: "https://other.example/\(daysAgo)", title: "Older \(daysAgo)"),
            text: "An article added \(daysAgo) days ago.", contentFormat: .markdown))
        older.createdAt = Date(timeIntervalSinceNow: -86_400 * daysAgo)
        try store.saveItem(older)
    }

    /// The essay as it stood after the listener heard it ten days ago: one finished session.
    private func essayHeardTenDaysAgo() throws -> Item {
        var item = try engine.importBrowserTextInBackground(essay)
        let tenDaysAgo = Date(timeIntervalSinceNow: -86_400 * 10)
        item.createdAt = tenDaysAgo
        try store.saveItem(item)
        try store.saveSession(Session(
            id: "heard", itemId: item.id, createdAt: tenDaysAgo, updatedAt: tenDaysAgo, completedAt: tenDaysAgo,
            status: "finished", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: 60), completionPercent: 100, playbackRate: 1))
        return item
    }

    func testANewArticleSharedFromSafariIsTheFirstRow() throws {
        try addOlderItem(daysAgo: 3)
        let item = try engine.importBrowserTextInBackground(essay)
        XCTAssertEqual(try visibleRows().first?.id, item.id)
    }

    func testAnArticleHeardAndDeletedThenSharedAgainIsTheFirstUnfinishedRow() throws {
        let heard = try essayHeardTenDaysAgo()
        try store.moveItemToTrash(id: heard.id)
        try addOlderItem(daysAgo: 1)

        let again = try engine.importBrowserTextInBackground(essay)

        XCTAssertEqual(again.id, heard.id, "the share lands on the same item, so its Margins stay with it")
        let first = try XCTUnwrap(try visibleRows().first)
        XCTAssertEqual(first.id, heard.id, "the Library lists what it just said it added, first")
        XCTAssertFalse(first.isCompleted)
        XCTAssertEqual(try store.loadSessions(itemId: heard.id).map(\.id), ["heard"], "the old listening is kept")
        XCTAssertEqual(try store.loadItem(id: heard.id).createdAt?.timeIntervalSince1970 ?? 0,
                       heard.createdAt?.timeIntervalSince1970 ?? 0, accuracy: 1, "the first-added date is kept")
    }

    func testAnArticleHeardAndKeptThenSharedAgainIsTheFirstUnfinishedRow() throws {
        let heard = try essayHeardTenDaysAgo()
        try addOlderItem(daysAgo: 1)
        XCTAssertFalse(try visibleRows().contains { $0.id == heard.id }, "finished: the default view hides it")

        _ = try engine.importBrowserTextInBackground(essay)

        XCTAssertEqual(try visibleRows().first?.id, heard.id)
    }

    func testAnArticleMarkedFinishedThenSharedAgainIsUnfinished() throws {
        var item = try engine.importBrowserTextInBackground(essay)
        item.sourceCompletedAt = Date(timeIntervalSinceNow: -3_600)
        item.createdAt = Date(timeIntervalSinceNow: -86_400)
        try store.saveItem(item)
        try addOlderItem(daysAgo: 2)

        _ = try engine.importBrowserTextInBackground(essay)

        XCTAssertNil(try store.loadItem(id: item.id).sourceCompletedAt)
        XCTAssertEqual(try visibleRows().first?.id, item.id)
    }

    /// The owner's case with the app left as it was: the essay finished in Now Playing, and the engine still holds that
    /// finished session when it is shared again. Nothing shows it, so the share marks it added again; closing the old
    /// session afterwards saves it once more, which must not make the essay finished again.
    func testAnArticleStillHeldFinishedWhenSharedAgainIsTheFirstUnfinishedRow() throws {
        let heard = try essayHeardTenDaysAgo()
        try addOlderItem(daysAgo: 1)
        XCTAssertEqual(try engine.inspectSession(sessionId: "heard").phase, .finished)

        _ = try engine.importBrowserTextInBackground(essay)
        XCTAssertEqual(try visibleRows().first?.id, heard.id)

        _ = try engine.endSession()
        XCTAssertEqual(try visibleRows().first?.id, heard.id, "closing the old session doesn't finish it again")
        XCTAssertNil(try store.loadItem(id: heard.id).sourceCompletedAt)
        XCTAssertNotNil(try store.loadItem(id: heard.id).addedAgainAt, "the held copy kept the stamp")
    }

    /// Then Play from the beginning on that same held session, after the re-add. A share while it replays leaves it
    /// alone (the listener is in it), and hearing it to the end finishes it again, though the session is the old one.
    func testTheHeldSessionReplayedToTheEndAfterTheReAddFinishesTheArticleAgain() throws {
        let heard = try essayHeardTenDaysAgo()
        let audio = EndableSpeechClient()
        let player = SessionEngine(profile: RuntimeCapabilityProfile(id: "test", displayName: "Test", capabilities: [
            "sync": ["canonical_persistence", "browser_session_handoff"], "playback": ["realtime_tts"]]),
            repository: store, audio: audio)
        XCTAssertEqual(try player.inspectSession(sessionId: "heard").phase, .finished)
        _ = try player.importBrowserTextInBackground(essay)
        let addedAgainAt = try XCTUnwrap(try store.loadItem(id: heard.id).addedAgainAt)

        _ = try player.playSourceFromBeginning()
        _ = try player.importBrowserTextInBackground(essay)
        XCTAssertEqual(try store.loadItem(id: heard.id).addedAgainAt, addedAgainAt, "a share while it plays leaves it as it is")
        XCTAssertEqual(try visibleRows().first?.id, heard.id, "replaying is not finishing")

        audio.ended = true
        _ = try player.syncPlaybackProgress()

        XCTAssertEqual(try store.loadSession(id: "heard")?.phase, .finished)
        XCTAssertFalse(try visibleRows().contains { $0.id == heard.id }, "heard to the end again: finished")
        XCTAssertNotNil(try store.loadItem(id: heard.id).sourceCompletedAt)
    }

    /// Read-later and shared text name their own id: the import replaces the row saved under it, whose finished session
    /// is still filed there.
    func testAHandoffThatNamesItsIdAndWasHeardBeforeIsUnfinishedAgain() throws {
        var named = essay; named.itemId = "read-later-essay"
        var item = try engine.importBrowserTextInBackground(named)
        let tenDaysAgo = Date(timeIntervalSinceNow: -86_400 * 10)
        item.createdAt = tenDaysAgo
        try store.saveItem(item)
        try store.saveSession(Session(
            id: "heard", itemId: item.id, createdAt: tenDaysAgo, updatedAt: tenDaysAgo, completedAt: tenDaysAgo,
            status: "finished", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: 60), completionPercent: 100, playbackRate: 1))
        try addOlderItem(daysAgo: 1)
        XCTAssertFalse(try visibleRows().contains { $0.id == item.id })

        _ = try engine.importBrowserTextInBackground(named)

        XCTAssertEqual(try visibleRows().first?.id, item.id)
    }

    /// The share the owner made while something else played: the off-main import (PDFs and web PDFs take it) marks it
    /// added again too.
    @MainActor
    func testTheOffMainImportMarksAnArticleAddedAgain() async throws {
        let heard = try essayHeardTenDaysAgo()
        try store.moveItemToTrash(id: heard.id)
        try addOlderItem(daysAgo: 1)

        _ = try await engine.importBrowserTextInBackgroundOffMain(essay)

        XCTAssertEqual(try visibleRows().first?.id, heard.id)
    }

    /// Following's "Add every new item" is not the listener asking: an article they finished stays finished.
    func testAnImportTheListenerDidNotAskForLeavesAFinishedArticleFinished() throws {
        let heard = try essayHeardTenDaysAgo()

        _ = try engine.importBrowserTextInBackground(essay, listenerAdded: false)

        XCTAssertNil(try store.loadItem(id: heard.id).addedAgainAt)
        XCTAssertFalse(try visibleRows().contains { $0.id == heard.id })
    }

    /// Heard again to the end after the re-add: finished again, as any item.
    func testAnItemAddedAgainAndHeardToTheEndIsFinishedAgain() throws {
        let heard = try essayHeardTenDaysAgo()
        _ = try engine.importBrowserTextInBackground(essay)
        let later = Date(timeIntervalSinceNow: 60)
        try store.saveSession(Session(
            id: "heard-again", itemId: heard.id, createdAt: later, updatedAt: later, completedAt: later,
            status: "finished", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: heard.id,
            position: Position(charOffset: 60), completionPercent: 100, playbackRate: 1))

        XCTAssertFalse(try visibleRows().contains { $0.id == heard.id })
    }

    func testCountedSessionsAfterAnAddAgain() {
        let addedAgain = Date(timeIntervalSince1970: 1_000)
        var item = LibraryItemSummary(id: "a", title: "A", mediaType: "text", status: "ready",
                                      hasListenableText: true, textCharacterCount: 10)
        func session(_ id: String, created: Double?, updated: Double?, completed: Double?) -> Session {
            Session(id: id, itemId: "a", createdAt: created.map(Date.init(timeIntervalSince1970:)),
                    updatedAt: updated.map(Date.init(timeIntervalSince1970:)),
                    completedAt: completed.map(Date.init(timeIntervalSince1970:)),
                    status: "finished", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: "a",
                    position: Position(), completionPercent: 100, playbackRate: 1)
        }
        let sessions = [
            session("before", created: 10, updated: 20, completed: 20),
            session("untimed", created: nil, updated: nil, completed: nil), // written before timestamps existed
            session("spans", created: 900, updated: 1_100, completed: nil), // begun before, played on after
            session("after", created: 1_200, updated: 1_300, completed: 1_300),
            session("same-second", created: 1_000, updated: 1_000, completed: 1_000),
            session("finished-resaved", created: 10, updated: 1_500, completed: 20), // saved once more as it closed
        ]
        XCTAssertEqual(ItemFinishedRule.countedSessions(item, sessions: sessions).map(\.id),
                       sessions.map(\.id), "never added again: every session counts")
        item.addedAgainAt = addedAgain
        XCTAssertEqual(ItemFinishedRule.countedSessions(item, sessions: sessions).map(\.id), ["spans", "after"])
        XCTAssertTrue(ItemFinishedRule.isFinished(item, sessions: sessions))
        XCTAssertFalse(ItemFinishedRule.isFinished(item, sessions: Array(sessions.prefix(2))))
    }

    func testFollowingDoesNotCountAnEpisodeAddedAgainAsHeard() {
        var episode = LibraryItemSummary(id: "e", title: "E", mediaType: "podcast", status: "ready",
                                         hasListenableText: false, textCharacterCount: nil)
        let heard = Session(id: "s", itemId: "e", createdAt: Date(timeIntervalSince1970: 10),
                            updatedAt: Date(timeIntervalSince1970: 20), status: "playing", phase: .itemPlayback,
                            currentTargetType: .itemTextTTS, currentTargetId: "e", position: Position(),
                            completionPercent: 96, playbackRate: 1)
        XCTAssertTrue(FollowingHeardRule.isHeard(item: episode, sessions: [heard]))
        episode.addedAgainAt = Date(timeIntervalSince1970: 30)
        XCTAssertFalse(FollowingHeardRule.isHeard(item: episode, sessions: [heard]))
    }

    /// The Diagnostics line every "Added to Library" now records: listed, or the first reason it isn't.
    func testAddedItemVisibilityNamesWhyTheLibraryLeavesAnItemOut() throws {
        let heard = try essayHeardTenDaysAgo()
        try addOlderItem(daysAgo: 1)
        func visibility(_ query: LibraryQuery = LibraryQuery(), id: String? = nil) throws -> String {
            let rows = LibraryRowBuilder.rows(from: try LibraryReadSnapshot.read(store: store), context: rowContext)
            return LibraryQueryEngine.addedItemVisibility(itemId: id ?? heard.id, in: rows, query: query)
        }
        XCTAssertEqual(try visibility(), "hidden:finished", "what the owner's three shares would have recorded")
        XCTAssertEqual(try visibility(id: "item-missing"), "hidden:no_row")
        _ = try engine.importBrowserTextInBackground(essay)
        XCTAssertEqual(try visibility(), "visible:row_1")
        XCTAssertEqual(try visibility(LibraryQuery(query: "zebra")), "hidden:search")
        XCTAssertEqual(try visibility(LibraryQuery(contentType: .podcast)), "hidden:content_filter")
        XCTAssertEqual(try visibility(LibraryQuery(listeningState: .completed)), "hidden:listening_filter")
        XCTAssertEqual(try visibility(LibraryQuery(offlineState: .readyOffline)), "hidden:offline_filter")
    }

    /// The summary the Library reads from the store carries the stamp, as the whole item does.
    func testTheStoredSummaryCarriesTheAddAgain() throws {
        let heard = try essayHeardTenDaysAgo()
        _ = try engine.importBrowserTextInBackground(essay)
        let summary = try XCTUnwrap(try store.loadItemSummary(id: heard.id))
        XCTAssertEqual(summary, LibraryItemSummary(try store.loadItem(id: heard.id)))
        XCTAssertNotNil(summary.addedAgainAt)
    }
}

/// A speech player the test ends.
private final class EndableSpeechClient: AudioPlaybackClient {
    var ended = false
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { ended = false }
    func play(targetId: String, from charOffset: Int) throws { ended = false }
    func pause() throws {}
    func isPlaybackComplete(targetId: String) -> Bool { ended }
}
