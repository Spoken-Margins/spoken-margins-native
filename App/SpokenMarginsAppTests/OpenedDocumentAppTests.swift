import SessionKitPersistence
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #2997 PR 5: a transcript opened from Files, Mail or an AirDrop goes through the model's `handleIncomingURL`, the way
/// the system delivers it. These read the Library and the screen afterwards: the item exists and is a transcript, the
/// app did not navigate, and a file the app does not add says so and adds nothing.
@MainActor
final class OpenedDocumentAppTests: XCTestCase {
    private let zoomTXT = """
    Budget sync
    Mar 4, 2026 10:00 AM

    Alice Example  0:03
    Welcome everyone, let's start with the budget.

    Ben Sample  0:06
    Thanks. I have the draft numbers ready.

    Alice Example  0:09
    Great, please share them.
    """

    private let teamsVTT = """
    WEBVTT

    00:00:03.000 --> 00:00:06.000
    Alice Example: Welcome everyone, let's start with the budget.

    00:00:06.000 --> 00:00:09.000
    Ben Sample: Thanks. I have the draft numbers ready.

    00:00:09.000 --> 00:00:12.000
    Alice Example: Great, please share them.
    """

    private func makeModel() throws -> (Gate1AppModel, SQLiteSessionStore) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return (model, try model.requireStore())
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opened-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func transcripts(in store: SQLiteSessionStore) throws -> [Item] {
        try store.listItems().filter { $0.externalReferenceType == TranscriptItemText.referenceType }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(what)")
    }

    /// The copies Open In stages in the temporary folder, so a test can see that none is left behind.
    private var stagedCopies: Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return names.filter { $0.hasPrefix("OpenedDocuments-") }.count
    }

    func testAVttOpenedFromFilesBecomesATranscriptAndTheScreenStaysPut() async throws {
        let (model, store) = try makeModel()
        let screenBefore = model.screen
        let copiesBefore = stagedCopies
        model.handleIncomingURL(try write("Budget sync.vtt", teamsVTT))
        try await waitFor("the transcript item") { try !transcripts(in: store).isEmpty }
        XCTAssertEqual(try transcripts(in: store).count, 1)
        XCTAssertEqual(try transcripts(in: store).first?.title, "Budget sync", "the title is the file's name, not a temporary copy's")
        XCTAssertEqual(model.screen, screenBefore, "opening a file from outside never navigates")
        try await waitFor("the staged copy to be deleted") { stagedCopies <= copiesBefore }
    }

    func testTheSameBytesOpenedAndPickedGiveOneItem() async throws {
        let (model, store) = try makeModel()
        model.handleIncomingURL(try write("meeting.txt", zoomTXT))
        try await waitFor("the opened transcript") { try transcripts(in: store).count == 1 }
        let openedId = try XCTUnwrap(try transcripts(in: store).first?.id)
        try await waitFor("the import slot to free") { model.sourceImportTask == nil }

        let finished = expectation(description: "the pick ended")
        var route = Gate1AppModel.TranscriptPickRoute(securityScopedURLs: [])
        route.onFinished = { _ in finished.fulfill() }
        model.importFilesWithTranscriptRule(urls: [try write("meeting.txt", zoomTXT)], route: route)
        await fulfillment(of: [finished], timeout: 20)

        XCTAssertEqual(try transcripts(in: store).map(\.id), [openedId],
                       "Files and Open In read the same bytes to the same item, added again rather than twice")
    }

    func testTwoFilesOpenedAtOnceAreBothAddedNotRefused() async throws {
        let (model, store) = try makeModel()
        let copiesBefore = stagedCopies
        let second = teamsVTT.replacingOccurrences(of: "budget", with: "roadmap")
        model.handleIncomingURL(try write("Budget sync.vtt", teamsVTT))
        model.handleIncomingURL(try write("Roadmap sync.vtt", second))
        try await waitFor("both transcripts") { try transcripts(in: store).count == 2 }
        XCTAssertNotEqual(model.lastError, "Another source is already importing. You can keep using playback while it finishes.")
        try await waitFor("the staged copies to be deleted") { stagedCopies <= copiesBefore }
    }

    func testAMarkdownFileOpenedFromFilesIsOrdinaryTextNotATranscript() async throws {
        let (model, store) = try makeModel()
        let before = try store.listItems().count
        let screenBefore = model.screen
        model.handleIncomingURL(try write("notes.md", "# Notes\n\nSomething to read on the train."))
        try await waitFor("the text item") { try store.listItems().count == before + 1 }
        XCTAssertTrue(try transcripts(in: store).isEmpty)
        XCTAssertEqual(model.screen, screenBefore)
    }

    func testAnotherTextTypeSaysItCannotBeAddedAndAddsNothing() async throws {
        let (model, store) = try makeModel()
        let before = try store.listItems().count
        model.handleIncomingURL(try write("table.csv", "a,b\n1,2\n"))
        XCTAssertEqual(
            model.lastError,
            "Spoken Margins can't add \u{201C}table.csv\u{201D}. It adds meeting transcripts (.vtt, .srt, .docx, .txt) and text or Markdown files.")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try store.listItems().count, before)
    }

    func testAFileThatCannotBeReadSaysSoAndAddsNothing() async throws {
        let (model, store) = try makeModel()
        let before = try store.listItems().count
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("opened-doc-gone-\(UUID().uuidString)/Standup.vtt")
        model.handleIncomingURL(gone)
        try await waitFor("the message") { model.lastError != nil }
        XCTAssertEqual(
            model.lastError,
            "\u{201C}Standup.vtt\u{201D} couldn't be read. If it's in iCloud Drive, open it in Files so it downloads, then try again.")
        XCTAssertEqual(try store.listItems().count, before)
    }

    func testFilesTheDocumentRouteDoesNotOwnKeepTheirOtherRoutes() throws {
        let (model, _) = try makeModel()
        for name in ["paper.pdf", "book.epub", "episode.mp3", "friend.spokenmargins"] {
            XCTAssertFalse(model.handleOpenedFile(try write(name, "x")), name)
        }
    }
}
