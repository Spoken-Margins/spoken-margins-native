import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2997 PR 4, the Design's `other-item-playing` row: importing a transcript while a podcast plays says
/// "…without changing Now Playing.", offers no Play now, and leaves the playing item alone. The import is real
/// (a temporary SQLite store); the banner and the confirmation are the same types the app calls.
final class TranscriptWhileSomethingPlaysTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private let utc = TimeZone(identifier: "UTC")!
    private let vtt = """
    WEBVTT

    1
    00:00:03.500 --> 00:00:06.000
    Alice Example: Welcome everyone, let's start with the budget.

    2
    00:00:06.500 --> 00:00:09.000
    Ben Sample: Thanks. I have the draft numbers ready.
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-playing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func podcast() -> Item {
        var item = Item(
            id: "podcast-playing", title: "Episode 12", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/12.mp3"))
        item.showTitle = "The Show"
        return item
    }

    /// Imports the fixture the way the Files route does and returns the one banner the pick leaves.
    private func importPick() async throws -> (title: String, banner: TranscriptPickBanner.Banner) {
        let outcome = try await TranscriptLibraryImport.importFile(
            name: "zoom.vtt", data: Data(vtt.utf8), store: store,
            docxText: { _ in throw CancellationError() }, now: Date(timeIntervalSince1970: 1_000), timeZone: utc)
        guard case .added(let id, let title, _) = outcome else {
            XCTFail("expected an added transcript, got \(outcome)")
            throw CancellationError()
        }
        let banner = TranscriptPickBanner.make(
            added: [(itemId: id, title: title)], refusals: [], documentsImported: 0, documentFailureNames: [], pickedCount: 1)
        return (title, banner)
    }

    func testImportingWhilePlayingLeavesTheEpisodeAndOffersNoPlayNow() async throws {
        let playing = podcast()
        try store.saveItem(playing)

        let (title, banner) = try await importPick()
        guard case .addedOne(_, let bannerTitle) = banner else { return XCTFail("a lone transcript is the standard banner, got \(banner)") }
        XCTAssertEqual(bannerTitle, title)

        // Every phase that holds Now Playing: the words and the missing button are the same for each.
        let holding: [SessionPhase] = [
            .idle, .itemPlayback, .recordingInterjection, .interjectionSummary, .summaryPlayback,
            .addendumCapture, .aiResponsePlayback, .conversation,
        ]
        for phase in holding {
            let empty = AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: "session-1", phase: phase)
            XCTAssertFalse(empty, "\(phase) holds Now Playing")
            let confirmation = AddedToLibraryConfirmation(title: bannerTitle, nowPlayingIsEmpty: empty)
            XCTAssertEqual(confirmation.message, "Added \(bannerTitle) to Library without changing Now Playing.", "\(phase)")
            XCTAssertFalse(confirmation.offersPlayNow, "\(phase)")
        }

        XCTAssertEqual(try store.loadItem(id: "podcast-playing"), playing, "the playing episode is untouched")
        XCTAssertEqual(try store.listItems().count, 2, "the transcript is a new row beside it")
    }

    func testImportingWithNothingPlayingOffersPlayNowAndStillStartsNothing() async throws {
        let (title, banner) = try await importPick()
        guard case .addedOne(let id, _) = banner else { return XCTFail("got \(banner)") }

        // No session, or one that has finished or been abandoned, is an empty Now Playing.
        let empties: [(String?, SessionPhase)] = [(nil, .idle), ("old", .finished), ("old", .abandoned)]
        for (sessionId, phase) in empties {
            let empty = AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: sessionId, phase: phase)
            XCTAssertTrue(empty, "\(String(describing: sessionId)) \(phase)")
            let confirmation = AddedToLibraryConfirmation(title: title, nowPlayingIsEmpty: empty)
            XCTAssertEqual(confirmation.message, "Added \(title) to Library.")
            XCTAssertTrue(confirmation.offersPlayNow)
        }
        // Importing only saves the item: no session record exists until the listener taps Play now.
        XCTAssertEqual(try store.loadItem(id: id).status, "needs_listening_map")
    }
}
