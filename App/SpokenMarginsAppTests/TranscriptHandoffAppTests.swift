import SessionKitPersistence
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #2997 PR 5b: a transcript shared from the share sheet. The extension copies a `.vtt`, `.srt` or `.docx` into the App
/// Group's `TranscriptHandoffs` folder, or hands a `.txt` over as a text payload; the model imports either when it next
/// drains its handoffs (launch, foreground, Retry). These write what the extension writes, run the model's own drain, and
/// read the Library, the banner and the screen afterwards. What the files are and what is kept is host-tested in SessionKit
/// (`TranscriptHandoffTests`); this is the wiring: the drain reaches the folder, the banner is the standard one, a refusal
/// says its sentence, nothing navigates, and a `.txt` is asked whether it is a transcript.
@MainActor
final class TranscriptHandoffAppTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    private let teamsVTT = """
    WEBVTT

    00:00:03.000 --> 00:00:06.000
    Alice Example: Welcome everyone, let's start with the budget.

    00:00:06.000 --> 00:00:09.000
    Ben Sample: Thanks. I have the draft numbers ready.

    00:00:09.000 --> 00:00:12.000
    Alice Example: Great, please share them.
    """

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

    private let essay = "A short essay about nothing in particular.\n\nIt has two paragraphs and no meeting in it."

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-transcript-share-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeModel(in directory: URL) throws -> Gate1AppModel {
        let model = Gate1AppModel(
            sourceLinkHandoffStore: SourceLinkHandoffStore(baseDirectory: directory),
            browserTextHandoffStore: Gate5BrowserTextHandoffStore(baseDirectory: directory),
            audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.dismissFeedback()
        return model
    }

    /// What the share extension does: copies a provider's file into the folder, unread, under the name the share gave it.
    @discardableResult
    private func shareFile(_ name: String, _ text: String, into directory: URL) throws -> String {
        let provider = directory.appendingPathComponent("provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let url = provider.appendingPathComponent("temporary-name.tmp")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try TranscriptHandoffFolder(baseDirectory: directory).save(from: url, originalName: name)
    }

    /// What the extension writes for a shared `.txt`: a `plain_text_file` payload in the browser text folder.
    private func shareText(_ name: String, _ text: String, into directory: URL) throws {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        try Gate5BrowserTextHandoffStore(baseDirectory: directory).save(BrowserTextHandoff(
            captureMode: .plainTextFile,
            source: BrowserTextSource(url: "shared-file://share-sheet/\(encoded)", title: (name as NSString).deletingPathExtension),
            text: text,
            contentFormat: .plainText,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        ), payloadID: "payload-\(UUID().uuidString)")
    }

    private func transcripts(_ model: Gate1AppModel) throws -> [Item] {
        try model.requireStore().listItems().filter { $0.externalReferenceType == TranscriptItemText.referenceType }
    }

    private func folderEntries(_ directory: URL) throws -> Int {
        try TranscriptHandoffFolder(baseDirectory: directory).pending().count
    }

    /// Runs one more drain and waits until it reports what it found in the transcript folder (the drain writes the count
    /// every time), so a "nothing more was imported" assertion after it reads a drain that has run, not a pause.
    private func drainAgainAndSeeNothingWaiting(_ model: Gate1AppModel) async throws {
        model.diagnostics["pendingTranscriptHandoffs"] = nil
        model.importPendingSourceLinkHandoffs()
        try await waitFor("another drain to find the transcript folder empty") { model.diagnostics["pendingTranscriptHandoffs"] == "0" }
        try await waitFor("that drain to finish") { !model.isImportingPendingSourceLinkHandoffs }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testASharedVttBecomesATranscriptWithTheStandardBannerAndTheScreenStaysPut() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        try shareFile("Budget sync.vtt", teamsVTT, into: directory)
        let screenBefore = model.screen

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the banner") { model.feedbackEvent?.message == "Added Budget sync to Library." }

        let items = try transcripts(model)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Budget sync", "titled from the name the share gave it, not the temporary copy's")
        XCTAssertEqual(model.feedbackEvent?.action?.title, "Play now")
        XCTAssertEqual(model.screen, screenBefore, "a share never navigates")
        XCTAssertNil(model.snapshot.sessionId, "and never plays")
        XCTAssertEqual(try folderEntries(directory), 0, "the copy is gone once it is imported")
    }

    func testSeveralSharedFilesGetOneBannerWithNoPlayNow() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        try shareFile("Budget sync.vtt", teamsVTT, into: directory)
        try shareFile("Roadmap sync.srt", """
        1
        00:00:02,000 --> 00:00:05,000
        Carol Other: Let's review the roadmap.

        2
        00:00:05,500 --> 00:00:08,000
        Dev Another: Two items are late.
        """, into: directory)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the banner") { model.feedbackEvent?.message == "Added 2 to Library." }

        XCTAssertEqual(try transcripts(model).count, 2)
        XCTAssertNil(model.feedbackEvent?.action)
    }

    func testASharedFileThatIsNotATranscriptSaysSoAndAddsNothing() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        let before = try model.requireStore().listItems().count
        try shareFile("Standup.vtt", "", into: directory)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the message") { model.lastError != nil }

        XCTAssertEqual(model.lastError, "\u{201C}Standup.vtt\u{201D} is empty, so nothing was added.")
        XCTAssertEqual(try model.requireStore().listItems().count, before)
        XCTAssertEqual(try folderEntries(directory), 0, "a refusal is an answer, so it is not retried at every foreground")
    }

    func testAShareDuringPlaybackLeavesNowPlayingAlone() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let before = model.snapshot
        try shareFile("Budget sync.vtt", teamsVTT, into: directory)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the banner") { model.feedbackEvent?.message == "Added Budget sync to Library without changing Now Playing." }

        XCTAssertNil(model.feedbackEvent?.action)
        assertNowPlayingUnchanged(model.snapshot, from: before)
    }

    /// `relaunch`: the extension saved, and the app was not running. The first drain of the next launch imports it, once.
    func testAShareWaitingBeforeTheAppStartedIsImportedOnceHoweverOftenTheDrainRuns() async throws {
        let directory = makeDirectory()
        try shareFile("Budget sync.vtt", teamsVTT, into: directory)
        let model = try makeModel(in: directory)

        model.importPendingSourceLinkHandoffs()
        model.importPendingSourceLinkHandoffs()
        try await waitFor("the item") { try transcripts(model).count == 1 }
        try await drainAgainAndSeeNothingWaiting(model)

        XCTAssertEqual(try transcripts(model).count, 1)
        XCTAssertEqual(try folderEntries(directory), 0)
    }

    func testASharedTxtThatIsATranscriptBecomesATranscriptItem() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        try shareText("meeting.txt", zoomTXT, into: directory)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the transcript") { try transcripts(model).count == 1 }

        XCTAssertEqual(try transcripts(model).first?.externalReference, "meeting.txt")
        try await waitFor("the banner") { model.feedbackEvent?.message.hasPrefix("Added ") == true }
    }

    func testASharedTxtThatIsAnEssayStaysOrdinaryText() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        let before = try model.requireStore().listItems().count
        try shareText("essay.txt", essay, into: directory)

        model.importPendingSourceLinkHandoffs()
        try await waitFor("the text item") { try model.requireStore().listItems().count == before + 1 }

        XCTAssertTrue(try transcripts(model).isEmpty)
    }

    /// The same text shared twice, a double share or two friends sending it, is one item: the id comes from the words.
    func testTheSameSharedTextTranscriptSharedTwiceIsOneItem() async throws {
        let directory = makeDirectory()
        let model = try makeModel(in: directory)
        try shareText("meeting.txt", zoomTXT, into: directory)
        model.importPendingSourceLinkHandoffs()
        try await waitFor("the first import") { try transcripts(model).count == 1 }
        let id = try XCTUnwrap(try transcripts(model).first?.id)

        try shareText("meeting.txt", zoomTXT, into: directory)
        try await drainAgainAndSeeNothingWaiting(model)

        XCTAssertEqual(try transcripts(model).map(\.id), [id])
    }
}
