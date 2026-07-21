import XCTest
import SessionKit
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class Gate1AppModelWorkflowTests: XCTestCase {
    func testWelcomeSampleSeedsOnlyForANewEmptyNonUITestLibrary() {
        XCTAssertTrue(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 0,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: false,
            storedVersion: 0,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 1,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 0,
            isUITesting: true
        ))
    }

    func testBundledSampleExplainsTheAppInsteadOfSeedingTheContractArticle() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.addSampleItem()

        XCTAssertEqual(model.selectedItem.title, "Welcome to Spoken Margins")
        XCTAssertTrue(model.selectedItem.text.contains("structured listening workspace"))
        XCTAssertTrue(model.selectedItem.text.contains("Listening Map"))
        XCTAssertTrue(model.selectedItem.text.contains("Tap Interject"))
        XCTAssertTrue(model.selectedItem.text.contains("backward and forward buttons"))
        XCTAssertTrue(model.selectedItem.text.contains("paste a podcast"))
        XCTAssertTrue(model.selectedItem.text.contains("Import Text or PDF Files"))
        XCTAssertFalse(model.selectedItem.text.contains("You Can't Inspect the Pill"))
        XCTAssertEqual(model.selectedItem.chapters.count, 5)
    }

    func testManualImportClearsEntryFieldsAfterSuccessfulCreate() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Scratch Item"
        model.importText = "This is pasted text. It should not remain in the import form."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.importTitle, "")
        XCTAssertEqual(model.importText, "")
        XCTAssertEqual(model.selectedItem.title, "Scratch Item")
    }

    func testLeavingPlaybackKeepsSessionPlayingAndShowsMiniPlayer() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Currently Playing"
        model.importText = "This remains the Now Playing item."
        model.importTextItem()
        let playingItemId = model.selectedItem.id

        model.openHome()
        model.openItem(id: "item-pill")
        model.openHome()

        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertTrue(model.shouldShowMiniPlayer)
        model.openPlayback()
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.selectedItem.id, playingItemId)
        XCTAssertFalse(model.shouldShowMiniPlayer)
    }

    func testTrashUndoPreservesItemSessions() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertFalse(model.selectedItem.sessions.isEmpty)

        model.moveItemToTrash(id: "item-pill")

        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertTrue(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertEqual(model.trashUndo?.itemId, "item-pill")

        model.undoLastTrash()
        model.openItem(id: "item-pill")

        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.selectedItem.sessions.isEmpty, "Restoring an item should restore its existing sessions")
    }

    func testTextImportStartsLiveSpeechWhenPreparedRenderingIsUnavailable() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            forcePreparedTextGate: true
        )
        model.resetAndSeed()
        model.importTitle = "Prepared First"
        model.importText = "This text should start immediately while generated audio renders in the background."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertNil(model.pendingPreparedTextStartItemId)
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.preparedTextAudioStatus, "live_fallback")
        XCTAssertFalse(model.canPlayLiveSpeechInstead)
    }

    func testTextImportKeepsLiveSpeechStableWhilePreparedMediaRendersInBackground() async throws {
        let prewarm = PreparedTextAudioPrewarmProbe()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            preparedTextAudioPrewarmHandler: { itemId, title, text, _, _, _ in
                let prepared = await prewarm.prepare(itemId: itemId, title: title, text: text)
                return .success(prepared)
            }
        )
        model.resetAndSeed()
        model.importTitle = "Prepared First"
        model.importText = "This text should start immediately while generated audio renders in the background."

        model.importTextItem()
        let request = await prewarm.waitForRequest()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.preparedTextAudioStatus, "rendering")
        XCTAssertEqual(request.title, "Prepared First")

        await prewarm.complete(with: preparedTextAudio(itemId: request.itemId, title: request.title, text: request.text))
        try await waitFor("prepared audio to attach") {
            model.preparedTextAudioStatus == "ready"
        }

        XCTAssertEqual(model.snapshot.preparedTextAudioStatus, "ready")
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.snapshot.targetId, request.itemId)
        XCTAssertFalse(model.canPlayLiveSpeechInstead)
    }

    func testResumeCompletedSessionAfterExportRestartsSourcePlayback() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Short Item"
        model.importText = "One sentence only."
        model.importTextItem()
        model.skipUnit = "section"
        model.skipForward()
        model.openExport()

        let completedSession = try XCTUnwrap(model.selectedItem.sessions.last)
        model.resumeSession(completedSession)

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, "item_text_tts")
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 0)
    }

    func testLifecycleSyncPersistsLatestTextPlaybackPosition() throws {
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Long Item"
        model.importText = "One. Two. Three."

        model.importTextItem()
        audio.currentOffset = "One. Two. ".count
        model.syncPlaybackProgressForLifecycle()

        let session = try XCTUnwrap(model.selectedItem.sessions.last)
        XCTAssertEqual(session.position.charOffset, "One. Two. ".count)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. Two. ".count)
        XCTAssertEqual(model.diagnostics["playbackLifecycleSync"], "saved")
    }

    func testPlaybackSpeechRateChangeRestartsActiveNativeTextAtCurrentOffset() throws {
        let previousSpeechRate = UserDefaults.standard.object(forKey: "speechRate")
        defer {
            if let previousSpeechRate {
                UserDefaults.standard.set(previousSpeechRate, forKey: "speechRate")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechRate")
            }
        }
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Rate Change"
        model.importText = "One. Two. Three."

        model.importTextItem()
        audio.currentOffset = "One. ".count
        model.speechRate = 0.65
        model.playbackSpeechRateChanged()

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. ".count)
        XCTAssertEqual(audio.playedOffsets.last, "One. ".count)
        XCTAssertEqual(try XCTUnwrap(audio.configuredSpeechRates.last), Float(0.65), accuracy: Float(0.001))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "speechRate"), 0.65, accuracy: 0.001)
    }

    func testLegacyEmbeddedPiperModeMigratesToInstalledSystemVoicePath() {
        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())
        model.resetAndSeed()
        model.ttsMode = "piper"

        model.speechSettingsChanged()

        XCTAssertEqual(model.ttsMode, "systemImmediate")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsMode"), "systemImmediate")
    }

    func testVoiceChangeWhilePausedDoesNotCreatePhantomPlaybackProgress() throws {
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Paused Voice Change"
        model.importText = "One. Two. Three."
        model.importTextItem()
        audio.currentOffset = "One. ".count
        model.pause()
        let playCount = audio.playedOffsets.count

        model.speechVoiceIdentifier = "test.voice"
        model.speechSettingsChanged()

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. ".count)
        XCTAssertEqual(audio.playedOffsets.count, playCount)
        XCTAssertEqual(audio.configuredSpeechVoices.last!, "test.voice")
    }

    func testObsidianImportRunsInBackgroundAndLoadsHeadingBasedListeningMap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-markdown-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Structured Article.md")
        try """
        ---
        title: "Structured Article"
        ---
        ### Key takeaways

        Opening content.

        ### 1\\. First section

        First body.

        ### 2\\. Second section

        Second body.
        """.write(to: file, atomically: true, encoding: .utf8)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])

        XCTAssertTrue(model.isImportingSources)
        try await waitFor("Obsidian import to finish") {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "Structured Article")
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Key takeaways", "1. First section", "2. Second section"])
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.status, "Ready to listen")
    }

    #if canImport(UIKit)
    func testTextBasedPDFImportExtractsReadableText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Readable PDF.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            ("A readable PDF paragraph for Spoken Margins." as NSString).draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
            )
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])
        try await waitFor("PDF import to finish") {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "Readable PDF")
        XCTAssertTrue(model.selectedItem.text.contains("A readable PDF paragraph for Spoken Margins."))
    }

    func testPDFVisualHeadingsPrebuildDeterministicListeningMap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-structured-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Structured PDF.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            var y: CGFloat = 30
            func draw(_ text: String, size: CGFloat, bold: Bool = false) {
                (text as NSString).draw(
                    at: CGPoint(x: 40, y: y),
                    withAttributes: [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)]
                )
                y += size + 13
            }
            draw("A Structured Report", size: 26, bold: true)
            for section in ["Context", "Evidence", "Tradeoffs", "Recommendations", "Conclusion"] {
                draw(section, size: 18, bold: true)
                draw("This section contains enough readable body text to establish the ordinary document font size.", size: 12)
            }
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])
        try await waitFor("structured PDF import to finish") {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "A Structured Report")
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Context", "Evidence", "Tradeoffs", "Recommendations", "Conclusion"])
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.status, "Ready to listen")
    }
    #endif

    func testPlaybackControlsRemainUsableWhileObsidianImportIsPending() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-responsive-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Long Import.md")
        let paragraphs = Array(repeating: "A source paragraph that takes some work to normalize.", count: 2_000)
        try paragraphs.joined(separator: "\n\n").write(to: file, atomically: true, encoding: .utf8)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertEqual(model.snapshot.status, .playing)

        model.importObsidianMarkdownFiles(urls: [file])
        XCTAssertTrue(model.isImportingSources)

        model.playPause()

        XCTAssertEqual(model.snapshot.status, .paused)
        try await waitFor("responsive Obsidian import to finish", timeoutNanoseconds: 5_000_000_000) {
            !model.isImportingSources
        }
        XCTAssertEqual(model.selectedItem.title, "Long Import")
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let interval: UInt64 = 10_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail("Timed out waiting for \(description).")
    }

    private func preparedTextAudio(itemId: String, title: String, text: String) -> PreparedTextAudio {
        let mediaURL = "file:///tmp/\(itemId)-full.caf"
        return PreparedTextAudio(
            normalizedText: text,
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: mediaURL,
                durationMs: 1_000,
                nativeMediaId: mediaURL
            ),
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: text.count, text: text)
                ],
                chapters: [
                    MediaTimelineChapter(id: "ch-tts-1", title: title, startMs: 0, transcriptSegmentId: "tts-1")
                ],
                durationMs: 1_000
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor PreparedTextAudioPrewarmProbe {
    struct Request: Sendable {
        var itemId: String
        var title: String
        var text: String
    }

    private var request: Request?
    private var requestContinuations: [CheckedContinuation<Request, Never>] = []
    private var preparedContinuation: CheckedContinuation<PreparedTextAudio?, Never>?

    func prepare(itemId: String, title: String, text: String) async -> PreparedTextAudio? {
        let request = Request(itemId: itemId, title: title, text: text)
        self.request = request
        for continuation in requestContinuations {
            continuation.resume(returning: request)
        }
        requestContinuations.removeAll()
        return await withCheckedContinuation { continuation in
            preparedContinuation = continuation
        }
    }

    func waitForRequest() async -> Request {
        if let request {
            return request
        }
        return await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    func complete(with prepared: PreparedTextAudio?) {
        preparedContinuation?.resume(returning: prepared)
        preparedContinuation = nil
    }
}

private final class WorkflowRecordingAudioClient: AudioPlaybackClient {
    var playedOffsets: [Int] = []
    var configuredSpeechRates: [Float] = []
    var configuredSpeechVoices: [String?] = []
    var currentOffset: Int?
    private var activeTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        configuredSpeechVoices.append(voiceIdentifier)
        configuredSpeechRates.append(rate)
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        activeTargetId = targetId
        currentOffset = charOffset
        playedOffsets.append(charOffset)
    }

    func pause() throws {}

    func currentCharOffset() -> Int? {
        currentOffset
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        guard let currentOffset else { return nil }
        return PlaybackPosition(
            targetType: .itemTextTTS,
            targetId: activeTargetId,
            textStart: currentOffset,
            textEnd: currentOffset + 1,
            anchorConfidence: .textRange
        )
    }
}
