import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// The status lines a chapter jump, play-from-start and local map generation report (#1003).
/// D6 folds the copied bodies into shared helpers; these pin what the listener is told.
@MainActor
final class Gate1ChapterNavigationMessagesTests: XCTestCase {
    private var savedPreferences: VoicePreferencesSnapshot!

    override func setUp() async throws {
        savedPreferences = VoicePreferencesSnapshot.capture()
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        savedPreferences.restore()
    }

    func testJumpToChapterReportsTheChapterTitleAndOpensPlayback() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        let chapter = try XCTUnwrap(model.selectedItem.chapters.dropFirst().first ?? model.selectedItem.chapters.first)

        model.jumpToChapter(chapter)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.statusMessage, "Jumped to \(chapter.title).")
        XCTAssertEqual(model.diagnostics["lastStatus"], "Jumped to \(chapter.title).")
        XCTAssertEqual(model.screen, .playback)
    }

    func testJumpToMediaChapterReportsTheChapterTitleAndOpensPlayback() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        let textChapter = try XCTUnwrap(model.selectedItem.chapters.first)
        let chapter = MediaTimelineChapter(id: textChapter.id, title: "Media \(textChapter.title)", startMs: 0, transcriptSegmentId: "segment")

        model.jumpToMediaChapter(chapter)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.statusMessage, "Jumped to Media \(textChapter.title).")
        XCTAssertEqual(model.screen, .playback)
    }

    func testPlaySourceFromBeginningReportsItAndOpensPlayback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()

        model.playSourceFromBeginning()

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.statusMessage, "Playing source from the beginning.")
        XCTAssertEqual(model.screen, .playback)
    }

    /// #3450: with the on-device model, the chapters are made first and the same message says summaries are being written.
    func testOnDeviceMapGenerationSaysGeneratedListeningMap() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: AvailableFoundationModelClient()
        )
        model.resetAndSeed()
        importPlainText(into: model)

        model.generateListeningMap()

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.statusMessage, "Generated Listening Map. Writing scene summaries on this device.")
        XCTAssertEqual(model.diagnostics["lastListeningMapMode"], "local_deterministic")
        XCTAssertFalse(model.isGeneratingListeningMap)
    }

    /// #2620: the injected client says the model is absent, so the test does not depend on which
    /// simulator or phone it runs on. The local map is deterministic and must not need the model.
    func testMapGenerationOnADeviceWithoutTheOnDeviceModelSaysGeneratedListeningMap() async {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: NoModelFoundationModelClient()
        )
        model.resetAndSeed()
        importPlainText(into: model)
        XCTAssertFalse(model.localFoundationModelAvailable)

        model.generateListeningMap()

        XCTAssertNil(model.lastError)
        // #3450: the chapters are still made, and the listener is told why they have no summaries.
        XCTAssertEqual(
            model.statusMessage,
            "Generated Listening Map. Scene summaries need the on-device model, so the chapters have no summaries. No on-device model in this test."
        )
        XCTAssertEqual(model.diagnostics["lastListeningMapMode"], "local_deterministic")
        await model.settleItemReload() // the item detail reloads off the main thread after the map is saved (#2505)
        XCTAssertFalse(model.selectedItem.chapters.isEmpty)
    }


    /// #2256: the Prepare Listening Map tap's path loads, cuts and saves off the main thread, and says what the
    /// synchronous path says when it lands.
    func testTheTapsMapGenerationOffTheMainThreadSavesTheChaptersAndSaysTheSame() async {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: NoModelFoundationModelClient()
        )
        model.resetAndSeed()
        importPlainText(into: model)
        model.run { _ in } // an engine exists, so the store work takes the off-main path and not the synchronous fallback

        model.generateListeningMapFromTap()
        XCTAssertTrue(model.isGeneratingListeningMap, "the button is held while the map is made off the main thread")
        XCTAssertNil(model.diagnostics["lastListeningMapMode"], "nothing is generated on the main thread before the tap returns")
        try? await pollUntil { !model.isGeneratingListeningMap }
        XCTAssertFalse(model.isGeneratingListeningMap)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(
            model.statusMessage,
            "Generated Listening Map. Scene summaries need the on-device model, so the chapters have no summaries. No on-device model in this test."
        )
        XCTAssertEqual(model.diagnostics["lastListeningMapMode"], "local_deterministic")
        XCTAssertEqual(model.diagnostics["lastGeneratedMapItem"], model.activeItemId)
        await model.settleItemReload()
        XCTAssertFalse(model.selectedItem.chapters.isEmpty)
    }


    private func importPlainText(into model: Gate1AppModel) {
        model.importTitle = "Plain Notes"
        model.importText = "A paragraph without structural headings. Another sentence follows. A third one closes it."
        model.importTextItem()
        XCTAssertTrue(model.selectedItem.chapters.isEmpty, "The map paths start from an item without chapters")
    }
}

private struct NoModelFoundationModelClient: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability { .unavailable("No on-device model in this test") }
    func summarizeInterjections(context: String) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        throw LocalFoundationModelError.unavailable("test")
    }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        throw LocalFoundationModelError.unavailable("test")
    }
}

private struct AvailableFoundationModelClient: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability { .available }
    func summarizeInterjections(context: String) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        throw LocalFoundationModelError.unavailable("test")
    }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        throw LocalFoundationModelError.unavailable("test")
    }
}
