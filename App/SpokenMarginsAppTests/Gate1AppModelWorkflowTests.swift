import AVFoundation
import Combine
import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitPersistence
@testable import SpokenMarginsApp
import SQLite3
#if canImport(UIKit)
import UIKit
import PDFKit
#endif

/// The voice and Terms defaults that building a `Gate1AppModel` and choosing a voice
/// (`declineCurrentTerms()`) write into the app's shared preferences. A test that exercises
/// those paths takes a snapshot first and restores it on teardown, so a key that was absent
/// goes back to absent and a saved choice goes back to what it was (#1448).
struct VoicePreferencesSnapshot {
    static let keys = [
        "speechRate",
        "speechVoiceIdentifier",
        "ttsVoiceSelection",
        "ttsMode",
        "piperVoiceId",
        "renderedSpeechCacheLimitMB",
        "supertonicTTSMigrationV1",
        "supertonicVoicePendingTermsV1",
        FirstRunVoiceDefault.downloadDueKey,
        SpokenMarginsTerms.acceptanceVersionKey,
        SpokenMarginsTerms.acceptanceDateKey
    ]

    private let values: [String: Any]

    static func capture(from defaults: UserDefaults = .standard) -> VoicePreferencesSnapshot {
        var values: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        return VoicePreferencesSnapshot(values: values)
    }

    func restore(to defaults: UserDefaults = .standard) {
        for key in Self.keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The keys in `keys` whose stored value differs from this snapshot, by property-list equality.
    func differingKeys(in defaults: UserDefaults = .standard) -> [String] {
        Self.keys.filter { key in
            switch (values[key], defaults.object(forKey: key)) {
            case (nil, nil): return false
            case let (saved?, current?): return !(saved as AnyObject).isEqual(current)
            default: return true
            }
        }
    }
}

private final class MainQueueDrainFlag: @unchecked Sendable { var done = false } // set and read on the main thread only

@MainActor
final class Gate1AppModelWorkflowTests: XCTestCase {
    /// Several of these tests used to leave a second or more of blocking main-queue work behind (#2195). A synchronous
    /// test never spins the run loop, so that work ran during whichever later test waited first, and could push a
    /// short wait in another class past its timeout (#2104). Draining here keeps it inside the test that queued it.
    /// A second or more is a blocked call, such as a SQLite write waiting out the store's 1 s busy timeout, so it
    /// fails the test that left it; the target is under 0.3 s, and the lane log names any test above that.
    override func setUp() {
        super.setUp()
        let inherited = Self.drainMainQueue(label: "before \(name)") // work an earlier class left behind isn't this test's
        if inherited > 0.3 { print("Main-queue backlog \(String(format: "%.2f", inherited)) s before \(name) (#2195)") }
    }

    override func tearDown() {
        let elapsed = Self.drainMainQueue(label: "after \(name)")
        if elapsed > 0.3 { print("Main-queue backlog \(String(format: "%.2f", elapsed)) s after \(name) (#2195)") }
        XCTAssertLessThan(elapsed, 1.0, "this test left a second or more of blocking main-queue work behind (#2195)")
        super.tearDown()
    }

    /// Spins the main run loop until two main-queue hops complete (at most 30 s) and returns how long that took.
    /// Past half a second it prints the main thread's stack, so the lane log shows what the backlog is.
    private static func drainMainQueue(label: String) -> TimeInterval {
        let start = Date()
        let watch = MainThreadStallWatch(label: label)
        defer { watch.finish() }
        let drained = MainQueueDrainFlag()
        DispatchQueue.main.async { DispatchQueue.main.async { drained.done = true } }
        while !drained.done, Date().timeIntervalSince(start) < 30 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return Date().timeIntervalSince(start)
    }

    func testRichClipboardRestoresOnlyExplicitHTMLHeadings() {
        let plain = "Article & notes\nA paragraph.\nNext section\nMore prose."
        let html = "<h1>Article &amp; notes</h1><p>A paragraph.</p><h2><em>Next section</em></h2><p>More prose.</p>"
        XCTAssertEqual(Gate1AppModel.pastedSourceText(plainText: plain, html: html),
                       "# Article & notes\nA paragraph.\n## Next section\nMore prose.")
        XCTAssertEqual(Gate1AppModel.pastedSourceText(plainText: plain, html: nil), plain)
    }

    /// #147: the Margins tab's per-item Share opens the Share Margins sheet directly, not the Share/Export screen.
    func testItemMarginsShareOpensTheShareSheetDirectlyWithoutChangingPlayback() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "First private thought")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Second selected thought")
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.marginRows.first { $0.preview.contains("Second selected") })
        let session = model.snapshot.sessionId
        let screen = model.screen
        model.openMarginItemExport(itemID: row.interjection.itemId)
        XCTAssertNotEqual(model.screen, .export)
        XCTAssertEqual(model.screen, screen)
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.selectedItem.id, row.interjection.itemId)
        XCTAssertEqual(model.sharingState.drafts.count, 2)
        XCTAssertEqual(model.snapshot.sessionId, session)
    }

    /// #147: when the newest session has no Margins, Share still opens the sheet with the Margins of the
    /// session that has them, as the Share/Export screen did.
    func testItemMarginsShareUsesTheSessionWithMarginsWhenTheNewestHasNone() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "A thought from the first session")
        let first = try XCTUnwrap(model.snapshot.sessionId)
        model.startNewSession(id: "item-pill")
        XCTAssertNotEqual(model.snapshot.sessionId, first)

        model.openMarginItemExport(itemID: "item-pill")

        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.sharingState.drafts.map(\.interjection.sessionId), [first])
    }

    func testItemMarginsShareSkipsANewerSessionWithOnlyResponseMargins() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "share-response-only-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "A thought from the first session")
        let first = try XCTUnwrap(model.snapshot.sessionId)
        model.startNewSession(id: "item-pill")
        let newer = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(newer, first)
        var response = shareableInterjection(itemId: "item-pill")
        response.sessionId = newer
        response.targetType = .assistantTurn
        response.targetId = "turn-1"
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveInterjection(response)
        // Both sessions are saved within the same second, so make the newer one sort first for certain.
        var newerSession = try XCTUnwrap(store.loadSession(id: newer))
        newerSession.updatedAt = Date().addingTimeInterval(60)
        try store.saveSession(newerSession)
        XCTAssertEqual(try store.loadSessions(itemId: "item-pill").first?.id, newer)

        model.openMarginItemExport(itemID: "item-pill")

        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.sharingState.drafts.map(\.interjection.sessionId), [first])
    }

    /// #147: an item with no source Margins to share says so, as the sheet does, and opens nothing.
    func testItemMarginsShareWithNoSourceMarginsExplainsInsteadOfOpeningTheSheet() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let screen = model.screen

        model.openMarginItemExport(itemID: "item-pill")

        XCTAssertFalse(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.screen, screen)
        XCTAssertEqual(model.lastError, "Record at least one Margin on this item before sharing.")
    }

    /// #1254: Settings is a tab, so every route to it (the Offline Storage back button) lands
    /// on the tab bar's home with the Settings tab requested, never on a screen of its own.
    func testEveryRouteToSettingsAsksForTheSettingsTab() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.openOfflineStorage()
        XCTAssertEqual(model.screen, .offlineStorage)
        model.returnToSettingsFromOfflineStorage()
        XCTAssertEqual(model.screen, .home)
        XCTAssertEqual(model.requestedExperienceRoot, .settings)
    }

    func testNextChapterUnavailableForFinalChapterAndDerivativePlayback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let first = Chapter(id: "a", title: "Opening", startChar: 0, endChar: 50, percent: 0)
        let last = Chapter(id: "b", title: "Ending", startChar: 50, endChar: 100, percent: 50)
        model.selectedItem = ItemDetailState(id: "item", title: "Article", chapters: [first, last])
        model.snapshot.itemId = "item"
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.chapterTitle = first.title
        XCTAssertEqual(model.nextPlaybackChapter?.id, "b")
        model.snapshot.chapterTitle = last.title
        XCTAssertFalse(model.canJumpToNextChapter)
        model.snapshot.targetType = TargetType.assistantTurnTTS.rawValue
        model.snapshot.chapterTitle = first.title
        XCTAssertFalse(model.canJumpToNextChapter)
    }

    func testUntitledManualImportUsesOpeningWordsAndPreservesHeadings() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = ""
        model.importText = "A useful opening sentence for my notes today."
        model.importTextItem(startListening: false)
        XCTAssertTrue(model.libraryItems.contains { $0.title == "A useful opening sentence for my notes today." })
        model.importTitle = "Formatted notes"
        model.importText = "**First heading**\n\nFirst paragraph.\n\n**Second heading**\n\nSecond paragraph."
        model.importTextItem()
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["First heading", "Second heading"])
    }

    func testPDFBibliographyTailNeedsExplicitHeadingAndMultipleRecords() throws {
        let body = "# Article\n\nIntroduction.\n\n## Discussion\n\nKeep this discussion.\n\n"
        let references = "## References\n" + (1...50).map { "[\($0)] Author. Journal 2024." }.joined(separator: "\n")
        let result = PDFStructuredTextExtractor.listeningMarkdown(body + references)
        XCTAssertEqual(result, body.trimmingCharacters(in: .whitespacesAndNewlines))
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Article.md", contents: result)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "pdf", policy: .canonicalHeadings))
        XCTAssertFalse(map.chapters.contains { $0.title.contains("part") || $0.title.contains("References") })
        let prose = body + "References\nWe discuss references in ordinary prose."
        XCTAssertEqual(PDFStructuredTextExtractor.listeningMarkdown(prose), prose)
    }

    func testDiagnosticUpdatesDoNotInvalidateNavigationModel() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        var modelNotifications = 0
        var diagnosticNotifications = 0
        let modelObserver = model.objectWillChange.sink { modelNotifications += 1 }
        let diagnosticObserver = model.runtimeDiagnostics.objectWillChange.sink { diagnosticNotifications += 1 }
        model.diagnostics["renderProgress"] = "1/20"
        model.diagnostics["renderProgress"] = "1/20"
        XCTAssertEqual(modelNotifications, 0)
        XCTAssertEqual(diagnosticNotifications, 1)
        withExtendedLifetime((modelObserver, diagnosticObserver)) {}
    }

    /// #2074: the progress tick used to publish through the model twice a second and re-run every screen's `body`.
    func testPlaybackTicksReachTheClockAndNotEveryScreen() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        var screenNotifications = 0
        var clockNotifications = 0
        let screenObserver = model.objectWillChange.sink { screenNotifications += 1 }
        let clockObserver = model.playbackClock.objectWillChange.sink { clockNotifications += 1 }
        var held = model.snapshot
        held.status = .paused
        held.chapterTitle = "Chapter one"
        held.preparedTextAudioStatus = "ready"
        held.sourceTranscriptStatus = "ready"
        held.currentMediaTimeMs = 1_000
        model.snapshot = held
        XCTAssertGreaterThan(screenNotifications, 0, "a change of state still reaches every screen")

        screenNotifications = 0
        clockNotifications = 0
        for ms in stride(from: 1_500, through: 5_000, by: 500) {
            held.currentMediaTimeMs = ms
            held.currentTextStart = ms / 10
            held.currentTextEnd = ms / 10 + 40
            model.snapshot = held
        }
        XCTAssertEqual(screenNotifications, 0, "a progress tick must not re-run every screen")
        XCTAssertEqual(clockNotifications, 8, "each tick still moves the playhead for the views that follow it")
        XCTAssertEqual(model.playbackClock.position.mediaTimeMs, 5_000)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 5_000)

        held.sourceProgressPercent = 7
        model.snapshot = held
        XCTAssertEqual(screenNotifications, 1, "a new whole percent reaches every screen")
        screenNotifications = 0
        held.currentMediaTimeMs = 5_500
        held.chapterTitle = "Chapter two"
        model.snapshot = held
        XCTAssertEqual(screenNotifications, 1, "a chapter change reaches every screen even as the position moves")
        screenNotifications = 0
        model.snapshot = held
        XCTAssertEqual(screenNotifications, 1, "writing the same snapshot still makes screens look again")
        withExtendedLifetime((screenObserver, clockObserver)) {}
    }

    func testDeferredHomeRefreshCannotReplaceNewerLibraryPresentation() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let readStarted = expectation(description: "navigation snapshot captured")
        let release = AsyncStream<Void>.makeStream()
        model.navigationLibraryRead = { store in
            let data = try LibraryReadSnapshot.read(store: store)
            readStarted.fulfill()
            for await _ in release.stream { break }
            return data
        }
        model.openHome()
        XCTAssertEqual(model.screen, .home)
        // Checks ordering, not speed; the seeded Library read takes ~2 s on a simulator.
        await fulfillment(of: [readStarted], timeout: 10)
        model.libraryItems = [LibraryItemRow(id: "newer-item", title: "Newer state", status: "Ready", canDelete: true)]
        release.continuation.yield(())
        release.continuation.finish()
        await model.navigationRefreshTask?.value
        XCTAssertEqual(model.libraryItems.map(\.id), ["newer-item"])
    }

    func testAutomaticPlaybackHistorySurvivesRestartAndIgnoresSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("events.json")
        let recorder = DeveloperDiagnosticRecording(limit: 4, fileURL: url, automatic: true)
        recorder.record("transport.request", ["command": "skipForward", "mediaTimeMs": "1200000"])
        for _ in 0..<1500 { recorder.record("sample", ["textOffset": "0"]) }
        XCTAssertEqual(recorder.events.count, 2)
        await recorder.flush()
        let restored = DeveloperDiagnosticRecording(limit: 4, fileURL: url, automatic: true)
        XCTAssertEqual(restored.events.count, 3)
        XCTAssertEqual(restored.events[1].fields["command"], "skipForward")
        restored.record("seek.media.result", ["outcome": "accepted:1260000"])
        restored.record("playback.state", ["status": "paused"])
        XCTAssertEqual(restored.events.count, 4)
        XCTAssertEqual(restored.events.first?.kind, "transport.request")
        await restored.flush()
        let saved = try JSONDecoder().decode(DeveloperDiagnosticRecording.Capture.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.events.last?.fields["status"], "paused")
    }

    func testDeveloperRecordingIsOptInBoundedAndStops() throws {
        let recorder = DeveloperDiagnosticRecording(limit: 4)
        recorder.record("ignored")
        XCTAssertTrue(recorder.events.isEmpty)
        recorder.start()
        for index in 0..<10 { recorder.record("sample", ["offset": String(index)]) }
        XCTAssertEqual(recorder.events.count, 4)
        XCTAssertEqual(recorder.events.first?.fields["offset"], "6")
        recorder.stop()
        let saved = recorder.exportJSON()
        let stoppedCount = recorder.events.count
        recorder.record("ignored.after.stop")
        XCTAssertEqual(recorder.events.count, stoppedCount)
        let data = try XCTUnwrap(saved?.data(using: .utf8))
        let capture = try JSONDecoder().decode(DeveloperDiagnosticRecording.Capture.self, from: data)
        XCTAssertEqual(capture.schemaVersion, "spoken-margins.developer-recording.v1")
        XCTAssertEqual(capture.events.last?.kind, "recording.stopped")
        XCTAssertEqual(DeveloperDiagnosticRecording.token("private article URL"), DeveloperDiagnosticRecording.token("private article URL"))
        XCTAssertFalse(DeveloperDiagnosticRecording.token("private article URL").contains("private"))
        recorder.start()
        XCTAssertEqual(recorder.events.count, 1)
    }

    func testDiagnosticsExportFileCarriesSafePayload() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.diagnostics = [
            "runtimeProfile": "test-profile",
            "lastBrowserTextSource": "private source content"
        ]
        for _ in 0..<400 {
            model.recordDeveloperDiagnostic("scrub.media.display", ["canonical": "100"])
            model.recordDeveloperDiagnostic("sample", ["textOffset": "0"])
        }
        model.recordDeveloperDiagnostic("transport.request", ["command": "skipForward", "origin": "now_playing"])
        let file = try XCTUnwrap(model.diagnosticsExportFileURL())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(file.pathExtension, "json")
        XCTAssertTrue(file.lastPathComponent.hasPrefix("Spoken Margins diagnostics "))
        let text = try String(contentsOf: file, encoding: .utf8)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(payload["schemaVersion"], "spoken-margins.diagnostics.v1")
        XCTAssertEqual(payload["runtimeProfile"], "test-profile")
        XCTAssertNil(payload["lastBrowserTextSource"])
        XCTAssertFalse(text.contains("private source content"))
        let eventJSON = try XCTUnwrap(payload["playbackEvents"]?.data(using: .utf8))
        let events = try JSONDecoder().decode(DeveloperDiagnosticRecording.Capture.self, from: eventJSON).events
        XCTAssertFalse(events.contains { $0.kind == "sample" || $0.kind.hasPrefix("scrub.") })
        XCTAssertEqual(events.last?.fields["origin"], "now_playing")
        XCTAssertNotEqual(model.feedbackEvent?.kind, .error)
    }

    /// #2224: the export carries the voice download log from its file, so a download from an earlier launch shows.
    func testDiagnosticsExportCarriesTheVoiceDownloadLogFromItsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-log-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logFile = VoiceDownloadLog.fileURL(stateFolder: folder)
        VoiceDownloadLog(fileURL: logFile).record("install.finished", ["voice": "supertonic-3", "bytesOnDisk": "1234"])
        let fixed = DiagnosticsExport.Fixed(
            developerBuild: "test", developerRecording: nil, playbackEvents: nil, exportedAt: Date(),
            playbackStatus: "idle", sessionPhase: "idle", targetType: nil, pendingAIJobs: 0
        )

        let withLog = try DiagnosticsExportInputs(live: [:], store: nil, fixed: fixed, voiceDownloadLogFile: logFile).writeFile()
        defer { try? FileManager.default.removeItem(at: withLog) }
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: withLog)) as? [String: String])
        let log = try XCTUnwrap(payload["voiceDownloads"])
        XCTAssertTrue(log.contains("install.finished"))
        XCTAssertTrue(log.contains("\"bytesOnDisk\":\"1234\""))

        let withoutLog = try DiagnosticsExportInputs(live: [:], store: nil, fixed: fixed, voiceDownloadLogFile: folder.appendingPathComponent("none.json")).writeFile()
        defer { try? FileManager.default.removeItem(at: withoutLog) }
        let bare = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: withoutLog)) as? [String: String])
        XCTAssertNil(bare["voiceDownloads"], "no log, no key")
    }

    /// #1191: Share Diagnostics builds the file off the main actor so the button can show a spinner. The file
    /// carries the same safe payload as the synchronous export.
    func testPrepareDiagnosticsExportFileURLBuildsTheSafeFile() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.diagnostics = [
            "runtimeProfile": "test-profile",
            "lastBrowserTextSource": "private source content"
        ]
        let exported = await model.prepareDiagnosticsExportFileURL()
        let file = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(payload["schemaVersion"], "spoken-margins.diagnostics.v1")
        XCTAssertEqual(payload["runtimeProfile"], "test-profile")
        XCTAssertNil(payload["lastBrowserTextSource"])
        XCTAssertNotEqual(model.feedbackEvent?.kind, .error)
    }

    /// #1109 (Codex audit): every switch to the iOS voice records its own event, the memory-warning stop
    /// included, with the reason shown to the listener and what the resource policy reads.
    func testFallbackEventCarriesTheReasonAndWhatThePolicyReads() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.recordSupertonicFallbackEvent(
            code: "memory_warning_stop",
            reason: .memoryWarning,
            conditions: SpeechEngineConditions(isRecoveringFromMemoryWarning: true),
            offset: 8_344
        )
        let fallback = try lastFallbackEventFields(of: model)
        XCTAssertEqual(fallback["code"], "memory_warning_stop")
        XCTAssertEqual(fallback["reason"], "memory_warning")
        XCTAssertEqual(fallback["policyBlock"], "memory_warning")
        XCTAssertEqual(fallback["offset"], "8344")
        XCTAssertTrue(fallback["conditions"]?.contains("memoryBackoff=true") == true)
    }

    /// The fields of the newest `supertonic.fallback` event in the model's diagnostics export.
    private func lastFallbackEventFields(of model: Gate1AppModel) throws -> [String: String] {
        let file = try XCTUnwrap(model.diagnosticsExportFileURL())
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        let eventJSON = try XCTUnwrap(payload["playbackEvents"]?.data(using: .utf8))
        let events = try JSONDecoder().decode(DeveloperDiagnosticRecording.Capture.self, from: eventJSON).events
        return try XCTUnwrap(events.last { $0.kind == "supertonic.fallback" }).fields
    }

    func testLibraryAudioIconUsesPlaybackRepresentationRatherThanFileExtension() {
        for type in ["text", "pdf", "epub", "mp4", "podcast", "audiobook"] {
            let row = LibraryItemRow(id: type, title: type, status: "ready", canDelete: true, mediaType: type, hasNativeAudio: true)
            XCTAssertEqual(row.mediaSymbol, "headphones")
        }
        XCTAssertEqual(LibraryItemRow(id: "text", title: "Text", status: "ready", canDelete: true).mediaSymbol, "doc.text")
    }

    func testSkimSeparatesNaturalSynthesisFromListeningSpeed() {
        XCTAssertEqual(SummaryBridgeRatePolicy.synthesisSpeed, 1)
        XCTAssertEqual(SummaryBridgeRatePolicy.systemSynthesisRate, 0.5)
        XCTAssertEqual(SummaryBridgeRatePolicy.transportRate(1.75), 1.75)
        XCTAssertEqual(SummaryBridgeRatePolicy.transportRate(0.75), 0.75)
    }

    func testCompletedSessionExportUsesItsMarginsDespiteNewEmptySession() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let store = try SQLiteSessionStore(path: url.path)
        let originalID = try XCTUnwrap(model.snapshot.sessionId)
        model.endSession()
        var original = try XCTUnwrap(store.loadSession(id: originalID))
        original.status = "finished"
        original.phase = .finished
        original.completionPercent = 100
        try store.saveSession(original)
        for index in 0..<2 {
            var note = shareableInterjection(itemId: "item-pill")
            note.id = "old-note-\(index)"
            note.sessionId = originalID
            note.targetId = "item-pill"
            try store.saveInterjection(note)
        }
        model.startNewSession(id: "item-pill")
        let newSession = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(newSession, originalID)
        model.openExport(sessionId: originalID)
        XCTAssertEqual(model.exportShareCandidates.count, 2)
        model.prepareExportShareInterjections()
        XCTAssertEqual(model.sharingState.drafts.count, 2)
        XCTAssertTrue(model.sharingState.drafts.allSatisfy { $0.interjection.sessionId == originalID })
        XCTAssertEqual(model.snapshot.sessionId, newSession)
        XCTAssertEqual(try store.loadSession(id: originalID)?.completionPercent, 100)
        model.openExport(sessionId: newSession)
        XCTAssertTrue(model.exportShareCandidates.isEmpty)
    }

    /// #1043 APM-12: the Margins tab's "export this item" was tested with one session, so any pick of session
    /// passed. After "play again" the newest session is empty; the export must still open the session that
    /// holds the Margins.
    func testItemMarginsExportUsesTheSessionWithMarginsWhenTheNewestHasNone() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "item-export-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "First private thought")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Second selected thought")
        let withMargins = try XCTUnwrap(model.snapshot.sessionId)
        model.startNewSession(id: "item-pill")
        let newest = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(newest, withMargins)
        // Both sessions are saved within the same second, so make the empty one sort first for certain.
        let store = try SQLiteSessionStore(path: databaseURL.path)
        var newer = try XCTUnwrap(store.loadSession(id: newest))
        newer.updatedAt = Date().addingTimeInterval(60)
        try store.saveSession(newer)
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.marginRows.first { $0.preview.contains("Second selected") })
        XCTAssertEqual(try store.loadSessions(itemId: "item-pill").first?.id, newest, "the newest session has no Margins")

        let screen = model.screen
        model.openMarginItemExport(itemID: row.interjection.itemId)

        // #147: Share opens the Share Margins sheet directly, not the Share/Export screen.
        XCTAssertEqual(model.screen, screen)
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.exportSessionId, withMargins)
        XCTAssertEqual(model.sharingState.drafts.count, 2)
        XCTAssertTrue(model.sharingState.drafts.allSatisfy { $0.interjection.sessionId == withMargins })
        XCTAssertEqual(model.snapshot.sessionId, newest, "opening the share sheet leaves the playing session alone")
    }

    func testChapterFromCompletedSessionStartsReplayWithoutChangingCompletedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let store = try SQLiteSessionStore(path: url.path)
        let id = try XCTUnwrap(model.snapshot.sessionId)
        model.endSession()
        var session = try XCTUnwrap(store.loadSession(id: id))
        session.status = "finished"
        session.phase = .finished
        session.completionPercent = 100
        try store.saveSession(session)
        model.openSession(session)
        let chapter = try XCTUnwrap(model.selectedItem.chapters.dropFirst().first)
        model.jumpToChapter(chapter, fromTimeline: true)
        XCTAssertNotEqual(model.snapshot.sessionId, id)
        XCTAssertEqual(model.snapshot.chapterTitle, chapter.title)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(try store.loadSession(id: id)?.completionPercent, 100)
    }

    func testMixedAudioIsExplicitPerSessionAndRestoresDefaultSystemOwnership() {
        let defaults = UserDefaults.standard
        let priorAvailability = defaults.object(forKey: "showsMixWithOtherAudioOption")
        let priorVolume = defaults.object(forKey: "mixedPlaybackVolume")
        defer {
            if let priorAvailability {
                defaults.set(priorAvailability, forKey: "showsMixWithOtherAudioOption")
            } else {
                defaults.removeObject(forKey: "showsMixWithOtherAudioOption")
            }
            if let priorVolume {
                defaults.set(priorVolume, forKey: "mixedPlaybackVolume")
            } else {
                defaults.removeObject(forKey: "mixedPlaybackVolume")
            }
        }
        defaults.set(2.0, forKey: "mixedPlaybackVolume")
        let audio = MixedAudioPolicyRecordingClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.showsMixWithOtherAudioOption = true
        model.mixWithOtherAudioAvailabilityChanged()
        model.startItem(id: "item-pill")

        XCTAssertFalse(model.mixesWithOtherAudio)
        XCTAssertFalse(model.lowersBackgroundAudio)
        XCTAssertEqual(model.mixedPlaybackVolume, 1)
        model.setLowersBackgroundAudio(true)
        XCTAssertFalse(model.lowersBackgroundAudio)

        model.setMixesWithOtherAudio(true)
        XCTAssertFalse(model.lowersBackgroundAudio)
        model.setLowersBackgroundAudio(true)
        XCTAssertTrue(model.lowersBackgroundAudio)
        XCTAssertEqual(audio.backgroundAudioStates.last, true)
        model.mixedPlaybackVolume = 0.35
        model.mixedPlaybackVolumeChanged()

        XCTAssertTrue(model.mixesWithOtherAudio)
        XCTAssertEqual(audio.mixingStates.last, true)
        XCTAssertEqual(audio.playbackVolumes.last ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(audio.remoteCommandHandlingStates.last, false)

        model.mixedPlaybackVolume = 1.5
        model.mixedPlaybackVolumeChanged()

        XCTAssertEqual(audio.playbackVolumes.last ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(model.lowersBackgroundAudio)
        model.setLowersBackgroundAudio(false)
        XCTAssertEqual(audio.backgroundAudioStates.last, false)
        XCTAssertTrue(model.mixesWithOtherAudio)
        model.setLowersBackgroundAudio(true)

        model.endSession()

        XCTAssertFalse(model.mixesWithOtherAudio)
        XCTAssertEqual(audio.mixingStates.last, false)
        XCTAssertFalse(model.lowersBackgroundAudio)
        XCTAssertEqual(audio.backgroundAudioStates.last, false)
        XCTAssertEqual(audio.playbackVolumes.last, 1)
        XCTAssertEqual(audio.remoteCommandHandlingStates.last, true)
    }

    func testStartingAStreamedOnlyEpisodeWithNoSignalSaysItIsNotDownloaded() throws {
        // #779: offline, this used to try, stall for 30 s, then blame saved audio that didn't exist.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "offline-stream-start-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let item = Item(
            id: "episode-streamed-only",
            title: "Streamed Only Episode",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/streamed-only",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/streamed-only.mp3",
                durationMs: 900_000
            )
        )
        try store.saveItem(item)
        model.connectivity.update(transport: .unavailable, isOffline: true)

        model.startNewSession(id: item.id)

        XCTAssertEqual(model.lastError, "This episode isn't downloaded, and there's no signal.")
        XCTAssertNotEqual(model.snapshot.itemId, item.id, "nothing tries to stream it")

        // With signal back, the same episode is no longer stopped by the check.
        model.connectivity.update(transport: .wifi, isOffline: false)
        model.lastError = nil
        model.startNewSession(id: item.id)
        XCTAssertNotEqual(model.lastError, OfflinePlayability.episodeNotDownloadedMessage)
    }

    func testResolvedPrivateListeningMapIsLoadedAsVisibleNavigableScenes() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "visible-private-map-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let item = Item(
            id: "episode-visible-map",
            title: "Visible Episode Map",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/visible-map",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: "https://cdn.example.com/visible-map.mp3",
                durationMs: 900_000
            )
        )
        try store.saveItem(item)
        let proposal = PortableListeningMapProposalArtifact(
            id: "proposal-visible-map",
            createdAt: Date(timeIntervalSince1970: 1),
            generator: "deterministic-scene-boundaries.v1",
            scenes: [
                PortableListeningMapScene(
                    id: "scene-opening",
                    order: 0,
                    title: "Opening argument",
                    summaryText: "The guest frames the central question.",
                    eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: 0, transcriptSegmentId: "segment-1"),
                    endAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: 300_000, transcriptSegmentId: "segment-2")
                ),
                PortableListeningMapScene(
                    id: "scene-evidence",
                    order: 1,
                    title: "Evidence",
                    eligibility: .unknown,
                    startAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: 300_000, transcriptSegmentId: "segment-2"),
                    endAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: 600_000, transcriptSegmentId: "segment-3")
                )
            ]
        )
        try store.savePortableListeningMapProposal(proposal, itemId: item.id)
        try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
            id: "projection-visible-map",
            itemId: item.id,
            proposalId: proposal.id,
            recipientEditionSHA256: "exact-edition",
            points: [
                ResolvedListeningMapPoint(
                    id: "point-1",
                    sourceMediaTimeMs: 60_000,
                    recipientMediaTimeMs: 60_000,
                    confidence: .exactEdition,
                    evidenceIds: ["exact-edition"]
                ),
                ResolvedListeningMapPoint(
                    id: "point-2",
                    sourceMediaTimeMs: 360_000,
                    recipientMediaTimeMs: 360_000,
                    confidence: .exactEdition,
                    evidenceIds: ["exact-edition"]
                )
            ],
            intervals: []
        ))

        model.openItem(id: item.id)

        XCTAssertEqual(model.selectedItem.listeningMapScenes.map(\.title), ["Opening argument", "Evidence"])
        XCTAssertEqual(model.selectedItem.listeningMapScenes.map(\.startMs), [0, 300_000])
        XCTAssertEqual(model.selectedItem.listeningMapScenes.first?.description, "The guest frames the central question.")
        // Podcast Now (#1629): the stored map reaches the view as spans; the unknown-eligibility scene shows nothing.
        let spans = model.selectedItem.listeningMapSummarySpans
        XCTAssertEqual(SceneSummarySelector.summary(at: 299_999, in: spans), "The guest frames the central question.")
        XCTAssertNil(SceneSummarySelector.summary(at: 300_000, in: spans))
        XCTAssertFalse(model.canGenerateListeningMap)
        XCTAssertTrue(model.listeningMapGenerationAvailabilityDescription.contains("2 scenes"))
    }

    func testTimedSleepTimerUsesWallClockAndStaysArmedWhilePaused() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.snapshot.status = .paused
        model.armSleepTimer(.minutes15)
        guard case .armed(let mode, let deadline?, _) = model.sleepTimerState else {
            return XCTFail("Expected armed sleep timer")
        }
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(-60))
        XCTAssertEqual(mode, .minutes15)
        XCTAssertEqual(model.sleepTimerRemainingSeconds, 60)
        XCTAssertTrue(model.sleepTimerIsActive)
        model.cancelSleepTimer()
    }

    /// #1043 APM-05: the expiry tests ran with nothing playing, so the pause the timer exists for never ran.
    func testTimedSleepTimerExpiryPausesThePlayingSource() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.snapshot.status.isPlaybackActive)
        XCTAssertTrue(audio.isPlaying)
        model.armSleepTimer(.minutes15)
        defer { model.cancelSleepTimer() }
        guard case .armed(_, let deadline?, _) = model.sleepTimerState else {
            return XCTFail("Expected armed sleep timer")
        }

        model.reconcileSleepTimer(now: deadline.addingTimeInterval(-1))
        XCTAssertTrue(audio.isPlaying, "nothing pauses before the deadline")

        model.reconcileSleepTimer(now: deadline.addingTimeInterval(1))
        XCTAssertEqual(model.sleepTimerState, .inactive)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertFalse(audio.isPlaying, "the timer said it paused playback, so the player must have stopped")
    }

    /// #1979: the timer fades what is playing over its last ten seconds, and the next play is not silent.
    func testSleepTimerFadesTheVolumeAndBringsItBackAfterThePauseOrAnExtension() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.snapshot.status.isPlaybackActive)
        model.armSleepTimer(.minutes15)
        defer { model.cancelSleepTimer() }
        guard case .armed(_, let deadline?, _) = model.sleepTimerState else {
            return XCTFail("Expected armed sleep timer")
        }
        let before = audio.playbackVolumes.count

        model.reconcileSleepTimer(now: deadline.addingTimeInterval(-30))
        XCTAssertEqual(audio.playbackVolumes.count, before, "the warning minute changes no volume")

        model.reconcileSleepTimer(now: deadline.addingTimeInterval(-5))
        XCTAssertEqual(audio.playbackVolumes.last, 0.5)
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(-2))
        XCTAssertEqual(audio.playbackVolumes.last ?? 1, 0.2, accuracy: 0.001)

        model.extendSleepTimerBy15Minutes()
        XCTAssertEqual(audio.playbackVolumes.last, 1, "extending mid-fade brings the volume back")
        XCTAssertTrue(audio.isPlaying)

        guard case .armed(_, let extended?, _) = model.sleepTimerState else {
            return XCTFail("Expected armed sleep timer")
        }
        model.reconcileSleepTimer(now: extended.addingTimeInterval(-1))
        XCTAssertEqual(audio.playbackVolumes.last ?? 1, 0.1, accuracy: 0.001)
        model.reconcileSleepTimer(now: extended.addingTimeInterval(1))
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.playbackVolumes.last, 1, "the next time the listener plays it is at full volume")
    }

    func testSleepTimerExpiryDefersThroughInterjectionRecording() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "the source must be playing before recording defers expiry")
        model.armSleepTimer(.minutes15)
        defer { model.cancelSleepTimer() }
        guard case .armed(_, let deadline?, _) = model.sleepTimerState else {
            return XCTFail("Expected armed sleep timer")
        }
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(1))
        XCTAssertEqual(model.sleepTimerState, .expiryDeferred(mode: .minutes15))
        XCTAssertTrue(model.snapshot.isRecording, "the timer never cuts a Margin off")

        model.finishInterjection()
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(audio.isPlaying, "the source plays on after the Margin is saved")
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(2))
        XCTAssertEqual(model.sleepTimerState, .inactive)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertFalse(audio.isPlaying, "the deferred expiry pauses the source once the Margin is saved")
    }

    func testEndOfChapterSleepTimerIsUnavailableForMaplessAndLastChapterPositions() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        XCTAssertFalse(model.canUseEndOfChapterSleepTimer)
        model.selectedItem = ItemDetailState(
            id: "audio",
            title: "Audio",
            mediaChapters: [
                MediaTimelineChapter(id: "one", title: "One", startMs: 0, transcriptSegmentId: "one"),
                MediaTimelineChapter(id: "two", title: "Two", startMs: 10_000, transcriptSegmentId: "two")
            ]
        )
        model.snapshot.currentMediaTimeMs = 1_000
        XCTAssertTrue(model.canUseEndOfChapterSleepTimer)
        model.snapshot.currentMediaTimeMs = 10_000
        XCTAssertFalse(model.canUseEndOfChapterSleepTimer)
    }

    func testImportedCommentaryPlaybackAcceptsVerifiedTextAndPodcastAnchors() {
        XCTAssertTrue(Gate1AppModel.isPlayableImportedCommentaryResolution(
            ImportedAnchorResolution(
                evidenceClass: .articleTextVerified,
                localStartChar: 120,
                localEndChar: 145
            )
        ))
        XCTAssertTrue(Gate1AppModel.isPlayableImportedCommentaryResolution(
            ImportedAnchorResolution(
                evidenceClass: .transcriptVerified,
                localMediaTimeMs: 45_000
            )
        ))
        XCTAssertFalse(Gate1AppModel.isPlayableImportedCommentaryResolution(
            ImportedAnchorResolution(
                evidenceClass: .articleTextVerified,
                localStartChar: 120,
                isAmbiguous: true
            )
        ))
        XCTAssertFalse(Gate1AppModel.isPlayableImportedCommentaryResolution(
            ImportedAnchorResolution(evidenceClass: .unresolved)
        ))
    }

    /// #872: the Hollywood packet's Margins carry only the sender's clock time. After a placement pass has run and
    /// left them unplaced, the Timeline row says that, not "Couldn't place this one", which reads as a match that
    /// failed. Before any pass has run, a freshly imported podcast layer (`.contextOnly`, no file digest) says
    /// "Not placed yet" for every unplaced Margin, bare or fingerprinted: a pass may still place it.
    func testSharedMarginRowSaysUnresolvedWordingOnlyAfterAPassLeftTheMarginUnplaced() {
        func layer(passDigest: String?) -> ImportedCommentaryLayer {
            ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
                itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Hollywood Was Cooked"),
                importedAt: Date(), sourceResolutionStatus: .contextOnly, isEnabled: true,
                resolvedRecipientEditionSHA256: passDigest)
        }
        func row(_ anchor: PortableAnchorEvidence, in layer: ImportedCommentaryLayer) -> SharedMarginRow {
            SharedMarginRow(interjection: ImportedCommentaryInterjection(id: "note", layerId: layer.id,
                packageScopedId: "note", createdAt: Date(), anchorEvidence: anchor, approvedTranscript: "Words",
                resolution: ImportedAnchorResolution(evidenceClass: .unresolved)), layer: layer, itemTitle: "Hollywood")
        }
        let bareAnchor = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 134_000, roughPercent: 4)
        let fingerprintedAnchor = PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 134_000, machineEvidenceAssetIds: ["pre"])
        let afterPass = layer(passDigest: String(repeating: "a", count: 64))
        let beforePass = layer(passDigest: nil)

        let bare = row(bareAnchor, in: afterPass)
        XCTAssertEqual(bare.placementStatus, .noPositionSent)
        XCTAssertEqual(bare.positionDescription, "Sent without a position")
        let fingerprinted = row(fingerprintedAnchor, in: afterPass)
        XCTAssertEqual(fingerprinted.placementStatus, .settled)
        XCTAssertEqual(fingerprinted.positionDescription, SharedMarginPlacementWording.couldntPlace)

        // The state a packet is in right after import into a podcast whose download hasn't finished.
        for anchor in [bareAnchor, fingerprintedAnchor] {
            let imported = row(anchor, in: beforePass)
            XCTAssertEqual(imported.placementStatus, .notPlacedYet)
            XCTAssertEqual(imported.positionDescription, "Not placed yet")
        }
    }

    func testLinklessTextSharingOffersPrivateRightsOrRecipientSuppliedTransport() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Private draft"
        model.importText = "A linkless item that can travel with its Margins when the sender confirms rights."
        model.importTextItem()
        model.selectedItem.interjections = [shareableInterjection(itemId: model.selectedItem.id)]

        model.prepareShareInterjections()

        XCTAssertNil(model.sharingState.itemReferenceURL)
        XCTAssertTrue(model.sharingState.canEmbedLinklessItem)
        XCTAssertFalse(model.sharingState.isAppAuthoredItem)
        XCTAssertFalse(model.sharingState.confirmsPrivateSharingRights)
        XCTAssertEqual(model.sharingState.drafts.count, 1)
    }

    func testShareWordDeletionSupportsUndoAndRedoWithoutAllowingInsertedText() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Editable Margin item"
        model.importText = "An item used to review a Margin."
        model.importTextItem()
        let margin = shareableInterjection(itemId: model.selectedItem.id)
        model.selectedItem.interjections = [margin]
        model.prepareShareInterjections()
        let draft = try XCTUnwrap(model.sharingState.drafts.first)

        model.toggleShareDraftWord(draftID: draft.id, segmentID: "word-remove")
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
        XCTAssertTrue(model.sharingState.drafts[0].canUndoEdit)

        model.undoShareDraftEdit(draft.id)
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep unnecessary words.")
        XCTAssertTrue(model.sharingState.drafts[0].canRedoEdit)

        model.redoShareDraftEdit(draft.id)
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
    }

    func testTimelineShareCurationPersistsAndCreatesAStarredSenderShortlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "share-curation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.startItem(id: itemID)
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let ids = ["margin-first", "margin-starred", "margin-last"]
        for id in ids {
            var margin = shareableInterjection(itemId: itemID)
            margin.id = id
            margin.sessionId = sessionID
            try store.saveInterjection(margin)
        }
        model.openItem(id: itemID)

        model.setInterjectionStarredForSharing("margin-starred", starred: true)
        model.setInterjectionPrivateSharingNote(
            "margin-starred",
            note: String(repeating: "n", count: Gate1AppModel.privateSharingNoteCharacterLimit + 25)
        )

        let reopened = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        reopened.bootstrapLibraryIfNeeded()
        reopened.openItem(id: itemID)
        let curated = try XCTUnwrap(reopened.selectedItem.interjections.first(where: { $0.id == "margin-starred" }))
        XCTAssertEqual(curated.isStarredForSharing, true)
        XCTAssertEqual(curated.privateSharingNote?.count, Gate1AppModel.privateSharingNoteCharacterLimit)

        reopened.prepareShareInterjections()

        XCTAssertEqual(reopened.sharingState.draftFilter, .starred)
        XCTAssertEqual(reopened.sharingState.drafts.filter(\.isIncluded).map(\.id), ["margin-starred"])
        XCTAssertEqual(InterjectionSharingView.collapsedTranscriptLineLimit, 10)
        XCTAssertFalse(InterjectionSharingView.transcriptRequiresExpansion(fullHeight: 220, limitedHeight: 220))
        XCTAssertTrue(InterjectionSharingView.transcriptRequiresExpansion(fullHeight: 440, limitedHeight: 220))

        reopened.setInterjectionStarredForSharing("margin-starred", starred: false)
        reopened.prepareShareInterjections()
        XCTAssertEqual(reopened.sharingState.draftFilter, .all)
        XCTAssertTrue(reopened.sharingState.drafts.allSatisfy(\.isIncluded))
    }

    func testBulkSharePreparationProcessesFiftyThreeMarginsSequentiallyAndPreservesOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "bulk-margin-preparation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appending(path: "private-original.m4a")
        let originalBytes = Data([0x53, 0x4D, 0x01, 0x35])
        try originalBytes.write(to: originalURL)
        // The model writes cleaned copies under the real Application Support; remove every folder this test adds.
        let shareRevisions = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "SpokenMargins/ShareRevisions", directoryHint: .isDirectory)
        let revisionsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: shareRevisions.path)) ?? [])
        defer {
            let after = (try? FileManager.default.contentsOfDirectory(atPath: shareRevisions.path)) ?? []
            for name in after where !revisionsBefore.contains(name) {
                try? FileManager.default.removeItem(at: shareRevisions.appending(path: name))
            }
        }
        let probe = BulkSharePreparationProbe()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] },
            shareMarginAudioCleanupHandler: { sourceURL, destinationURL, decisions in
                try await probe.render(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    decisions: decisions
                )
            }
        )
        model.resetAndSeed()
        model.importTitle = "Bulk preparation"
        model.importText = "An item with many Margins."
        model.importTextItem()
        model.selectedItem.interjections = (0..<53).map { index in
            bulkShareableInterjection(
                itemId: model.selectedItem.id,
                id: "margin-bulk-\(index)",
                audioPath: originalURL.path
            )
        }
        model.prepareShareInterjections()

        XCTAssertEqual(model.bulkSharePreparationEligibleCount, 53)
        model.prepareAllIncludedShareDrafts()
        try await waitFor("53 Margins to finish bulk preparation", timeoutNanoseconds: 5_000_000_000) {
            !model.sharingState.isBulkPreparing
        }

        let probeSnapshot = await probe.snapshot()
        XCTAssertEqual(probeSnapshot.renderCount, 53)
        XCTAssertEqual(probeSnapshot.maximumConcurrentRenders, 1)
        XCTAssertEqual(model.sharingState.bulkPreparationCompleted, 53)
        XCTAssertEqual(model.sharingState.bulkPreparationFailureCount, 0)
        XCTAssertEqual(model.bulkSharePreparationEligibleCount, 0)
        XCTAssertTrue(model.sharingState.drafts.allSatisfy {
            $0.currentEditState.automaticCleanupEnabled
                && $0.representationChoice == .cleaned
                && $0.approvedTranscript == "Keep words."
        })
        let cleanedURLs = model.sharingState.drafts.compactMap(\.cleanedAudioURL)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes, "the owner's recording is untouched")
        XCTAssertEqual(cleanedURLs.count, 53)
        XCTAssertEqual(Set(cleanedURLs.map(\.standardizedFileURL.path)).count, 53, "each Margin gets its own cleaned copy")
        for url in cleanedURLs {
            XCTAssertNotEqual(url.standardizedFileURL.path, originalURL.standardizedFileURL.path)
            XCTAssertNotEqual(url.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
            XCTAssertEqual(try Data(contentsOf: url), BulkSharePreparationProbe.cleanedBytes)
        }

        let firstID = try XCTUnwrap(model.sharingState.drafts.first?.id)
        model.undoShareDraftEdit(firstID)
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep um words.")
        model.redoShareDraftEdit(firstID)
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
        // Redo renders the cleaned copy again in the background; let it land before the folder cleanup runs.
        try await waitFor("the redo render to finish", timeoutNanoseconds: 5_000_000_000) {
            !model.sharingState.drafts[0].isPreparingCleanup
        }
    }

    func testTurningOffAutomaticCleanupRestoresAutomaticallyCleanedDrafts() async throws {
        let defaults = UserDefaults.standard
        let priorDecision = defaults.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        let priorEnabled = defaults.object(forKey: ShareAutoCleanPreference.enabledKey)
        defer {
            restoreUserDefault(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey)
            restoreUserDefault(priorEnabled, forKey: ShareAutoCleanPreference.enabledKey)
        }
        defaults.removeObject(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        defaults.removeObject(forKey: ShareAutoCleanPreference.enabledKey)

        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] }
        )
        model.resetAndSeed()
        model.importTitle = "Automatic cleanup preference"
        model.importText = "An item with one Margin."
        model.importTextItem()
        model.selectedItem.interjections = [bulkShareableInterjection(
            itemId: model.selectedItem.id,
            id: "margin-auto-clean-toggle",
            audioPath: "/missing-auto-clean-toggle.m4a"
        )]
        model.prepareShareInterjections()

        model.setShareAutoCleanSelectedEnabled(true)
        try await waitFor("automatic cleanup to finish") {
            !model.sharingState.isBulkPreparing
        }
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
        XCTAssertTrue(model.sharingState.drafts[0].currentEditState.automaticCleanupEnabled)

        model.setShareAutoCleanSelectedEnabled(false)

        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep um words.")
        XCTAssertFalse(model.sharingState.drafts[0].currentEditState.automaticCleanupEnabled)
        XCTAssertTrue(model.sharingState.automaticallyCleanedDraftIDs.isEmpty)

        model.prepareCleanup(forShareDraft: "margin-auto-clean-toggle")
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
        XCTAssertTrue(model.sharingState.automaticallyCleanedDraftIDs.isEmpty)

        model.setShareAutoCleanSelectedEnabled(true)
        model.setShareAutoCleanSelectedEnabled(false)

        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
        XCTAssertTrue(model.sharingState.drafts[0].currentEditState.automaticCleanupEnabled)
    }

    func testMarginPlaybackRateMatchesItemRateAndClampsInvalidValues() {
        XCTAssertEqual(Gate1AppModel.marginPlaybackRate(itemPlaybackRate: 1.75), 1.75)
        XCTAssertEqual(Gate1AppModel.marginPlaybackRate(itemPlaybackRate: 4), 3)
        XCTAssertEqual(Gate1AppModel.marginPlaybackRate(itemPlaybackRate: 0.1), 0.25)
        XCTAssertEqual(Gate1AppModel.marginPlaybackRate(itemPlaybackRate: .nan), 1)
    }

    /// #1043 APM-08: the test asserted straight after Cancel, so the render still in flight never came back, and
    /// the guard that stops a stale render writing onto the cancelled draft never ran. Here the render ignores the
    /// cancel (as an export already under way does), finishes afterwards and writes its file. The draft must stay
    /// as Cancel left it, and the stale cleaned copy must be deleted.
    func testCancellingBulkSharePreparationMakesInFlightMarginEligibleAgain() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appending(path: "bulk-margin-cancel-\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let render = HeldCleanupRender()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] },
            shareMarginAudioCleanupHandler: { _, destinationURL, _ in
                try await render.render(destinationURL: destinationURL)
            }
        )
        model.resetAndSeed()
        model.importTitle = "Bulk cancellation"
        model.importText = "An item with one Margin."
        model.importTextItem()
        model.selectedItem.interjections = [bulkShareableInterjection(
            itemId: model.selectedItem.id,
            id: "margin-cancel",
            audioPath: sourceURL.path
        )]
        model.prepareShareInterjections()
        model.prepareAllIncludedShareDrafts()
        try await waitFor("bulk render to begin") {
            model.sharingState.drafts.first?.isPreparingCleanup == true
        }
        var heldDestination: URL?
        for _ in 0..<200 where heldDestination == nil {
            heldDestination = await render.heldDestination
            if heldDestination == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let destination = try XCTUnwrap(heldDestination, "the renderer was handed its destination")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        model.cancelBulkSharePreparation()

        XCTAssertFalse(model.sharingState.isBulkPreparing)
        XCTAssertEqual(model.sharingState.bulkPreparationCompleted, 0)
        XCTAssertEqual(model.bulkSharePreparationEligibleCount, 1)
        let cancelled = try XCTUnwrap(model.sharingState.drafts.first)
        XCTAssertFalse(cancelled.currentEditState.automaticCleanupEnabled)
        XCTAssertNil(cancelled.cleanup)

        await render.finish()
        var returned = false
        for _ in 0..<200 where !returned {
            returned = await render.hasReturned
            if !returned { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(returned, "the stale render came back after Cancel")
        // Checked by the renderer as it returns: the model's cleanup runs on the main actor as soon as the render
        // returns, which can be before this test's poll sees `hasReturned`, so the file may already be gone here.
        let wroteCopy = await render.wroteCopy
        XCTAssertTrue(wroteCopy, "it wrote its cleaned copy")
        // The cancelled preparation comes back to the main actor and, past its guard, deletes the stale copy.
        try await waitFor("the stale cleaned copy to be deleted", timeoutNanoseconds: 3_000_000_000) {
            !FileManager.default.fileExists(atPath: destination.path)
        }

        let draft = try XCTUnwrap(model.sharingState.drafts.first)
        XCTAssertNil(draft.cleanedAudioURL, "a cancelled render must not attach its copy")
        XCTAssertNil(draft.cleanedAudioDurationMs)
        XCTAssertEqual(draft.representationChoice, cancelled.representationChoice)
        XCTAssertNil(draft.preparationMessage)
        XCTAssertFalse(draft.isPreparingCleanup)
        XCTAssertFalse(draft.currentEditState.automaticCleanupEnabled)
        XCTAssertNil(draft.cleanup)
        XCTAssertFalse(model.sharingState.isBulkPreparing)
        XCTAssertEqual(model.sharingState.bulkPreparationCompleted, 0)
        XCTAssertEqual(model.bulkSharePreparationEligibleCount, 1, "the Margin is still eligible for the next run")
    }

    func testBulkSharePreparationFallsBackToOriginalVoiceWhenRenderingFails() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appending(path: "bulk-margin-fallback-\(UUID().uuidString).m4a")
        let originalBytes = Data([0x02, 0x03])
        try originalBytes.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] },
            shareMarginAudioCleanupHandler: { _, _, _ in
                throw SessionKitError.persistenceFailed("deliberate_cleanup_failure")
            }
        )
        model.resetAndSeed()
        model.importTitle = "Bulk fallback"
        model.importText = "An item with one Margin."
        model.importTextItem()
        model.selectedItem.interjections = [bulkShareableInterjection(
            itemId: model.selectedItem.id,
            id: "margin-fallback",
            audioPath: sourceURL.path
        )]
        model.prepareShareInterjections()
        model.prepareAllIncludedShareDrafts()
        try await waitFor("bulk fallback to finish") {
            !model.sharingState.isBulkPreparing
        }

        let draft = try XCTUnwrap(model.sharingState.drafts.first)
        XCTAssertEqual(model.sharingState.bulkPreparationFailureCount, 1)
        XCTAssertEqual(draft.representationChoice, .original)
        XCTAssertNil(draft.cleanedAudioURL)
        XCTAssertNotNil(draft.preparationMessage)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
    }

    func testPlaybackScrubStateKeepsGestureValueAuthoritativeUntilCommit() {
        var state = PlaybackScrubState()
        let range = 0.0...3_600.0

        // SwiftUI may deliver the binding write before onEditingChanged(true).
        state.updateFromGesture(1_500, range: range)
        state.begin(at: 120, range: range)

        XCTAssertTrue(state.isEditing)
        XCTAssertEqual(state.displayedValue(canonicalValue: 121, range: range), 1_500)

        state.updateFromGesture(1_620, range: range)
        XCTAssertEqual(state.displayedValue(canonicalValue: 122, range: range), 1_620)

        state.finish()
        XCTAssertFalse(state.isEditing)
        for canonicalTick in [1_620.0, 1_620.5, 1_621.0, 1_621.5] {
            XCTAssertEqual(
                state.displayedValue(canonicalValue: canonicalTick, range: range),
                canonicalTick,
                "After release the scrubber must immediately rejoin and continue following canonical playback"
            )
        }
    }

    func testLateSliderWriteCannotFreezeCanonicalPlaybackAfterRelease() {
        var state = PlaybackScrubState()
        let range = 0.0...100.0
        state.begin(at: 10, range: range)
        state.updateFromGesture(40, range: range)
        state.finish()
        state.updateFromGesture(40, range: range)
        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.displayedValue(canonicalValue: 41, range: range), 41)
        XCTAssertEqual(state.displayedValue(canonicalValue: 42, range: range), 42)
    }

    func testStartupRecoveryIncludesOlderUnpreparedItemsInNewestFirstOrder() {
        let old = LibraryItemRow(id: "old", title: "Old", status: "Ready", canDelete: true, addedAt: Date(timeIntervalSince1970: 1))
        let new = LibraryItemRow(id: "new", title: "New", status: "Ready", canDelete: true, addedAt: Date(timeIntervalSince1970: 2))
        let done = LibraryItemRow(id: "done", title: "Done", status: "Ready", canDelete: true, isCompleted: true, addedAt: Date(timeIntervalSince1970: 3))
        let ready = LibraryItemRow(id: "ready", title: "Ready", status: "Ready", canDelete: true, startupAudioState: .ready, addedAt: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(Gate1AppModel.startupPreparationCandidates([old, done, ready, new]), ["new", "old"])
    }

    func testPrioritizePinsOnlySelectedJobAndLeavesFutureImportsOrderedByRecency() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "queue-priority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        // Jobs for an item that isn't in the Library are dropped on refresh (#883), so each job's item has to exist.
        for id in ["old", "selected", "new"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Words to read aloud.", externalReference: nil, status: "ready"))
        }
        let old = AudioPreparationJob(id: "old", itemId: "old", manifestId: "old", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 1), maximumChunkCount: 2)
        let selected = AudioPreparationJob(id: "selected", itemId: "selected", manifestId: "selected", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 0), maximumChunkCount: 2)
        try store.saveAudioPreparationJob(old)
        try store.saveAudioPreparationJob(selected)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        await model.prioritizeAudioPreparationJob(id: selected.id)
        let new = AudioPreparationJob(id: "new", itemId: "new", manifestId: "new", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 2), maximumChunkCount: 2)
        try store.saveAudioPreparationJob(new)
        let jobs = try store.loadAudioPreparationJobs()
        XCTAssertNil(jobs.first(where: { $0.id == old.id })?.userPriority)
        XCTAssertEqual(jobs.sorted(by: Gate1AppModel.audioPreparationJobPrecedes).map(\.id), ["selected", "new", "old"])
    }

    func testNewestOpeningBufferComesFirstAndExplicitPriorityOverridesIt() {
        let old = AudioPreparationJob(id: "old", itemId: "old", manifestId: "old", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 1), maximumChunkCount: 2)
        let new = AudioPreparationJob(id: "new", itemId: "new", manifestId: "new", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 2), maximumChunkCount: 2)
        var pinned = AudioPreparationJob(id: "pinned", itemId: "pinned", manifestId: "pinned", policy: .whileCharging, requestedAt: Date(timeIntervalSince1970: 0))
        pinned.userPriority = 0
        XCTAssertEqual([old, new, pinned].sorted(by: Gate1AppModel.audioPreparationJobPrecedes).map(\.id), ["pinned", "new", "old"])
        XCTAssertEqual([old, new, pinned].sorted { Gate1AppModel.audioPreparationJobPrecedes($0, $1, activeItemId: "old") }.map(\.id), ["pinned", "old", "new"])
    }

    func testPlaybackScrubStateClampsGestureToCanonicalDuration() {
        var state = PlaybackScrubState()
        let range = 0.0...900.0

        state.begin(at: 0, range: range)
        state.updateFromGesture(1_200, range: range)
        XCTAssertEqual(state.displayedValue(canonicalValue: 0, range: range), 900)
    }

    func testPartialPreparedTextAudioDoesNotAdvertiseAFullScrubber() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.preparedTextAudioStatus = "starter_ready"

        XCTAssertFalse(model.canShowFullPlaybackScrubber)

        model.snapshot.preparedTextAudioStatus = "ready"
        XCTAssertTrue(model.canShowFullPlaybackScrubber)

        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.preparedTextAudioStatus = nil
        XCTAssertTrue(model.canShowFullPlaybackScrubber)
    }

    func testPlaybackHeaderKeepsTheItemTitleUnprefixedWhenItIsNotAChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(title: "Why Apple Is Heading Into a Pivotal Moment")
        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.chapterTitle = "Why Apple Is Heading Into a Pivotal Moment"

        XCTAssertEqual(model.playbackHeaderTitle, "Why Apple Is Heading Into a Pivotal Moment")
    }

    func testPlaybackHeaderPrefixesARealChapterWithItsNumber() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "item-1",
            title: "A Long Article",
            chapters: [
                Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0),
                Chapter(id: "chapter-2", title: "The Pivot", startChar: 100, endChar: 200, percent: 50)
            ]
        )
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.chapterTitle = "The Pivot"

        XCTAssertEqual(model.playbackHeaderTitle, "Ch. 2: The Pivot")
    }

    func testPlaybackHeaderNumbersARealPodcastChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "episode-1",
            title: "A Podcast Episode",
            mediaChapters: [
                MediaTimelineChapter(id: "intro", title: "Introduction", startMs: 0, transcriptSegmentId: "segment-1"),
                MediaTimelineChapter(id: "analysis", title: "The Analysis", startMs: 60_000, transcriptSegmentId: "segment-2")
            ]
        )
        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.chapterTitle = "The Analysis"

        XCTAssertEqual(model.playbackHeaderTitle, "Ch. 2: The Analysis")
    }

    func testPlaybackHeaderInfersCurrentGeneratedChapterWhenSnapshotStillReportsItemTitle() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "item-1",
            title: "A Long Article",
            chapters: [
                Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0),
                Chapter(id: "chapter-2", title: "The Pivot", startChar: 100, endChar: 200, percent: 50)
            ]
        )
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.title = "A Long Article"
        model.snapshot.chapterTitle = "A Long Article"
        model.snapshot.sourceProgressPercent = 60

        XCTAssertEqual(model.playbackChapterHeaderTitle, "Ch. 2: The Pivot")
    }

    func testPlaybackHeaderUsesPrivateListeningMapSceneWhenPodcastHasNoPublisherChapters() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "episode-1",
            title: "A Podcast Episode",
            listeningMapScenes: [
                MediaTimelineChapter(id: "scene-1", title: "Opening", startMs: 0, transcriptSegmentId: "segment-1"),
                MediaTimelineChapter(id: "scene-2", title: "The Debate", startMs: 60_000, transcriptSegmentId: "segment-2")
            ]
        )
        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.title = "A Podcast Episode"
        model.snapshot.chapterTitle = "A Podcast Episode"
        model.snapshot.currentMediaTimeMs = 90_000

        XCTAssertEqual(model.playbackChapterHeaderTitle, "Ch. 2: The Debate")
    }

    func testNativeAudioExportDisablesFullSourceTextOption() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(id: "podcast", title: "Podcast", isNativeAudio: true)
        XCTAssertFalse(model.exportSourceTextAvailable)

        model.selectedItem = ItemDetailState(id: "article", title: "Article", isNativeAudio: false)
        XCTAssertTrue(model.exportSourceTextAvailable)
    }

    func testDeletedInterjectionsAreNeverEligibleForAnotherSummary() {
        let active = Interjection(
            id: "active",
            itemId: "item",
            sessionId: "session",
            targetType: .item,
            targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "Keep me",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        var deleted = active
        deleted.id = "deleted"
        deleted.status = "deleted"

        let eligible = Gate1SummaryEligibility.unsummarizedInterjections(
            turns: [],
            interjections: [active, deleted],
            currentTargetType: TargetType.itemTextTTS.rawValue,
            currentTargetId: "item"
        )

        XCTAssertEqual(eligible.map(\.id), ["active"])
    }

    func testCurrentPDFChapterUsesExactPositionWhenPercentagesCollide() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let starts = [0, 21, 174, 185]
        let chapters = starts.enumerated().map { index, start in
            Chapter(id: "chapter-\(index)", title: "Section \(index)", startChar: start,
                    endChar: index + 1 < starts.count ? starts[index + 1] : 2904, percent: 0)
        }
        model.selectedItem = ItemDetailState(id: "pdf", title: "Report", chapters: chapters)
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.sourceProgressPercent = 0
        for (index, offset) in starts.enumerated() {
            model.snapshot.currentTextStart = offset
            XCTAssertEqual(model.currentChapter?.id, chapters[index].id)
        }
        model.snapshot.currentTextStart = 180
        XCTAssertEqual(model.currentChapter?.id, chapters[2].id)
    }

    func testTimelineMarksTheCurrentSourceChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let opening = Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0)
        let pivot = Chapter(id: "chapter-2", title: "The Pivot", startChar: 100, endChar: 200, percent: 50)
        model.selectedItem = ItemDetailState(id: "item-1", title: "A Long Article", chapters: [opening, pivot])
        model.snapshot.targetType = TargetType.itemTextTTS.rawValue
        model.snapshot.chapterTitle = pivot.title

        XCTAssertFalse(model.isCurrentTimelineChapter(opening))
        XCTAssertTrue(model.isCurrentTimelineChapter(pivot))
    }

    func testTimelineDoesNotMarkASourceChapterDuringAssistantPlayback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let opening = Chapter(id: "chapter-1", title: "Opening", startChar: 0, endChar: 100, percent: 0)
        model.selectedItem = ItemDetailState(id: "item-1", title: "A Long Article", chapters: [opening])
        model.snapshot.targetType = TargetType.assistantTurnTTS.rawValue
        model.snapshot.chapterTitle = opening.title

        XCTAssertFalse(model.isCurrentTimelineChapter(opening))
    }

    func testSupertonicGenerationStatusSupportsNativeAndGeneratedTextTargets() {
        XCTAssertTrue(Gate1AppModel.supportsOnDeviceSpeechGenerationStatus(
            targetType: TargetType.itemTextTTS.rawValue
        ))
        XCTAssertTrue(Gate1AppModel.supportsOnDeviceSpeechGenerationStatus(
            targetType: TargetType.summaryTurnTTS.rawValue
        ))
        XCTAssertTrue(Gate1AppModel.supportsOnDeviceSpeechGenerationStatus(
            targetType: TargetType.assistantTurnTTS.rawValue
        ))
        XCTAssertFalse(Gate1AppModel.supportsOnDeviceSpeechGenerationStatus(
            targetType: TargetType.transcriptBackedMedia.rawValue
        ))
    }

    /// #314: a stop's reason reaches the model's diagnostics and the on-device voice line, and
    /// leaves diagnostics once generation runs again, so a device report taken after a
    /// successful Retry doesn't show the old failure.
    func testGenerationStopReasonReachesDiagnosticsAndClearsWhenGenerationRunsAgain() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let assembly = "\(SpeechGenerationStopReason.assemblyFailedCode): disk full"

        model.updateOnDeviceSpeechGenerationState(.stopped, stopReason: assembly)
        XCTAssertEqual(model.diagnostics["onDeviceSpeechGenerationStopReason"], assembly)
        XCTAssertTrue(
            model.onDeviceSpeechGenerationStatusDescription.contains("Couldn't save the finished audio"),
            model.onDeviceSpeechGenerationStatusDescription
        )

        // A render that failed without the iOS voice taking over (no fallback reason) must not
        // say the iOS voice is playing.
        model.updateOnDeviceSpeechGenerationState(.stopped, stopReason: "supertonic_render_timeout")
        XCTAssertEqual(model.diagnostics["onDeviceSpeechGenerationStopReason"], "supertonic_render_timeout")
        XCTAssertFalse(
            model.onDeviceSpeechGenerationStatusDescription.contains("iOS"),
            model.onDeviceSpeechGenerationStatusDescription
        )

        model.updateOnDeviceSpeechGenerationState(.rendering, stopReason: nil)
        XCTAssertNil(model.onDeviceSpeechGenerationStopReason)
        XCTAssertNil(model.diagnostics["onDeviceSpeechGenerationStopReason"], "A Retry that renders again clears the old reason")
    }

    func testTimelineMarksTheCurrentPreparedAudioChapter() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let opening = MediaTimelineChapter(
            id: "ch-supertonic-01",
            title: "Opening",
            startMs: 0,
            transcriptSegmentId: "segment-1"
        )
        let pivot = MediaTimelineChapter(
            id: "ch-supertonic-02",
            title: "The Pivot",
            startMs: 60_000,
            transcriptSegmentId: "segment-2"
        )
        model.selectedItem = ItemDetailState(
            id: "item-1",
            title: "A Long Article",
            mediaChapters: [opening, pivot]
        )
        model.snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        model.snapshot.chapterTitle = pivot.title

        XCTAssertFalse(model.isCurrentTimelineMediaChapter(opening))
        XCTAssertTrue(model.isCurrentTimelineMediaChapter(pivot))
    }


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
        XCTAssertTrue(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 1,
            isUITesting: false
        ))
        XCTAssertFalse(Gate1AppModel.shouldSeedWelcomeSample(
            libraryIsEmpty: true,
            storedVersion: 2,
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
        XCTAssertTrue(model.selectedItem.text.contains("Tap Add a Margin"))
        XCTAssertTrue(model.selectedItem.text.contains("backward and forward buttons"))
        XCTAssertTrue(model.selectedItem.text.contains("Link or Podcast"))
        XCTAssertTrue(model.selectedItem.text.contains("document, PDF, DRM-free EPUB"))
        XCTAssertTrue(model.selectedItem.text.contains("Summarize Notes synthesizes"))
        XCTAssertTrue(model.selectedItem.text.contains("enable Spoken Margins Text"))
        XCTAssertFalse(model.selectedItem.text.contains("You Can't Inspect the Pill"))
        XCTAssertEqual(model.selectedItem.chapters.count, 6, "the welcome title heads its opening, then five sections")
    }

    /// #1043 APM-10: the practice-Margin step was checked once, before any tap. It must stay open through Add
    /// Margin (button and compact control), through Cancel, and through a Finish whose save fails; only a saved
    /// Margin completes it.
    func testGuidedOnboardingAdvancesOnlyFromCompletedProductActions() throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let recorder = try CountingToneRecordingClient()
        defer { recorder.removeSavedFiles() }
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: recorder,
            interjectionTranscriptionHandler: { _ in "A practice note." }
        )
        model.resetOnboardingProgressForTesting()
        defer { model.resetOnboardingProgressForTesting() }
        model.resetAndSeed()

        model.startGuidedOnboarding()

        XCTAssertEqual(model.selectedItem.id, Gate1AppModel.guidedOnboardingItemId)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertTrue(model.shouldShowGuidedOnboardingCoach)
        XCTAssertEqual(model.guidedOnboardingStage, .practiceInterjection)
        XCTAssertFalse(model.isOnboardingStepComplete(.firstInterjection))

        func assertPracticeStepStillOpen(_ moment: String) {
            XCTAssertFalse(model.isOnboardingStepComplete(.firstInterjection), moment)
            XCTAssertEqual(model.guidedOnboardingStage, .practiceInterjection, moment)
        }
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        assertPracticeStepStillOpen("after Add Margin")
        model.cancelInterjection()
        XCTAssertFalse(model.snapshot.isRecording)
        assertPracticeStepStillOpen("after Cancel")
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        assertPracticeStepStillOpen("after Add Margin from the compact control")
        model.dispatchGate2CompactCommand(.cancelInterjection)
        assertPracticeStepStillOpen("after Cancel from the compact control")

        recorder.refusesToFinish = true
        model.beginInterjection()
        model.finishInterjection()
        XCTAssertNotNil(model.lastError, "the failed save is reported")
        XCTAssertTrue(model.selectedItem.interjections.isEmpty, "nothing was saved")
        assertPracticeStepStillOpen("after a Finish whose save failed")
        model.dispatchGate2CompactCommand(.finishInterjection)
        assertPracticeStepStillOpen("after a compact Finish whose save failed")
        model.cancelInterjection()
        XCTAssertFalse(model.snapshot.isRecording)
        recorder.refusesToFinish = false
        XCTAssertEqual(recorder.finishCount, 2, "both Finishes reached the recorder")

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertTrue(model.isOnboardingStepComplete(.firstInterjection))
        XCTAssertEqual(model.guidedOnboardingStage, .reviewTimeline)
        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)

        model.recordTimelineInterjectionViewed(interjectionId: interjection.id)

        XCTAssertTrue(model.isOnboardingStepComplete(.reviewedTimeline))
        XCTAssertEqual(model.guidedOnboardingStage, .optionalAI)

        model.continueGuidedOnboardingPastAI()
        XCTAssertEqual(model.guidedOnboardingStage, .exportSession)
        model.openExport()
        model.recordSessionExported()

        XCTAssertTrue(model.isOnboardingStepComplete(.exportedSession))
        XCTAssertTrue(model.hasCompletedCoreOnboarding)
        XCTAssertEqual(model.guidedOnboardingStage, .complete)
    }

    func testRecordingBlocksNavigationAndSessionReplacementWithoutMutatingListeningState() throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetAndSeed()
        model.addSampleItem()
        model.startItem(id: "item-pill")
        let session = try XCTUnwrap(model.selectedItem.sessions.first)
        let libraryIDs = model.libraryItems.map(\.id)
        let selectedItemID = model.selectedItem.id
        let activeItemID = model.activePlaybackItemId
        let mediaRate = model.mediaPlaybackRate
        let speechRate = model.speechRate

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        let recordingSnapshot = model.snapshot

        model.screen = .item
        model.openHome()
        model.openSettings()
        model.openHelp()
        model.openTimeline()
        model.openOfflineStorage()
        model.openExport()
        model.openBatchExport()
        model.openItem(id: Gate1AppModel.welcomeSampleItemId)
        model.startItem(id: Gate1AppModel.welcomeSampleItemId)
        model.startNewSession(id: Gate1AppModel.welcomeSampleItemId)
        model.openSession(session)
        model.resumeSession(session)
        model.moveItemToTrash(id: "item-pill")
        model.endSession()
        model.dismissMiniPlayer()
        model.cyclePlaybackRate()
        model.setMediaPlaybackRate(2)
        model.dispatchGate2CompactCommand(.setPlaybackRate, playbackRate: 2)

        XCTAssertEqual(model.snapshot, recordingSnapshot)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.selectedItem.id, selectedItemID)
        XCTAssertEqual(model.activePlaybackItemId, activeItemID)
        XCTAssertEqual(model.libraryItems.map(\.id), libraryIDs)
        XCTAssertEqual(model.mediaPlaybackRate, mediaRate)
        XCTAssertEqual(model.speechRate, speechRate)
        XCTAssertFalse(model.isHelpPresented)
        XCTAssertNotNil(model.recordingPresentationContext)
        XCTAssertTrue(model.statusMessage.contains("Finish or cancel"))
    }

    func testAddingMarginWhileAnotherDetailIsOpenUsesPlayingItem() async throws {
        try await checkMarginWhileAnotherDetailIsOpen(compact: false)
    }

    func testCompactMarginWhileAnotherDetailIsOpenUsesPlayingItem() async throws {
        try await checkMarginWhileAnotherDetailIsOpen(compact: true)
    }

    /// #1527: real navigation and SQLite ownership, with transport/recording injected because
    /// this test checks item identity rather than audio encoding or microphone health.
    private func checkMarginWhileAnotherDetailIsOpen(compact: Bool) async throws {
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = Gate1AppModel(
            audioPlaybackClient: WorkflowRecordingAudioClient(), recordingClient: NoopRecordingClient(),
            microphonePermissionStatus: { .granted },
            databaseURLOverride: directory.appendingPathComponent("library.sqlite")
        )
        model.resetAndSeed()
        model.declineCurrentTerms()
        let store = try model.libraryStoreForTesting()
        let b = Item(id: "item-b", title: "X post", mediaType: "text", text: "A different item.",
                     externalReference: nil, status: "ready")
        try store.saveItem(b)
        let bSession = Session(id: "session-b", itemId: b.id, status: "in_progress", phase: .itemPlayback,
                               currentTargetType: .itemTextTTS, currentTargetId: b.id,
                               position: Position(), completionPercent: 0, playbackRate: 1)
        try store.saveSession(bSession)
        model.startItem(id: "item-pill")
        let aTitle = model.selectedItem.title
        let aSessionID = try XCTUnwrap(model.snapshot.sessionId)
        model.openHome()
        model.openItem(id: b.id)
        XCTAssertEqual(model.selectedItem.id, b.id)
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertTrue(model.shouldShowMiniPlayer)
        let bLibraryRow = try XCTUnwrap(model.loadLibraryRows(store: store).first { $0.id == b.id })

        if compact {
            model.dispatchGate2CompactCommand(.beginInterjection, origin: "compact_url")
        } else {
            model.beginInterjection()
            XCTAssertEqual(model.recordingPresentationContext?.itemTitle, aTitle,
                           "the acknowledgement before the microphone starts also names A")
        }
        try await waitFor("Margin to start on the playing item") { model.snapshot.isRecording }
        let context = try XCTUnwrap(model.recordingPresentationContext)
        XCTAssertEqual(context.itemTitle, aTitle)
        XCTAssertEqual(context.locationTitle, model.snapshot.chapterTitle)
        XCTAssertEqual(context.progressPercent, model.snapshot.currentPlaybackProgressPercent)
        let fallback = RecordingPresentationContext(snapshot: model.snapshot, startedAt: context.startedAt)
        XCTAssertEqual(fallback, context, "the recording screen's fallback uses the same playing session")
        if compact {
            model.dispatchGate2CompactCommand(.finishInterjection, origin: "compact_url")
        } else {
            model.finishInterjection()
        }
        XCTAssertFalse(model.snapshot.isRecording)
        // The Margins list refreshes the playing item's rows off the main thread (#2505).
        await model.settleMarginRows()
        let saved = try XCTUnwrap(store.loadInterjections(sessionId: aSessionID).first)
        XCTAssertEqual(saved.itemId, "item-pill")
        XCTAssertEqual(saved.sessionId, aSessionID)
        XCTAssertTrue(try store.loadInterjections(sessionId: bSession.id).isEmpty)
        XCTAssertEqual(model.selectedItem.id, b.id)
        XCTAssertTrue(model.selectedItem.interjections.isEmpty, "B's open detail never receives A's Margin")
        XCTAssertEqual(model.selectedItem.sessionRows.map(\.interjectionCount), [0])
        model.marginCollectionQuery = MarginCollectionQuery(itemID: b.id)
        XCTAssertTrue(model.visiblePrivateMarginRows.isEmpty, "B's Margins list is empty")
        // Without the storage rank: it is B's place in the store's updated_at order, so it moves whenever A's
        // record gets a later timestamp, and it is not a badge (#2164).
        let bLibraryRowAfter = try XCTUnwrap(model.loadLibraryRows(store: store).first { $0.id == b.id })
        XCTAssertEqual(libraryRowFieldsExceptStorageRank(bLibraryRowAfter), libraryRowFieldsExceptStorageRank(bLibraryRow),
                       "B's Library status and progress badges do not change")
        model.openItem(id: "item-pill")
        XCTAssertEqual(model.selectedItem.interjections.map(\.id), [saved.id])
        model.marginCollectionQuery = MarginCollectionQuery(itemID: "item-pill")
        XCTAssertEqual(model.visiblePrivateMarginRows.map(\.interjection.id), [saved.id])
        model.openItem(id: b.id)
        XCTAssertTrue(model.selectedItem.interjections.isEmpty, "reopening B still shows no Margins")
    }

    func testFinishAcknowledgesImmediatelyAndRejectsAccidentalRestart() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        model.requestFinishInterjection()
        XCTAssertTrue(model.isFinishingInterjection)
        model.requestFinishInterjection()
        model.beginInterjection()
        try await waitFor("Margin finish") { !model.isFinishingInterjection }
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.selectedItem.interjections.count, 1)
        XCTAssertTrue(model.isMarginCaptureCoolingDown)
        model.beginInterjection()
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertFalse(model.snapshot.isRecording)
        // #148: the old timer ran out 0.7 s after the save returned, while the listening screen was still being
        // drawn, and the queued second tap on Add a Margin then started a recording. The shield now waits for the
        // screen to appear.
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(model.isMarginCaptureCoolingDown, "no listening screen has appeared yet")
        model.beginInterjection()
        XCTAssertFalse(model.snapshot.isRecording)
        model.listeningScreenAppeared()
        model.beginInterjection()
        XCTAssertFalse(model.isRequestingRecordingPermission, "a tap right after the draw is the queued second tap")
        XCTAssertFalse(model.snapshot.isRecording)
        try await waitFor("capture cooldown", timeoutNanoseconds: 2_000_000_000) { !model.isMarginCaptureCoolingDown }
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        model.dispatchGate2CompactCommand(.cancelInterjection)
    }

    func testFinishAndCancelAreTheOnlyRecordingExits() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let recorder = try CountingToneRecordingClient()
        defer { recorder.removeSavedFiles() }
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: recorder
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionID = model.snapshot.sessionId
        let targetID = model.snapshot.targetId
        let anchor = model.snapshot.currentPlaybackProgressPercent

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.recordingNavigationIsLocked)
        XCTAssertEqual(recorder.beginCount, 1, "the microphone was asked to start once")
        model.dispatchGate2CompactCommand(.finishInterjection)
        XCTAssertEqual(recorder.finishCount, 1)
        XCTAssertEqual(recorder.cancelCount, 0)
        XCTAssertEqual(model.selectedItem.interjections.first?.audioPath, recorder.savedPaths.first)

        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertNil(model.recordingPresentationContext)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.targetId, targetID)
        XCTAssertEqual(model.snapshot.currentPlaybackProgressPercent, anchor)
        let savedCount = model.selectedItem.interjections.count
        XCTAssertEqual(savedCount, 1)

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.recordingNavigationIsLocked)
        XCTAssertEqual(recorder.beginCount, 2)
        model.dispatchGate2CompactCommand(.cancelInterjection)
        XCTAssertEqual(recorder.cancelCount, 1, "cancel discards the recording")
        XCTAssertEqual(recorder.finishCount, 1, "cancel never saves")

        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertNil(model.recordingPresentationContext)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.targetId, targetID)
        XCTAssertEqual(model.snapshot.currentPlaybackProgressPercent, anchor)
        XCTAssertEqual(model.selectedItem.interjections.count, savedCount)
        model.openHome()
        XCTAssertEqual(model.screen, .home)
    }

    /// #1043 APM-01 (and #937's shape): with a recorder that never fails, nothing checked what the listener is
    /// left with when the microphone won't start. The recording screen must close, the source play on, and
    /// nothing be saved; the next tap, with a working microphone, records.
    func testAMicrophoneThatWontStartClosesTheRecordingScreenAndPlaysOn() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let recorder = try CountingToneRecordingClient()
        defer { recorder.removeSavedFiles() }
        recorder.refusesToStart = true
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: recorder)
        model.resetAndSeed()
        model.importTitle = "Microphone Refuses"
        model.importText = "One. Two. Three."
        model.importTextItem()
        XCTAssertTrue(audio.isPlaying)
        let playsBefore = audio.playedOffsets.count

        model.beginInterjection()

        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(recorder.cancelCount, 1, "the failed start lets go of the microphone")
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertNil(model.recordingPresentationContext, "no recording screen over a microphone that never started")
        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertNotNil(model.lastError, "the listener is told the Margin did not start")
        XCTAssertTrue(audio.isPlaying, "the source plays on")
        XCTAssertGreaterThan(audio.playedOffsets.count, playsBefore)
        XCTAssertTrue(model.selectedItem.interjections.isEmpty)

        recorder.refusesToStart = false
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(recorder.beginCount, 2)
        model.cancelInterjection()
        XCTAssertEqual(recorder.cancelCount, 2)
    }

    /// #1043 APM-03: the recording tests never looked at a saved Margin's audio. Each Margin here must point at
    /// its own non-empty recording that the app can find and decode, and transcription must be given that file.
    func testSpokenMarginsAreSavedAsTheirOwnPlayableRecordings() async throws {
        let recorder = try CountingToneRecordingClient()
        defer { recorder.removeSavedFiles() }
        let transcribed = TranscribedAudioPaths()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: recorder,
            interjectionTranscriptionHandler: { path in
                transcribed.append(path)
                return "A spoken Margin."
            }
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        for _ in 0..<2 {
            model.beginInterjection()
            XCTAssertTrue(model.snapshot.isRecording)
            model.finishInterjection()
            XCTAssertFalse(model.snapshot.isRecording)
        }

        XCTAssertEqual(recorder.finishCount, 2)
        XCTAssertEqual(Set(recorder.savedPaths).count, 2, "each Margin keeps its own recording")
        let margins = model.selectedItem.interjections
        XCTAssertEqual(margins.count, 2)
        XCTAssertEqual(Set(margins.compactMap(\.audioPath)), Set(recorder.savedPaths))
        for margin in margins {
            XCTAssertEqual(margin.audioStatus, "saved")
            let path = try XCTUnwrap(margin.audioPath)
            let url = try XCTUnwrap(model.resolvedInterjectionAudioURL(for: path), "the app finds the file the recorder wrote")
            XCTAssertEqual(url.standardizedFileURL.path, recorder.supportDirectory.appending(path: path).standardizedFileURL.path)
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.length, 0, "the saved Margin has audio behind it")
        }
        try await waitFor("both Margins to reach transcription", timeoutNanoseconds: 5_000_000_000) {
            transcribed.all.count == 2
        }
        XCTAssertEqual(Set(transcribed.all), Set(recorder.savedPaths), "transcription is given each Margin's own file")
    }

    func testOpeningMarginFromAnotherSessionDoesNotReplaceNowPlaying() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.activePlaybackIsPlaying, "only a playing session is protected (#638)")
        let snapshotBefore = model.snapshot
        let margin = MarginRow(
            interjection: Interjection(
                id: "other-margin",
                itemId: "item-pill",
                sessionId: "another-session",
                targetType: .item,
                targetId: "item-pill",
                createdAt: Date(),
                roughPercent: 25,
                anchor: Anchor(
                    anchorType: .text,
                    startChar: 10,
                    endChar: 20,
                    anchorBefore: "Before",
                    anchorAfter: "After"
                ),
                audioPath: "Interjections/other-margin.m4a",
                audioStatus: "saved",
                transcriptionStatus: "transcribed",
                transcript: "A thought from another session.",
                cleanedTranscript: nil,
                displayText: nil,
                status: "active"
            ),
            itemTitle: "The Pill and the Paper Trail",
            sessionDate: Date()
        )

        model.openMarginInTimeline(margin)

        XCTAssertEqual(model.snapshot, snapshotBefore)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.diagnostics["marginTimelineNavigation"], "blocked_active_session_replacement")
        XCTAssertTrue(model.statusMessage.contains("Now Playing was left unchanged"))
    }

    func testGuidedOnboardingTimelineChapterCompletesReviewStep() throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetOnboardingProgressForTesting()
        defer { model.resetOnboardingProgressForTesting() }
        model.resetAndSeed()
        model.startGuidedOnboarding()
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        let chapter = try XCTUnwrap(model.selectedItem.chapters.first)

        model.jumpToChapter(chapter)

        XCTAssertEqual(model.guidedOnboardingStage, .reviewTimeline)
        XCTAssertFalse(model.isOnboardingStepComplete(.reviewedTimeline))

        model.jumpToChapter(chapter, fromTimeline: true)

        XCTAssertTrue(model.isOnboardingStepComplete(.reviewedTimeline))
        XCTAssertEqual(model.guidedOnboardingStage, .optionalAI)
    }

    func testManualImportCountsAsOwnSourceButNotAsSafariFileOrPodcast() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetOnboardingProgressForTesting()
        defer { model.resetOnboardingProgressForTesting() }
        model.resetAndSeed()
        model.importTitle = "My Source"
        model.importText = "This source belongs to the user."

        model.importTextItem()

        XCTAssertTrue(model.isOnboardingStepComplete(.addedOwnSource))
        XCTAssertFalse(model.isOnboardingStepComplete(.addedFromSafari))
        XCTAssertFalse(model.isOnboardingStepComplete(.addedFromFiles))
        XCTAssertFalse(model.isOnboardingStepComplete(.addedPodcast))
    }

    /// #1019: the progress is read in the model's declaration and written under the three keys,
    /// with the value types, that Build 29 used. A listener's tour must survive an update.
    func testOnboardingProgressIsReadFromAndWrittenToTheKeysEarlierBuildsUsed() {
        let keys = ["onboardingCompletedStepsV1", "guidedOnboardingStageV1", "onboardingCardDismissedV1"]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { zip(keys, prior).forEach { restoreUserDefault($1, forKey: $0) } }
        UserDefaults.standard.set(["reviewed_timeline", "not_a_step", "first_interjection"], forKey: keys[0])
        UserDefaults.standard.set("review_timeline", forKey: keys[1])
        UserDefaults.standard.set(true, forKey: keys[2])

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())

        XCTAssertTrue(model.isOnboardingStepComplete(.firstInterjection))
        XCTAssertTrue(model.isOnboardingStepComplete(.reviewedTimeline))
        XCTAssertEqual(model.guidedOnboardingStage, .reviewTimeline)
        XCTAssertTrue(model.isOnboardingCardDismissed)

        model.markOnboardingSteps([.exportedSession, .addedPodcast])
        let stored = UserDefaults.standard.stringArray(forKey: keys[0]) ?? []
        XCTAssertEqual(stored, stored.sorted(), "steps are stored as a sorted array of raw values")
        for name in ["first_interjection", "reviewed_timeline", "exported_session", "added_podcast"] {
            XCTAssertTrue(stored.contains(name), name)
        }
        XCTAssertFalse(stored.contains("not_a_step"))

        model.pauseGuidedOnboarding()
        XCTAssertEqual(UserDefaults.standard.string(forKey: keys[1]), "inactive")
        model.restoreOnboardingCard()
        XCTAssertEqual(UserDefaults.standard.object(forKey: keys[2]) as? Bool, false)
        model.dismissOnboardingCard()
        XCTAssertEqual(UserDefaults.standard.object(forKey: keys[2]) as? Bool, true)
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

    func testSchemaFiveLibraryRemainsVisibleAcrossEveryReportedIngestionRoute() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "schema-five-ingestion-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        do {
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.saveItem(Item(
                id: "item-existing-v5",
                title: "Existing Schema 5 Library Item",
                mediaType: "text",
                text: "Existing library content must remain visible.",
                externalReference: "existing-v5",
                status: "ready"
            ))
        }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: databaseURL.path), 5)

        let resolver = SchemaFiveIngestionLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/shared-episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/shared-episode", provider: "direct_audio", role: "audio_file"),
                title: "Shared Podcast Episode",
                durationMs: 180_000,
                audioURL: "https://cdn.example.com/shared-episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: SchemaFiveNoopSourceTranscriptionClient(),
            databaseURLOverride: databaseURL
        )

        model.bootstrapLibraryIfNeeded()
        XCTAssertNil(model.libraryAccessError)
        XCTAssertTrue(model.libraryItems.contains { $0.id == "item-existing-v5" })

        model.importTitle = "Pasted Text"
        model.importText = "Text pasted directly into the app."
        model.importTextItem()
        XCTAssertTrue(model.libraryItems.contains { $0.title == "Pasted Text" })

        model.handleIncomingURL(Gate5BrowserTextHandoffURL.url(for: BrowserTextHandoff(
            itemId: "item-plugin-v5",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/plugin", title: "Plugin Text"),
            text: "Text delivered through the browser plugin.",
            requestedContinuation: BrowserTextContinuation(startSession: false)
        )))
        XCTAssertTrue(model.libraryItems.contains { $0.id == "item-plugin-v5" })

        model.handleIncomingURL(SourceLinkHandoffURL.url(for: SourceLinkHandoff(
            id: "source-link-share-v5",
            inputURL: "https://example.com/shared-episode",
            sourceSurface: "share_sheet",
            startSession: false
        )))
        XCTAssertTrue(model.libraryItems.contains { $0.title == "Shared Podcast Episode" })
        XCTAssertTrue(model.libraryItems.contains { $0.id == "item-existing-v5" })

        let reopened = try SQLiteSessionStore(path: databaseURL.path)
        let reopenedItems = try reopened.listItems()
        XCTAssertEqual(reopenedItems.count, 4)
        XCTAssertTrue(reopenedItems.contains { $0.id == "item-existing-v5" })
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: databaseURL.path), 5)
    }

    func testUnsupportedFutureSchemaShowsDataPreservationMessageInsteadOfEmptyLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "future-schema-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        do {
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.saveItem(Item(
                id: "item-future-schema",
                title: "Do Not Delete",
                mediaType: "text",
                text: "Preserve this record.",
                externalReference: nil,
                status: "ready"
            ))
        }
        try setSchemaVersion(6, at: databaseURL)

        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.bootstrapLibraryIfNeeded()

        XCTAssertTrue(model.libraryItems.isEmpty)
        XCTAssertTrue(model.libraryAccessError?.contains("did not reset") == true)
        XCTAssertTrue(model.libraryAccessError?.contains("Do not use Reset Library or delete the app") == true)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: databaseURL.path), 6)
        XCTAssertEqual(try recordCount(at: databaseURL), 1)
    }

    /// #1175: the scene-active refresh can open the store before the root view bootstraps the Library. A UI-test
    /// launch must still start from its own seed, not from what the previous run left in the database.
    func testUITestSeedReplacesTheLeftoverLibraryEvenWhenSomethingOpenedTheStoreFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ui-test-seed-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        do {
            let leftover = try SQLiteSessionStore(path: databaseURL.path)
            for id in ["item-leftover-pdf", "item-leftover-fixture"] {
                try leftover.saveItem(Item(
                    id: id, title: id, mediaType: "text", text: "Left by an earlier launch.",
                    externalReference: nil, status: "ready"
                ))
            }
        }

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.pendingUITestingSeed = .text(title: "J1: A short walk", text: "On a short walk.", reference: "ui-test")
        let store = try model.libraryStoreForTesting() // what opens first on a cold launch
        model.bootstrapLibraryIfNeeded()

        XCTAssertEqual(model.libraryItems.map(\.id), [UITestingLaunchSeed.textItemId])
        XCTAssertEqual(try store.listItems().map(\.id), [UITestingLaunchSeed.textItemId])
        XCTAssertNil(model.pendingUITestingSeed, "The seed is written once")

        try store.saveItem(Item(
            id: "item-added-later", title: "Added later", mediaType: "text", text: "Added by the script.",
            externalReference: nil, status: "ready"
        ))
        model.bootstrapLibraryIfNeeded()
        XCTAssertEqual(try store.listItems().count, 2, "A second bootstrap must not wipe the Library again")
    }

    func testALaunchWithoutAUITestSeedNeverResetsTheLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "no-seed-library-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        do {
            let existing = try SQLiteSessionStore(path: databaseURL.path)
            try existing.saveItem(Item(
                id: "item-owner", title: "Owner article", mediaType: "text", text: "Mine.",
                externalReference: nil, status: "ready"
            ))
        }

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        XCTAssertNil(model.pendingUITestingSeed, "A normal launch has no seed to write")
        let store = try model.libraryStoreForTesting()
        model.bootstrapLibraryIfNeeded()

        XCTAssertEqual(try store.listItems().map(\.id), ["item-owner"])
    }

    func testManualImportBuildsListeningMapFromPastedMarkdownHeadings() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Structured Notes"
        model.importText = """
        # Source Heading

        Opening context.

        ## First Claim

        Evidence for the first claim.

        ## Counterpoint

        Evidence for the counterpoint.

        ## Conclusion

        Closing synthesis.
        """

        model.importTextItem()

        XCTAssertEqual(model.selectedItem.title, "Structured Notes")
        // The lone `#` is the text's own title, not a section (#1468): the chapters are the `##` headings.
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["First Claim", "Counterpoint", "Conclusion"])
        XCTAssertEqual(model.selectedItem.chapters.first?.startChar, 0)
        XCTAssertEqual(model.selectedItem.chapters.last?.endChar, model.selectedItem.text.count)
        XCTAssertTrue(zip(model.selectedItem.chapters, model.selectedItem.chapters.dropFirst()).allSatisfy {
            $0.endChar == $1.startChar
        })
    }

    private func setSchemaVersion(_ version: Int, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw NSError(domain: "Gate1AppModelWorkflowTests", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = "UPDATE metadata SET value = '\(version)' WHERE key = 'schema_version';"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Gate1AppModelWorkflowTests", code: 2)
        }
    }

    private func recordCount(at databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw NSError(domain: "Gate1AppModelWorkflowTests", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM records;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Gate1AppModelWorkflowTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "Gate1AppModelWorkflowTests", code: 5)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func testManualImportDoesNotInventChaptersForUnstructuredText() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Plain Notes"
        model.importText = "A paragraph without structural headings. Another sentence follows."

        model.importTextItem()

        XCTAssertEqual(model.selectedItem.title, "Plain Notes")
        XCTAssertTrue(model.selectedItem.chapters.isEmpty)
    }

    func testRapidManualImportsReceiveDistinctIdentifiers() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "First Import"
        model.importText = "The first rapidly imported item."
        model.importTextItem()
        let firstID = model.selectedItem.id

        model.importTitle = "Second Import"
        model.importText = "The second rapidly imported item."
        model.importTextItem()
        let secondID = model.selectedItem.id

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == firstID }))
        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == secondID }))
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

    func testDismissingMiniPlayerHidesItBeforeSessionCleanupCompletes() async {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.openHome()

        XCTAssertTrue(model.shouldShowMiniPlayer)
        model.dismissMiniPlayer()

        XCTAssertFalse(model.shouldShowMiniPlayer)
        for _ in 0..<50 where model.hasActiveSession {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.hasActiveSession)
    }

    /// #583: closing the mini player while another item's page is open saves the session and keeps that
    /// page. It used to switch the page to the item that was playing.
    func testDismissingMiniPlayerKeepsAnotherItemsPageOpen() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        try store.saveItem(Item(id: "item-b", title: "Item B", mediaType: "text", text: "Source text.",
                                externalReference: nil, status: "ready"))
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.openItem(id: "item-b")
        XCTAssertEqual(model.selectedItem.id, "item-b")
        XCTAssertTrue(model.shouldShowMiniPlayer)

        model.dismissMiniPlayer()
        for _ in 0..<50 where model.hasActiveSession {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.hasActiveSession)
        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.selectedItem.id, "item-b")
        XCTAssertEqual(model.feedbackEvent?.message, "Session saved. You can resume it later.")
        XCTAssertEqual(try store.loadSessions().first { $0.id == sessionId }?.status, "in_progress")
    }

    /// #583: from the playing item's own page, closing the mini player still saves and shows that item.
    func testDismissingMiniPlayerOnThePlayingItemsPageKeepsItAndSaves() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.openItem(id: "item-pill")

        model.dismissMiniPlayer()
        for _ in 0..<50 where model.hasActiveSession {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.hasActiveSession)
        XCTAssertEqual(model.selectedItem.id, "item-pill")
        XCTAssertEqual(model.feedbackEvent?.message, "Session saved. You can resume it later.")
        XCTAssertEqual(model.selectedItem.sessions.first { $0.id == sessionId }?.status, "in_progress")
    }

    func testRoutinePlaybackAndNavigationActionsDoNotPresentFeedback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        XCTAssertNil(model.feedbackEvent)

        model.startItem(id: "item-pill")
        XCTAssertNil(model.feedbackEvent)
        XCTAssertTrue(model.statusMessage.hasPrefix("Started "))

        model.pause()
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.statusMessage, "Paused.")

        model.resumePlayback()
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.statusMessage, "Resumed.")

        model.openHome()
        model.openItem(id: "item-pill")
        XCTAssertNil(model.feedbackEvent)
        XCTAssertTrue(model.statusMessage.hasPrefix("Opened "))
    }

    func testBuildingVisibleExportPreviewDoesNotPresentFeedback() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.openExport()
        model.buildExport()

        XCTAssertFalse(model.exportPreview.isEmpty)
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(model.statusMessage, "Built session export.")
    }

    func testPlaybackHeaderOpensCurrentItemWithoutStoppingItsSession() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.openCurrentPlaybackItem()

        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.selectedItem.id, "item-pill")
        XCTAssertTrue(model.selectedItem.sessions.contains(where: { $0.id == sessionID }))
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertTrue(model.shouldShowMiniPlayer)
    }

    func testChapterFromAnotherItemClosesRestoredSessionAndStartsSelectedItem() throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let previousSessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.addSampleItem()
        let selectedItemID = model.selectedItem.id
        let chapter = try XCTUnwrap(model.selectedItem.chapters.dropFirst().first)
        model.jumpToChapter(chapter)

        XCTAssertEqual(model.snapshot.itemId, selectedItemID)
        XCTAssertNotEqual(model.snapshot.sessionId, previousSessionID)
        XCTAssertEqual(model.snapshot.chapterTitle, chapter.title)
        XCTAssertEqual(model.screen, .playback)
        model.openItem(id: "item-pill")
        XCTAssertTrue(model.selectedItem.sessions.contains { $0.id == previousSessionID })
    }

    func testLargeExportUsesBoundedVisiblePreviewWithoutChangingCopiedPayload() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let complete = String(repeating: "source context ", count: 4_000)
        model.exportPreview = complete

        XCTAssertTrue(model.exportPreviewIsTruncated)
        XCTAssertTrue(model.displayedExportPreview.contains("Preview truncated"))
        XCTAssertLessThan(model.displayedExportPreview.count, model.exportPreview.count)
        XCTAssertEqual(model.exportPreview, complete)
        XCTAssertFalse(model.exportPreviewSizeDescription.isEmpty)
    }

    #if canImport(UIKit)
    func testCopyingAssistantTurnNotesOmitsTheFullAssistantResponse() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "Listener note about the opening claim." }
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pastedAssistantResponse = """
        First response sentence. Second response sentence. Third response sentence.
        Fourth response sentence. Fifth response sentence. Sixth response sentence.
        Seventh response sentence. Eighth response sentence. Distinctive final appendix sentence.
        """
        model.importPastedAssistantResponse(autoPlay: true)
        let turn = try XCTUnwrap(model.selectedItem.turns.last(where: { $0.turnType == "assistant_response" }))

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("assistant response interjection transcription") {
            model.selectedItem.interjections.contains {
                $0.targetId == turn.id && $0.transcriptionStatus == "transcribed"
            }
        }

        UIPasteboard.general.string = nil
        model.copyTargetInterjections(
            targetType: InterjectionTargetType.assistantTurn.rawValue,
            targetId: turn.id
        )
        let copied = try XCTUnwrap(UIPasteboard.general.string)

        XCTAssertTrue(copied.contains("Listener note about the opening claim."))
        XCTAssertTrue(copied.contains("Turn continues:"))
        XCTAssertFalse(copied.contains("Distinctive final appendix sentence."))
    }
    #endif

    func testTrashUndoPreservesItemSessions() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertFalse(model.selectedItem.sessions.isEmpty)

        model.moveItemToTrash(id: "item-pill")

        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertTrue(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertEqual(model.trashUndo?.itemId, "item-pill")
        XCTAssertNil(model.feedbackEvent)

        model.undoLastTrash()
        await model.settleLibraryReload()
        model.openItem(id: "item-pill")

        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.selectedItem.sessions.isEmpty, "Restoring an item should restore its existing sessions")
    }

    /// #1043 APM-09: the trash tests ran on a player with no state, and the model resets its own snapshot, so
    /// a trashed item that kept playing with no screen to stop it passed. Here the player says whether it plays.
    func testTrashingThePlayingItemStopsItsAudioAndKeepsItsPlace() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let root = FileManager.default.temporaryDirectory.appending(path: "trash-playing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.importTitle = "Trash While Playing"
        model.importText = "One. Two. Three."
        model.importTextItem()
        let itemID = try XCTUnwrap(model.snapshot.itemId)
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertTrue(audio.isPlaying)

        model.moveItemToTrash(id: "item-pill")
        XCTAssertTrue(audio.isPlaying, "trashing another item leaves this one playing")
        XCTAssertEqual(model.snapshot.sessionId, sessionID)

        let stoppedAt = "One. ".count
        audio.currentOffset = stoppedAt
        model.moveItemToTrash(id: itemID)

        XCTAssertFalse(audio.isPlaying, "a trashed item must not keep playing with no screen to stop it")
        XCTAssertTrue(model.recentlyDeletedItems.contains { $0.id == itemID })
        let saved = try XCTUnwrap(SQLiteSessionStore(path: databaseURL.path).loadSession(id: sessionID))
        XCTAssertEqual(saved.status, "in_progress", "Undo brings the session back resumable")
        XCTAssertEqual(saved.position.charOffset, stoppedAt, "the place it stopped at is saved")
    }

    func testLibraryUnfinishedPreferenceTransitionRunsOnceAndPreservesSpecificChoices() throws {
        let suite = "library-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Gate1AppModel.loadLibraryListeningFilter(defaults: defaults), .unfinished)
        defaults.set("all", forKey: "libraryListeningStateFilter")
        XCTAssertEqual(Gate1AppModel.loadLibraryListeningFilter(defaults: defaults), .all)
        defaults.removePersistentDomain(forName: suite)
        defaults.set("all", forKey: "libraryListeningStateFilter")
        XCTAssertEqual(Gate1AppModel.loadLibraryListeningFilter(defaults: defaults), .unfinished)
        for choice in ["completed", "in_progress", "unplayed"] {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(choice, forKey: "libraryListeningStateFilter")
            XCTAssertEqual(Gate1AppModel.loadLibraryListeningFilter(defaults: defaults).rawValue, choice)
        }
    }

    func testUnfinishedLibraryCompletionUndoPreservesHistoryAndSearch() async throws {
        let keys = ["libraryContentTypeFilter", "libraryListeningStateFilter", "libraryOfflineStateFilter", "librarySort", "libraryUnfinishedDefaultApplied"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.libraryQuery = LibraryQuery()
        model.startItem(id: "item-pill")
        let history = model.selectedItem.sessions
        let snapshot = model.snapshot
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.markItemCompleted(id: "item-pill")
        await model.settleLibraryReload()
        XCTAssertFalse(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        try XCTUnwrap(model.feedbackEvent?.action, "Marking complete offers Undo on the banner").perform()
        await model.settleLibraryReload()
        XCTAssertNil(model.feedbackEvent?.action, "Undo answers with a plain confirmation")
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        XCTAssertEqual(model.selectedItem.sessions, history)
        // The waits above let playback move on (the chapter title changes), so compare the session, not the whole snapshot.
        XCTAssertEqual(model.snapshot.sessionId, snapshot.sessionId)
        XCTAssertEqual(model.snapshot.itemId, snapshot.itemId)
        XCTAssertEqual(model.snapshot.status, snapshot.status)
        model.markItemCompleted(id: "item-pill")
        await model.settleLibraryReload()
        model.libraryQuery.query = "pill"
        XCTAssertTrue(model.libraryHidesCompleted)
        XCTAssertFalse(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.libraryQuery.listeningState = .all
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.libraryQuery.contentType = .pdf
        model.resetLibraryFilters()
        XCTAssertEqual(model.libraryQuery.query, "pill")
        XCTAssertEqual(model.libraryQuery.listeningState, .unfinished)
        model.libraryQuery.query = ""
        for item in model.libraryItems where !item.isCompleted { model.markItemCompleted(id: item.id) }
        await model.settleLibraryReload()
        XCTAssertTrue(model.libraryIsCaughtUp)
        model.showCompletedLibraryItems()
        XCTAssertFalse(model.libraryIsCaughtUp)
        XCTAssertFalse(model.visibleLibraryItems.isEmpty)
    }

    func testMarkItemCompletedPersistsListeningStateAndStopsOfferingItAsContinueHero() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        let history = model.selectedItem.sessions
        model.markItemCompleted(id: "item-pill")
        await model.settleLibraryReload()

        let row = try XCTUnwrap(model.libraryItems.first(where: { $0.id == "item-pill" }))
        XCTAssertTrue(row.isCompleted)
        model.openItem(id: "item-pill")
        XCTAssertEqual(model.selectedItem.sessions, history, "Mark Complete must not fabricate listening history")
        model.libraryQuery.listeningState = .completed
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.libraryQuery.listeningState = .inProgress
        XCTAssertFalse(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.libraryQuery.listeningState = .unplayed
        XCTAssertFalse(model.visibleLibraryItems.contains { $0.id == "item-pill" })
    }

    // #273: once the 10-second undo banner was gone, nothing could mark an item unfinished again.
    func testItemMarkedCompleteByHandCanBeMarkedUnfinishedAfterTheUndoBannerIsGone() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        let history = model.selectedItem.sessions
        model.markItemCompleted(id: "item-pill")
        await model.settleLibraryReload()
        model.dismissFeedback()
        XCTAssertTrue(try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" }).canMarkUnfinished)

        model.markItemUnfinished(id: "item-pill")
        await model.settleLibraryReload()

        let row = try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" })
        XCTAssertFalse(row.isCompleted)
        XCTAssertFalse(row.canMarkUnfinished)
        model.libraryQuery.listeningState = .unfinished
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.openItem(id: "item-pill")
        XCTAssertEqual(model.selectedItem.sessions, history, "the listening position is unchanged")
    }

    func testUnplayedItemCanBeMarkedCompletedWithoutStartingPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.importTitle = "Read Later"
        model.importText = "A source that the listener finished somewhere else."
        model.importTextItem(startListening: false)
        let itemID = try XCTUnwrap(model.libraryItems.first(where: { $0.title == "Read Later" })?.id)
        model.openItem(id: itemID)
        let history = model.selectedItem.sessions
        model.markItemCompleted(id: itemID)
        await model.settleLibraryReload()
        model.openItem(id: itemID)

        XCTAssertTrue(try XCTUnwrap(model.libraryItems.first { $0.id == itemID }).isCompleted)
        XCTAssertEqual(model.selectedItem.sessions, history)
        XCTAssertFalse(model.snapshot.status.isPlaybackActive)
        let reopened = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        reopened.bootstrapLibraryIfNeeded()
        XCTAssertTrue(try XCTUnwrap(reopened.libraryItems.first { $0.id == itemID }).isCompleted)
    }

    /// #2195: the offline-services startup held its model strongly, so a dropped model lived on and its SQLite
    /// calls ran later on the main thread, during whatever came next. Each could wait out the 1 s busy timeout.
    func testDroppedModelIsReleasedAndItsOfflineServicesStartupIsCancelled() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "dropped-model-startup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        weak var dropped: Gate1AppModel?
        var startup: [Task<Void, Never>] = []
        do {
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
            model.resetAndSeed()
            startup = model.offlineServicesStartupTasks
            dropped = model
        }

        XCTAssertFalse(startup.isEmpty)
        XCTAssertNil(dropped, "nothing queued may keep a dropped model alive")
        XCTAssertTrue(startup.allSatisfy(\.isCancelled), "the model's deinit cancels its startup")
    }

    /// #2772: the offline-services startup asked the production server for the guided tour, and on a runner with a
    /// network the answer saved a `guided-onboarding` row into a library a test had already counted. A test model
    /// makes no request for it. The coordinator is swapped for one on a counting session before the startup task
    /// first runs, so the count is zero only because the startup never asked.
    func testAModelUnderUnitTestsDoesNotAskTheServerForTheGuidedTour() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let ledger = try XCTUnwrap(model.offlineStorageLedger)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuidedTourRequestCountingURLProtocol.self]
        GuidedTourRequestCountingURLProtocol.reset()
        model.guidedOnboardingCoordinator = GuidedOnboardingCoordinator(
            session: URLSession(configuration: configuration),
            directory: FileManager.default.temporaryDirectory
                .appending(path: "guided-tour-startup-\(UUID().uuidString)", directoryHint: .isDirectory),
            ledger: ledger
        )

        for task in model.offlineServicesStartupTasks { await task.value }

        XCTAssertEqual(GuidedTourRequestCountingURLProtocol.requested, [])
        XCTAssertFalse(model.libraryItems.contains { $0.id == Gate1AppModel.guidedOnboardingItemId })
    }

    /// #2195: every model a test built published Live Activity cards through the real ActivityKit. Those calls wait
    /// on a system daemon from the main thread, and on a loaded Mac they left 1 to 2.5 s of main-queue work behind
    /// tests that never touch a card. Under unit tests the default system shows no card and calls nothing.
    func testAModelUnderUnitTestsMakesNoActivityKitCalls() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.gate2CompactControls.diagnostics()["gate2LiveActivity"], "disabled")
    }

    func testExplicitOfflinePreparationJobsSortAheadOfAutomaticWork() {
        let automatic = AudioPreparationJob(
            id: "automatic",
            itemId: "automatic-item",
            manifestId: "automatic-manifest",
            policy: .whileCharging,
            requestedAt: Date(timeIntervalSince1970: 1)
        )
        let explicit = AudioPreparationJob(
            id: "explicit",
            itemId: "explicit-item",
            manifestId: "explicit-manifest",
            policy: .explicit,
            requestedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(
            [automatic, explicit].sorted(by: Gate1AppModel.audioPreparationJobPrecedes).map(\.id),
            ["explicit", "automatic"]
        )
    }

    func testClearAudioPreparationQueueKeepsLibraryItemsAndRemovesEveryJob() async throws {
        let defaults = UserDefaults.standard
        let suppressionKey = "suppressedAudioPreparationItemIdsV1"
        let priorSuppression = defaults.array(forKey: suppressionKey)
        defer {
            if let priorSuppression {
                defaults.set(priorSuppression, forKey: suppressionKey)
            } else {
                defaults.removeObject(forKey: suppressionKey)
            }
        }
        defaults.removeObject(forKey: suppressionKey)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "queue-bankruptcy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        // Jobs for an item that isn't in the Library are dropped on refresh (#883), so the second item has to exist.
        try store.saveItem(Item(
            id: "item-essay", title: "Essay", mediaType: "text", text: "Words to read aloud.",
            externalReference: nil, status: "ready"
        ))
        for index in 0..<200 {
            let itemId = index.isMultiple(of: 2) ? "item-pill" : "item-essay"
            try store.saveAudioPreparationJob(AudioPreparationJob(
                id: "clear-\(index)",
                itemId: itemId,
                manifestId: "manifest-\(index)",
                policy: index.isMultiple(of: 2) ? .demandWindow : .whileCharging,
                maximumChunkCount: index.isMultiple(of: 2) ? 2 : nil
            ))
        }
        try model.refreshLibraryRows(store: store)
        await model.refreshAudioPreparationPresentation()
        let itemCount = model.libraryItems.count
        XCTAssertEqual(model.audioPreparationQueue.count, 200)

        await model.clearAudioPreparationQueue()

        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
        XCTAssertEqual(model.libraryItems.count, itemCount)
        XCTAssertEqual(Set(defaults.stringArray(forKey: suppressionKey) ?? []), ["item-pill", "item-essay"])
    }

    func testCompletedItemIsLabeledCompleteAndPurgedFromPreparationQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "completed-queue-purge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveSession(Session(
            id: "completed-item-session",
            itemId: "item-pill",
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: "item-pill",
            position: Position(charOffset: 990),
            completionPercent: 99,
            playbackRate: 1
        ))
        try store.saveAudioPreparationJob(AudioPreparationJob(
            id: "completed-item-job",
            itemId: "item-pill",
            manifestId: "completed-item-manifest",
            policy: .demandWindow
        ))

        let reloadedModel = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        reloadedModel.bootstrapLibraryIfNeeded()

        XCTAssertEqual(reloadedModel.libraryItems.first(where: { $0.id == "item-pill" })?.isCompleted, true)
        // Launch refreshes the queue off the main actor (#2507), so its purge lands a moment after bootstrap returns.
        try await waitFor("the launch refresh to purge the completed item's job") {
            (try? store.loadAudioPreparationJobs().contains(where: { $0.itemId == "item-pill" })) == false
        }
        XCTAssertFalse(reloadedModel.audioPreparationQueue.contains(where: { $0.itemId == "item-pill" }))
        XCTAssertFalse(try store.loadAudioPreparationJobs().contains(where: { $0.itemId == "item-pill" }))
    }

    func testPreparationQueueDropsPodcastTranscriptsAndTrashedItemsButKeepsUnfinishedArticles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "queue-admission-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveItem(Item(
            id: "episode-with-transcript",
            title: "Episode",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: "A transcript the episode's own audio already says.",
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        ))
        try store.saveItem(Item(
            id: "article-in-the-trash", title: "Trashed", mediaType: "text", text: "Words to read aloud.",
            externalReference: nil, status: "ready"
        ))
        try store.moveItemToTrash(id: "article-in-the-trash")
        let jobs: [(id: String, itemId: String, policy: PreparationJobPolicy)] = [
            ("pill-charging", "item-pill", .whileCharging),
            ("episode-charging", "episode-with-transcript", .whileCharging),
            ("episode-buffer", "episode-with-transcript", .demandWindow),
            ("trashed-charging", "article-in-the-trash", .whileCharging),
            ("trashed-asked-for", "article-in-the-trash", .explicit),
        ]
        for (id, itemId, policy) in jobs {
            try store.saveAudioPreparationJob(AudioPreparationJob(
                id: id, itemId: itemId, manifestId: "manifest-\(id)", policy: policy
            ))
        }

        await model.refreshAudioPreparationPresentation()

        XCTAssertEqual(model.audioPreparationQueue.map(\.id), ["pill-charging"])
        XCTAssertEqual(try store.loadAudioPreparationJobs().map(\.id), ["pill-charging"])
    }

    func testActivePlaybackPreparationSortsAheadOfOtherWork() {
        let explicit = AudioPreparationJob(
            id: "explicit",
            itemId: "other-item",
            manifestId: "other-manifest",
            policy: .explicit,
            requestedAt: Date(timeIntervalSince1970: 1)
        )
        let active = AudioPreparationJob(
            id: "active",
            itemId: "active-item",
            manifestId: "active-manifest",
            policy: .whileCharging,
            requestedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(
            [explicit, active].sorted {
                Gate1AppModel.audioPreparationJobPrecedes($0, $1, activeItemId: "active-item")
            }.map(\.id),
            ["active", "explicit"]
        )
    }

    func testOpeningBufferSortsAheadOfFullItemPreparation() {
        let fullItem = AudioPreparationJob(
            id: "full-item",
            itemId: "existing-item",
            manifestId: "existing-manifest",
            policy: .explicit,
            requestedAt: Date(timeIntervalSince1970: 1)
        )
        let openingBuffer = AudioPreparationJob(
            id: "opening-buffer",
            itemId: "new-item",
            manifestId: "new-manifest",
            policy: .demandWindow,
            requestedAt: Date(timeIntervalSince1970: 2),
            maximumChunkCount: 2
        )

        XCTAssertEqual(
            [fullItem, openingBuffer].sorted(by: Gate1AppModel.audioPreparationJobPrecedes).map(\.id),
            ["opening-buffer", "full-item"]
        )
    }

    func testUserQueuePriorityOrdersJobsWithinTheSameTier() {
        let laterRequestMovedFirst = AudioPreparationJob(
            id: "moved-first",
            itemId: "item-2",
            manifestId: "manifest-2",
            policy: .whileCharging,
            requestedAt: Date(timeIntervalSince1970: 2),
            userPriority: 0
        )
        let earlierRequestMovedSecond = AudioPreparationJob(
            id: "moved-second",
            itemId: "item-1",
            manifestId: "manifest-1",
            policy: .whileCharging,
            requestedAt: Date(timeIntervalSince1970: 1),
            userPriority: 1
        )

        XCTAssertEqual(
            [earlierRequestMovedSecond, laterRequestMovedFirst]
                .sorted(by: Gate1AppModel.audioPreparationJobPrecedes)
                .map(\.id),
            ["moved-first", "moved-second"]
        )
    }

    func testOpeningAudioPreparationStopsAfterTwoChunks() {
        let plan = (0..<6).map { index in
            PreparedChunkPlan(
                index: index,
                startOffset: index * 240,
                sourceLength: 240,
                text: "Chunk \(index)"
            )
        }

        XCTAssertEqual(
            Gate1AppModel.preparationHorizon(plan: plan, maximumChunkCount: 2).map(\.index),
            [0, 1]
        )
        XCTAssertEqual(
            Gate1AppModel.preparationHorizon(plan: plan, maximumChunkCount: nil).map(\.index),
            [0, 1, 2, 3, 4, 5]
        )
    }

    func testLibraryStartOpensPlaybackWhileOpeningAudioIsStillPreparing() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = "item-pill"
        guard let index = model.libraryItems.firstIndex(where: { $0.id == itemID }) else {
            return XCTFail("Missing seeded text item")
        }
        model.libraryItems[index].startupAudioState = .preparing
        model.libraryItems[index].startupAudioTargetChunkCount = 2

        model.startItem(id: itemID)

        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(
            model.diagnostics["startupAudioPlayback:\(itemID)"],
            "started_without_waiting_for_opening_buffer"
        )
    }

    func testBackgroundPreparationWindowContinuesOnlyWhileDurableProgressIsMade() async {
        var results: [BackgroundPreparationWorkResult] = [.continueNow, .continueNow, .finished]
        var passCount = 0

        let result = await AudioPreparationBackgroundController.drain {
            passCount += 1
            return results.removeFirst()
        }

        XCTAssertEqual(result, .finished)
        XCTAssertEqual(passCount, 3)
    }

    func testBackgroundPreparationExpirationCancelsFromSchedulerQueue() async {
        let started = expectation(description: "Background work started")
        let operation = Task { @MainActor in
            await AudioPreparationBackgroundController.drain {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(60))
                    XCTFail("Expiration did not cancel ongoing preparation")
                } catch {
                    XCTAssertTrue(Task.isCancelled)
                }
                return .continueNow
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let expire = AudioPreparationBackgroundController.expirationHandler(for: operation)
        await Task.detached { expire() }.value
        let result = await operation.value
        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(result, .continueNow)
    }

    func testBackgroundPreparationWindowStopsWhenWorkMustRetryLater() async {
        var passCount = 0

        let result = await AudioPreparationBackgroundController.drain {
            passCount += 1
            return .retryLater
        }

        XCTAssertEqual(result, .retryLater)
        XCTAssertEqual(passCount, 1)
    }

    func testTrashUndoAutoDismissesAfterConfiguredDelay() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            trashUndoDismissDelay: .milliseconds(20)
        )
        model.resetAndSeed()

        model.moveItemToTrash(id: "item-pill")

        XCTAssertEqual(model.trashUndo?.itemId, "item-pill")
        try await waitFor("trash Undo to auto-dismiss") {
            model.trashUndo == nil
        }
        XCTAssertTrue(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
    }

    func testReplacingTrashUndoCancelsOlderDismissal() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            trashUndoDismissDelay: .milliseconds(80)
        )
        model.resetAndSeed()
        model.importTitle = "Second Item"
        model.importText = "A second item to delete."
        model.importTextItem()
        let secondItemId = model.selectedItem.id

        model.moveItemToTrash(id: "item-pill")
        let firstUndoId = try XCTUnwrap(model.trashUndo?.id)
        try await Task.sleep(for: .milliseconds(40))
        model.moveItemToTrash(id: secondItemId)
        let secondUndoId = try XCTUnwrap(model.trashUndo?.id)

        XCTAssertNotEqual(firstUndoId, secondUndoId)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.trashUndo?.id, secondUndoId, "The older timer must not dismiss the replacement Undo")
        try await waitFor("replacement trash Undo to auto-dismiss") {
            model.trashUndo == nil
        }
    }

    func testPermanentDeletionCannotCrossFireIntoRestore() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.moveItemToTrash(id: "item-pill")

        model.permanentlyDeleteItem(id: "item-pill")

        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        model.restoreItem(id: "item-pill")
        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
    }

    func testEmptyRecentlyDeletedPermanentlyDeletesEveryTrashedItem() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.importTitle = "Second Trashed Item"
        model.importText = "A second item with its own listening session."
        model.importTextItem()
        let secondID = model.selectedItem.id

        model.moveItemToTrash(id: "item-pill")
        model.moveItemToTrash(id: secondID)
        XCTAssertEqual(Set(model.recentlyDeletedItems.map(\.id)), ["item-pill", secondID])

        model.permanentlyDeleteRecentlyDeletedItems()

        XCTAssertTrue(model.recentlyDeletedItems.isEmpty)
        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == "item-pill" || $0.id == secondID }))
        XCTAssertNil(model.trashUndo)
    }

    /// #1035: "Permanently deleted" has to take the item's spoken Margin recordings off the phone, not
    /// only their database rows. The recordings are real files in the app's own Application Support folder.
    func testPermanentDeleteRemovesTheItemsMarginRecordingsAndKeepsALiveItemsOwn() async throws {
        // Start playback needs the Terms on a fresh simulator: with no stored answer the voice defaults to
        // James, and the Terms gate holds the start. Earlier tests in a full run happen to clear it.
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "permanent-delete-recordings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let doomedSession = try startAndEndSession(model, itemId: "item-pill")
        model.importTitle = "Second Item"
        model.importText = "A second item that stays in the Library."
        model.importTextItem()
        let liveID = model.selectedItem.id
        let liveSession = try startAndEndSession(model, itemId: liveID)
        let doomed = [
            try saveSpokenMargin(store: store, itemId: "item-pill", sessionId: doomedSession),
            try saveSpokenMargin(store: store, itemId: "item-pill", sessionId: doomedSession),
        ]
        let live = try saveSpokenMargin(store: store, itemId: liveID, sessionId: liveSession)
        let doomedFiles = try givePreparedAudioAndEpisodeMap(store: store, itemId: "item-pill")
        let liveFiles = try givePreparedAudioAndEpisodeMap(store: store, itemId: liveID)
        model.moveItemToTrash(id: "item-pill")

        model.permanentlyDeleteItem(id: "item-pill")
        // The narration file, the episode-map folder and the recordings are removed off the main thread (#2510), so they go a moment
        // after the delete returns.
        try await waitFor("the deleted item's narration, episode map folder and recordings to be removed", timeoutNanoseconds: 5_000_000_000) {
            !FileManager.default.fileExists(atPath: doomedFiles.episodeMap.path)
                && !FileManager.default.fileExists(atPath: doomedFiles.narration.path)
                && doomed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }

        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        for file in doomed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is gone with its item")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live item's recording is never touched")
        assertDeleted(doomedFiles, kept: liveFiles)
        XCTAssertTrue(try store.loadInterjections(itemId: "item-pill").isEmpty)
        XCTAssertEqual(try store.loadInterjections(itemId: liveID).count, 1)
    }

    func testRelaunchListsRecentlyDeletedItemsNewestFirstFromTheLaunchRead() throws {
        // #2508: launch builds Recently Deleted from the Library read it already made, so the rows must still be
        // exactly the trashed items, newest first, and the trashed item must stay out of the Library rows.
        let root = FileManager.default.temporaryDirectory.appending(path: "relaunch-deleted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        var ids: [String] = []
        for title in ["Older Trashed", "Newer Trashed", "Stays In Library"] {
            model.importTitle = title
            model.importText = "\(title) has some text to listen to."
            model.importTextItem()
            ids.append(model.selectedItem.id)
        }
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.moveItemToTrash(id: ids[0], at: Date(timeIntervalSince1970: 1_000))
        try store.moveItemToTrash(id: ids[1], at: Date(timeIntervalSince1970: 2_000))

        let reopened = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        reopened.bootstrapLibraryIfNeeded()

        XCTAssertEqual(reopened.recentlyDeletedItems.map(\.id), [ids[1], ids[0]])
        XCTAssertEqual(reopened.recentlyDeletedItems.map(\.status), ["Recently deleted", "Recently deleted"])
        XCTAssertFalse(reopened.libraryItems.contains { ids[0...1].contains($0.id) })
        XCTAssertTrue(reopened.libraryItems.contains { $0.id == ids[2] })
    }

    func testEmptyRecentlyDeletedRemovesEveryTrashedItemsMarginRecordings() async throws {
        // Start playback needs the Terms on a fresh simulator: with no stored answer the voice defaults to
        // James, and the Terms gate holds the start. Earlier tests in a full run happen to clear it.
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "empty-trash-recordings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        var sessions: [String: String] = [:]
        sessions["item-pill"] = try startAndEndSession(model, itemId: "item-pill")
        var ids = ["item-pill"]
        for title in ["Second Trashed Item", "Third Item That Stays"] {
            model.importTitle = title
            model.importText = "\(title) has its own listening session."
            model.importTextItem()
            let id = model.selectedItem.id
            ids.append(id)
            sessions[id] = try startAndEndSession(model, itemId: id)
        }
        let trashed = Array(ids.prefix(2))
        let liveID = ids[2]
        var doomed: [URL] = []
        for id in trashed {
            doomed.append(try saveSpokenMargin(store: store, itemId: id, sessionId: sessions[id]!))
            doomed.append(try saveSpokenMargin(store: store, itemId: id, sessionId: sessions[id]!))
        }
        let live = try saveSpokenMargin(store: store, itemId: liveID, sessionId: sessions[liveID]!)
        let doomedFiles = try trashed.map { try givePreparedAudioAndEpisodeMap(store: store, itemId: $0) }
        let liveFiles = try givePreparedAudioAndEpisodeMap(store: store, itemId: liveID)
        trashed.forEach { model.moveItemToTrash(id: $0) }
        XCTAssertEqual(Set(model.recentlyDeletedItems.map(\.id)), Set(trashed))

        model.permanentlyDeleteRecentlyDeletedItems()
        // The narration files, the episode-map folders and the recordings are removed off the main thread (#2510), so they go a moment
        // after the delete returns.
        try await waitFor("the deleted items' narration, episode map folders and recordings to be removed", timeoutNanoseconds: 5_000_000_000) {
            doomedFiles.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.episodeMap.path)
                    && !FileManager.default.fileExists(atPath: $0.narration.path)
            }
                && doomed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        }

        XCTAssertTrue(model.recentlyDeletedItems.isEmpty)
        for file in doomed {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is gone with its item")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live item's recording is never touched")
        doomedFiles.forEach { assertDeleted($0, kept: liveFiles) }
        XCTAssertTrue(try trashed.allSatisfy { try store.loadInterjections(itemId: $0).isEmpty })
        XCTAssertEqual(try store.loadInterjections(itemId: liveID).count, 1)
    }

    /// #1043 APM-13: the other files a permanent delete must take with an item. Prepared narration in
    /// Application Support/PreparedSupertonicAudio, named by the item's media, and the item's episode-map
    /// folder under SpokenMargins/EpisodeMaps, both where the app writes them. Removed when the test ends.
    private func givePreparedAudioAndEpisodeMap(store: SQLiteSessionStore, itemId: String) throws -> (narration: URL, episodeMap: URL) {
        let support = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let audioFolder = support.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        let narration = audioFolder.appending(path: "test-1043-\(UUID().uuidString).caf")
        try Data("prepared narration".utf8).write(to: narration)
        addTeardownBlock { try? FileManager.default.removeItem(at: narration) }
        var item = try store.loadItem(id: itemId)
        item.media = ItemMedia(sourceType: .generatedTTSPrerendered, url: narration.absoluteString, durationMs: 1_000)
        try store.saveItem(item)

        let episodeMap = support
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: PodcastAnchorEvidencePaths.safeComponent(itemId), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: episodeMap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: episodeMap.appending(path: "map.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: episodeMap) }
        return (narration, episodeMap)
    }

    private func assertDeleted(
        _ doomed: (narration: URL, episodeMap: URL),
        kept live: (narration: URL, episodeMap: URL),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let files = FileManager.default
        XCTAssertFalse(files.fileExists(atPath: doomed.narration.path), "the deleted item's prepared narration is gone", file: file, line: line)
        XCTAssertFalse(files.fileExists(atPath: doomed.episodeMap.path), "the deleted item's episode map is gone", file: file, line: line)
        XCTAssertTrue(files.fileExists(atPath: live.narration.path), "a live item's prepared narration stays", file: file, line: line)
        XCTAssertTrue(files.fileExists(atPath: live.episodeMap.path), "a live item's episode map stays", file: file, line: line)
    }

    private func startAndEndSession(_ model: Gate1AppModel, itemId: String) throws -> String {
        model.startItem(id: itemId)
        let sessionId = try XCTUnwrap(
            model.snapshot.sessionId,
            "no session started for \(itemId): \(model.diagnostics["termsGate"] ?? "no Terms gate"), \(model.statusMessage)"
        )
        model.endSession()
        return sessionId
    }

    /// A spoken Margin the way the recorder leaves it: an audio file under Application Support and a row
    /// naming it. The file is removed when the test ends even if the app under test didn't.
    private func saveSpokenMargin(store: SQLiteSessionStore, itemId: String, sessionId: String) throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "SpokenMargins/interjections", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "test-1035-\(UUID().uuidString).m4a")
        try Data("a spoken Margin".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var margin = shareableInterjection(itemId: itemId)
        margin.sessionId = sessionId
        margin.audioPath = "SpokenMargins/interjections/\(file.lastPathComponent)"
        margin.audioStatus = "recorded"
        try store.saveInterjection(margin)
        return file
    }

    /// #1043 APM-06: with a player that reports no position, "resume where I stopped" and "start over" looked the
    /// same. The player here reports a place two sentences in, and the resume must start there, from memory and
    /// after a relaunch reads the session back from SQLite.
    func testStoppingTextPlaybackKeepsSessionInProgressAndResumable() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let root = FileManager.default.temporaryDirectory.appending(path: "resume-position-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, databaseURLOverride: databaseURL)
        model.resetAndSeed()
        model.importTitle = "Resume Position"
        model.importText = "One. Two. Three. Four."
        model.importTextItem()
        let sessionId = model.snapshot.sessionId
        let stoppedAt = "One. Two. ".count
        audio.currentOffset = stoppedAt

        model.endSession()

        XCTAssertNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.phase, .idle)
        XCTAssertEqual(model.snapshot.status, .idle)
        XCTAssertFalse(model.shouldShowMiniPlayer)
        XCTAssertEqual(model.feedbackEvent?.kind, .success)
        XCTAssertEqual(model.feedbackEvent?.message, "Session saved. You can resume it later.")
        let saved = model.selectedItem.sessions.first(where: { $0.id == sessionId })
        XCTAssertEqual(saved?.status, "in_progress")
        XCTAssertLessThan(saved?.completionPercent ?? 100, 100)
        let store = try SQLiteSessionStore(path: databaseURL.path)
        XCTAssertEqual(try XCTUnwrap(store.loadSession(id: try XCTUnwrap(sessionId))).position.charOffset, stoppedAt)
        model.dismissFeedback()
        if let saved {
            model.resumeSession(saved)
        }
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(model.feedbackEvent)
        XCTAssertEqual(audio.playedOffsets.last, stoppedAt, "resume starts where the listener stopped, not at the top")
        XCTAssertEqual(model.snapshot.currentTextStart, stoppedAt)
        model.endSession()

        let relaunchedAudio = WorkflowRecordingAudioClient()
        let relaunched = Gate1AppModel(audioPlaybackClient: relaunchedAudio, databaseURLOverride: databaseURL)
        relaunched.bootstrapLibraryIfNeeded()
        relaunched.resumeSession(try XCTUnwrap(store.loadSession(id: try XCTUnwrap(sessionId))))
        XCTAssertEqual(relaunched.snapshot.sessionId, sessionId)
        XCTAssertEqual(relaunchedAudio.playedOffsets.last, stoppedAt, "a relaunched app resumes from the stored place")
    }

    func testHomePlayResumesLatestSessionWithoutCreatingAnother() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        let countBefore = model.selectedItem.sessions.count

        model.openHome()
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.selectedItem.sessions.count, countBefore)
        XCTAssertEqual(model.snapshot.status, .playing)
    }

    func testHomeReflectsCompletionAndReplayPreservesBothPriorSessions() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let olderSessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.startNewSession(id: "item-pill")
        let completedSessionID = try XCTUnwrap(model.snapshot.sessionId)
        XCTAssertNotEqual(completedSessionID, olderSessionID)

        // Starting a new session first persists the older session immediately.
        // Wait before updating the new session so their whole-second persisted
        // timestamps exercise newest-session ordering without a UUID tie-break.
        try await Task.sleep(for: .seconds(1.1))
        model.skipUnit = "section"
        model.skipForward()
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        model.openHome()

        let row = try XCTUnwrap(model.libraryItems.first(where: { $0.id == "item-pill" }))
        XCTAssertTrue(row.hasContinuationSession)
        XCTAssertEqual(row.continuationProgressPercent, 100)

        let sessionCount = model.selectedItem.sessions.count
        model.startItem(id: "item-pill")

        XCTAssertNotEqual(model.snapshot.sessionId, completedSessionID)
        XCTAssertNotEqual(model.snapshot.sessionId, olderSessionID)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 0)
        XCTAssertEqual(model.selectedItem.sessions.count, sessionCount + 1)
        XCTAssertTrue(model.selectedItem.sessions.contains { $0.id == completedSessionID })
        XCTAssertTrue(model.selectedItem.sessions.contains { $0.id == olderSessionID })
    }

    func testFinishedSessionAtOneHundredPercentIsPreferredOverOlderInProgressSession() throws {
        let decoder = JSONDecoder()
        let older = try decoder.decode(Session.self, from: Data("""
        {"id":"older","itemId":"item-pill","status":"in_progress","phase":"item_playback","currentTargetType":"item_text_tts","currentTargetId":"item-pill","position":{"charOffset":0},"completionPercent":0,"playbackRate":1}
        """.utf8))
        let completed = try decoder.decode(Session.self, from: Data("""
        {"id":"completed","itemId":"item-pill","status":"finished","phase":"finished","currentTargetType":"item_text_tts","currentTargetId":"item-pill","position":{"charOffset":100},"completionPercent":100,"playbackRate":1}
        """.utf8))

        XCTAssertEqual(Gate1AppModel.preferredContinuationSession(in: [completed, older])?.id, completed.id)
    }

    func testExplicitStartNewSessionCreatesOneAdditionalSession() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let firstSessionID = try XCTUnwrap(model.snapshot.sessionId)

        model.startNewSession(id: "item-pill")

        XCTAssertNotEqual(model.snapshot.sessionId, firstSessionID)
        XCTAssertEqual(model.selectedItem.sessions.count, 2)
    }



    func testUnavailableLocalModelDoesNotCreateSummaryJobs() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .unavailable("Unsupported test device"))
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let snapshotBefore = model.snapshot
        let turnsBefore = model.selectedItem.turns

        model.summarize()

        XCTAssertFalse(model.aiSummaryExperienceAvailable)
        XCTAssertEqual(model.snapshot, snapshotBefore)
        XCTAssertEqual(model.selectedItem.turns, turnsBefore)
        XCTAssertEqual(model.diagnostics["summaryPreflight"], "local_model_unavailable")
    }

    func testAvailableLocalFoundationModelCompletesInterjectionSummaryWithoutAPIKey() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "Structure helps me remember the source." },
            localFoundationModelClient: WorkflowFoundationModelStub(
                availability: .available,
                summary: "The listener wants to preserve the relationship between structure and recall."
            )
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        XCTAssertEqual(model.selectedItem.interjections.count, 1)
        XCTAssertTrue(model.canSummarizeInterjections)

        model.summarize()

        try await waitFor("local summary completion") {
            model.diagnostics["lastSummaryMode"] == "apple_foundation_on_device"
        }
        XCTAssertTrue(model.selectedItem.turns.contains {
            $0.turnType == "interjection_summary"
                && $0.text?.contains("relationship between structure and recall") == true
        })
    }

    func testFailedLocalSummaryExitsBusyStateAndCanBeRetried() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "I am uncertain whether this premise supports the conclusion." },
            localFoundationModelClient: ThrowingWorkflowFoundationModelStub()
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("listener note transcription") {
            model.selectedItem.interjections.first?.transcriptionStatus == "transcribed"
        }

        model.summarize()

        try await waitFor("local summary failure") {
            model.diagnostics["lastSummaryMode"] == "apple_foundation_failed"
        }
        // The controls read the job table off the main thread, once per session state (#2508).
        await model.settleSummaryRecords()
        XCTAssertFalse(model.isSummarizingInterjections)
        XCTAssertTrue(model.canSummarizeInterjections)
        XCTAssertTrue(model.canRetryLocalSummary)
        XCTAssertEqual(model.summaryActionTitle, "Retry Summary")
        XCTAssertEqual(model.selectedItem.turns.last(where: { $0.turnType == "interjection_summary" })?.status, "failed")
        XCTAssertEqual(model.feedbackEvent?.kind, .error)
        XCTAssertTrue(model.lastError?.contains("No cleaned-transcript fallback was saved") == true)
        XCTAssertTrue(model.lastError?.contains("Tap Retry Summary") == true)

        // #310: the banner offers Retry, and trying again another way withdraws the stale offer.
        let failure = model.feedbackEvent
        XCTAssertEqual(failure?.retry?.key, "summary")
        model.summarize()
        XCTAssertNotEqual(model.feedbackEvent?.id, failure?.id)
    }

    func testCompletedSummaryPlaybackDoesNotBlockSummarizingANewInterjection() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            interjectionTranscriptionHandler: { _ in "A newly added listener note." },
            localFoundationModelClient: WorkflowFoundationModelStub(
                availability: .available,
                summary: "A concise listener note."
            )
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        model.summarize()
        try await waitFor("first local summary completion") {
            model.selectedItem.turns.filter { $0.turnType == "interjection_summary" && $0.status == "complete" }.count == 1
        }
        // The controls read the job table off the main thread, once per session state (#2508).
        await model.settleSummaryRecords()

        XCTAssertFalse(model.isSummarizingInterjections)
        XCTAssertFalse(model.canSummarizeInterjections)

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        await model.settleSummaryRecords()

        XCTAssertTrue(model.canSummarizeInterjections)
        XCTAssertFalse(model.isSummarizingInterjections)

        model.summarize()
        try await waitFor("second local summary completion") {
            model.selectedItem.turns.contains {
                $0.turnType == "interjection_summary"
                    && $0.status == "complete"
                    && $0.sourceInterjectionIds.count == 2
            }
        }
        await model.settleSummaryRecords()
        XCTAssertFalse(model.isSummarizingInterjections)

        model.snapshot.targetType = TargetType.summaryTurnTTS.rawValue
        await model.settleSummaryRecords()
        XCTAssertFalse(model.isSummarizingInterjections)
    }

    func testDefaultReleaseBuildsDeterministicTextMapOnPasteInsteadOfUsingFoundationModel() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .available)
        )
        model.resetAndSeed()
        model.importTitle = "Deterministic Map Source"
        model.importText = "# Opening\n\nA first section.\n\n## Next Topic\n\nA second section.\n\n## Last Topic\n\nA third section."
        model.importTextItem()

        XCTAssertEqual(model.diagnostics["lastListeningMapMode"], "deterministic_headings")
        XCTAssertFalse(model.selectedItem.chapters.isEmpty)
        XCTAssertFalse(model.isGeneratingListeningMap)
    }

    func testBootstrapRestoresNewestUnfinishedSessionPausedWithoutAutoplay() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-relaunch-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
            }
        }
        let firstModel = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        firstModel.resetAndSeed()
        // #1043 APM-07: with one session in the database any selection rule passed. Four sessions here, each one
        // the answer of a different wrong rule: the oldest (first/last flipped), a newer finished one (resumable
        // filter dropped) and the newest on a trashed item (Library filter dropped).
        func listen(title: String?) throws -> (session: String, item: String) {
            if let title {
                firstModel.importTitle = title
                firstModel.importText = "One. Two. Three."
                firstModel.importTextItem()
            } else {
                firstModel.startItem(id: "item-pill")
            }
            firstModel.pause()
            return (try XCTUnwrap(firstModel.snapshot.sessionId), try XCTUnwrap(firstModel.snapshot.itemId))
        }
        let oldest = try listen(title: nil)
        let expected = try listen(title: "Newer unfinished")
        let finished = try listen(title: "Finished since")
        let trashed = try listen(title: "Trashed since")
        firstModel.moveItemToTrash(id: trashed.item)
        XCTAssertEqual(Set([oldest.item, expected.item, finished.item, trashed.item]).count, 4)

        let store = try SQLiteSessionStore(path: databaseURL.path)
        func stamp(_ sessionID: String, at seconds: TimeInterval, finished: Bool = false) throws {
            var session = try XCTUnwrap(store.loadSession(id: sessionID))
            session.updatedAt = Date(timeIntervalSince1970: seconds)
            if finished {
                session.status = "finished"
                session.phase = .finished
                session.completionPercent = 100
            } else {
                session.status = "in_progress"
                if session.phase == .abandoned || session.phase == .finished { session.phase = .itemPlayback }
            }
            try store.saveSession(session)
        }
        try stamp(oldest.session, at: 1_000)
        try stamp(expected.session, at: 3_000)
        try stamp(finished.session, at: 4_000, finished: true)
        try stamp(trashed.session, at: 5_000)

        let relaunchedAudio = WorkflowRecordingAudioClient()
        let relaunchedModel = Gate1AppModel(
            audioPlaybackClient: relaunchedAudio,
            databaseURLOverride: databaseURL
        )
        relaunchedModel.bootstrapLibraryIfNeeded()

        XCTAssertEqual(relaunchedModel.snapshot.sessionId, expected.session,
                       "the newest unfinished session on an item still in the Library")
        XCTAssertEqual(relaunchedModel.diagnostics["restoredSession"], expected.session)
        XCTAssertEqual(relaunchedModel.selectedItem.id, expected.item)
        XCTAssertEqual(relaunchedModel.snapshot.status, .paused)
        XCTAssertTrue(relaunchedAudio.playedOffsets.isEmpty, "relaunch never starts the player")
        XCTAssertFalse(relaunchedAudio.isPlaying)
        XCTAssertTrue(relaunchedModel.shouldShowMiniPlayer)
        XCTAssertEqual(relaunchedModel.diagnostics["restoredSessionMode"], "paused_without_autoplay")
    }

    func testTextImportStartsLiveSpeechWhenPreparedRenderingIsUnavailable() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        model.importTitle = "Prepared First"
        model.importText = "This text should start immediately while generated audio renders in the background."

        model.importTextItem()

        XCTAssertEqual(model.screen, .playback)
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(model.preparedTextAudioStatus, "live_fallback")
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
        model.ttsVoiceSelection = .system
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
    }

    func testTextAudioPreparationSkipsAnyCompletedOrGreaterThanNinetyEightPercentSession() {
        let atCutoff = Session(
            id: "session-at-cutoff",
            itemId: "item-native-text",
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: "item-native-text",
            position: Position(charOffset: 990),
            completionPercent: 99,
            playbackRate: 1
        )
        let belowCutoff = Session(
            id: "session-below-cutoff",
            itemId: "item-native-text",
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: "item-native-text",
            position: Position(charOffset: 980),
            completionPercent: 98,
            playbackRate: 1
        )
        var completed = belowCutoff
        completed.id = "session-completed"
        completed.status = "finished"
        completed.phase = .finished
        completed.completionPercent = 12
        var completedAtOnly = belowCutoff
        completedAtOnly.id = "session-completed-at"
        completedAtOnly.completedAt = Date(timeIntervalSince1970: 1)

        XCTAssertFalse(PreparationChunkGate.itemAlreadyListened([belowCutoff]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([atCutoff]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([completed]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([completedAtOnly]))
        XCTAssertTrue(PreparationChunkGate.itemAlreadyListened([belowCutoff, completed]))
    }

    func testResumeCompletedSessionAfterExportRequiresExplicitRestart() throws {
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
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.targetType, "item_text_tts")
        XCTAssertEqual(model.snapshot.sourceProgressPercent, 100)
        XCTAssertTrue(model.statusMessage.contains("Play from Beginning"))
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

    /// #2184: leaving the foreground saves the position but does not re-read the item on the main thread. On the owner's
    /// phone that read decoded a mapped episode's transcript as iOS waited for the app to settle, and iOS killed it.
    func testLeavingTheForegroundSavesThePositionWithoutReloadingTheItem() throws {
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        defer { OnDeviceVoiceGovernor.app.setAppBackgrounded(false) } // the background handler sets it app-wide
        model.resetAndSeed()
        model.importTitle = "Long Item"
        model.importText = "One. Two. Three."
        model.importTextItem()
        let shownOffset = try XCTUnwrap(model.selectedItem.sessions.last).position.charOffset
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)

        audio.currentOffset = "One. Two. ".count
        model.handleAppBecameInactiveOrBackground(entersBackground: true)

        XCTAssertEqual(model.diagnostics["playbackLifecycleSync"], "saved")
        let stored = try XCTUnwrap(model.store?.loadSessions(itemId: model.selectedItem.id).first { $0.id == sessionID })
        XCTAssertEqual(stored.position.charOffset, "One. Two. ".count, "the position is saved before the app is suspended")
        XCTAssertEqual(model.selectedItem.sessions.last?.position.charOffset, shownOffset, "the item is not re-read on the way out")
        XCTAssertNotEqual(shownOffset, "One. Two. ".count, "precondition: a reload would have shown the new position")

        model.syncPlaybackProgressForLifecycle()
        XCTAssertEqual(model.selectedItem.sessions.last?.position.charOffset, "One. Two. ".count, "coming back re-reads it")
    }

    func testCompletingFinalAudioRetainsFinishedSessionForReview() throws {
        let audio = WorkflowCompletionAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let completedSessionID = try XCTUnwrap(model.snapshot.sessionId)

        audio.completeCurrentTarget()
        model.syncPlaybackProgressForLifecycle()

        XCTAssertEqual(model.snapshot.sessionId, completedSessionID)
        XCTAssertEqual(model.snapshot.phase, .finished)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.statusMessage, "Session complete and saved.")
        XCTAssertEqual(
            model.selectedItem.sessions.first(where: { $0.id == completedSessionID })?.status,
            "finished"
        )
    }

    /// #142: a spoken recap Margin at the end saves at the end and returns to the finished state.
    func testSpokenMarginOnAFinishedItemSavesAtTheEndAndStaysFinished() throws {
        let audio = WorkflowCompletionAudioClient()
        // A finished speech player reports offset 0, the position #142 saved the Margin at.
        audio.reportsZeroOffsetAfterCompletion = true
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        audio.completeCurrentTarget()
        XCTAssertEqual(audio.currentCharOffset(), 0)
        model.syncPlaybackProgressForLifecycle()
        XCTAssertEqual(model.snapshot.phase, .finished)
        let marginIDsBefore = Set(model.selectedItem.interjections.map(\.id))
        let playsBefore = audio.playCount

        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        model.finishInterjection()

        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.snapshot.phase, .finished)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertFalse(model.snapshot.status.isPlaybackActive)
        XCTAssertEqual(audio.playCount, playsBefore, "the source must not restart")
        XCTAssertNil(model.lastError)
        let margin = try XCTUnwrap(model.selectedItem.interjections.first { !marginIDsBefore.contains($0.id) })
        XCTAssertEqual(margin.sessionId, sessionID)
        XCTAssertEqual(margin.anchor.startChar, model.selectedItem.text.count, "saved at the end, not at the stopped player's 0")
        XCTAssertEqual(margin.roughPercent, 100)
        XCTAssertEqual(model.selectedItem.sessions.first { $0.id == sessionID }?.status, "finished")
    }

    /// #1448: the interruption fixtures choose a voice, which writes the voice and Terms defaults.
    /// With nothing saved before, restoring must leave nothing saved, not a stale system-voice
    /// choice that changes what the next test sees.
    func testVoicePreferencesSnapshotRestoresAbsentPreferences() {
        let outer = VoicePreferencesSnapshot.capture()
        addTeardownBlock { outer.restore() }
        for key in VoicePreferencesSnapshot.keys { UserDefaults.standard.removeObject(forKey: key) }
        let snapshot = VoicePreferencesSnapshot.capture()

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.system.rawValue,
                       "the fixture's own work must be visible, or this test proves nothing")
        XCTAssertFalse(snapshot.differingKeys().isEmpty)

        snapshot.restore()
        XCTAssertEqual(snapshot.differingKeys(), [])
        for key in VoicePreferencesSnapshot.keys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key) was absent before and must be absent after")
        }
    }

    /// #1448: a saved voice and a pending Terms choice must come back as they were, including a
    /// non-default speech rate, after a voice choice overwrote them.
    func testVoicePreferencesSnapshotRestoresASavedVoiceAndPendingChoice() {
        let outer = VoicePreferencesSnapshot.capture()
        addTeardownBlock { outer.restore() }
        let defaults = UserDefaults.standard
        for key in VoicePreferencesSnapshot.keys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "supertonicVoicePendingTermsV1")
        defaults.set("supertonic", forKey: "ttsMode")
        defaults.set(0.61, forKey: "speechRate")
        let snapshot = VoicePreferencesSnapshot.capture()
        XCTAssertEqual(snapshot.differingKeys(), [])

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.system.rawValue)
        XCTAssertNil(defaults.object(forKey: "supertonicVoicePendingTermsV1"), "declining clears the pending choice")
        XCTAssertTrue(snapshot.differingKeys().contains("ttsVoiceSelection"))
        XCTAssertTrue(snapshot.differingKeys().contains("supertonicVoicePendingTermsV1"))

        snapshot.restore()
        XCTAssertEqual(snapshot.differingKeys(), [])
        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.james.rawValue)
        XCTAssertEqual(defaults.string(forKey: "supertonicVoicePendingTermsV1"), AppTTSVoiceSelection.james.rawValue)
        XCTAssertEqual(defaults.string(forKey: "ttsMode"), "supertonic")
        XCTAssertEqual(defaults.double(forKey: "speechRate"), 0.61, accuracy: 0.0001)
        XCTAssertTrue(defaults.bool(forKey: "supertonicTTSMigrationV1"))
    }

    /// #771: a call during a spoken Margin stopped the recorder while the screen still said
    /// "Recording". Now what was said is saved, marked cut short, the source waits through the call,
    /// and plays on when the call ends with "should resume".
    func testACallMidMarginSavesItCutShortAndResumesAfterTheCall() async throws {
        let voicePreferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { voicePreferences.restore() }
        let audio = WorkflowCompletionAudioClient()
        let recorder = InterruptibleRecordingClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: recorder)
        model.resetAndSeed()
        model.declineCurrentTerms() // on a fresh simulator the terms sheet would hold the start; the snapshot undoes this on teardown
        model.startItem(id: "item-pill")
        let marginIDsBefore = Set(model.selectedItem.interjections.map(\.id))
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        let playsBefore = audio.playCount

        recorder.onInterruption?(.interruptionBegan, 5)
        for _ in 0..<50 where model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(model.snapshot.isRecording, "the recording screen closes")
        XCTAssertEqual(model.snapshot.status, .paused, "the source waits through the call")
        XCTAssertEqual(audio.playCount, playsBefore)
        XCTAssertNotNil(model.selectedItem.interjections.first { !marginIDsBefore.contains($0.id) }, "what was said is saved")
        XCTAssertTrue(model.diagnostics["lastMarginCutShort"]?.contains("call_or_siri") == true)

        recorder.onInterruption?(.interruptionEnded(shouldResume: true), nil)
        for _ in 0..<50 where !model.snapshot.status.isPlaybackActive { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.snapshot.status.isPlaybackActive, "the source plays on after the call")
        XCTAssertEqual(audio.playCount, playsBefore + 1)
    }

    /// Codex audit P2 on f11032e: during the call the listener started another session and paused
    /// it. The call's end must not play that session.
    func testACallsEndDoesNotPlayASessionOpenedDuringTheCall() async throws {
        let voicePreferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { voicePreferences.restore() }
        let audio = WorkflowCompletionAudioClient()
        let recorder = InterruptibleRecordingClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: recorder)
        model.resetAndSeed()
        model.declineCurrentTerms() // on a fresh simulator the terms sheet would hold the start; the snapshot undoes this on teardown
        model.startItem(id: "item-pill")
        let interruptedSession = model.snapshot.sessionId
        model.beginInterjection()
        recorder.onInterruption?(.interruptionBegan, 5)
        for _ in 0..<50 where model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.snapshot.status, .paused)

        model.startNewSession(id: "item-pill")
        model.pause()
        XCTAssertNotEqual(model.snapshot.sessionId, interruptedSession)
        XCTAssertEqual(model.snapshot.status, .paused)
        let playsBefore = audio.playCount

        recorder.onInterruption?(.interruptionEnded(shouldResume: true), nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.snapshot.status, .paused, "the session the listener chose stays paused")
        XCTAssertEqual(audio.playCount, playsBefore)
    }

    /// #771: taking AirPods out mid-Margin saves it and leaves the source paused, so it never plays
    /// from the speaker. A start interrupted within a second is dropped.
    func testLostHeadphonesSaveAndStayPausedAndAStrayStartIsDropped() async throws {
        let audio = WorkflowCompletionAudioClient()
        let recorder = InterruptibleRecordingClient()
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: recorder)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let marginCount = model.selectedItem.interjections.count
        let playsBefore = audio.playCount

        model.beginInterjection()
        recorder.onInterruption?(.routeLost, 4)
        for _ in 0..<50 where model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(audio.playCount, playsBefore)
        XCTAssertEqual(model.selectedItem.interjections.count, marginCount + 1)

        model.beginInterjection()
        recorder.onInterruption?(.interruptionBegan, 0.3)
        for _ in 0..<50 where model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.selectedItem.interjections.count, marginCount + 1, "a stray start isn't kept")
        XCTAssertEqual(audio.playCount, playsBefore)
    }

    func testItemReplayStartsANewSessionAndPreservesTheCompletedSession() throws {
        let audio = WorkflowCompletionAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let completedID = try XCTUnwrap(model.snapshot.sessionId)
        audio.completeCurrentTarget()
        model.syncPlaybackProgressForLifecycle()
        XCTAssertEqual(model.snapshot.phase, .finished)
        model.openHome()
        model.startItem(id: "item-pill")
        XCTAssertNotEqual(model.snapshot.sessionId, completedID)
        XCTAssertEqual(model.snapshot.currentTextStart, 0)
        XCTAssertEqual(model.snapshot.phase, .itemPlayback)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.selectedItem.sessions.first { $0.id == completedID }?.status, "finished")
    }

    func testNaturalCompletionPreservesAnOpenItemAndItsFinishedSourceSession() throws {
        let audio = WorkflowCompletionAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionID = model.snapshot.sessionId
        model.openItem(id: "item-pill")
        audio.completeCurrentTarget()
        model.syncPlaybackProgressForLifecycle()
        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.phase, .finished)
        model.openPlayback()
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.phase, .finished)
    }

    /// #1577: pin the app action to #807's single rule without playing or encoding audio.
    /// This verifies the lead-in wiring and cue; hearing the saved voice still needs the owner's phone.
    func testPlayThisMomentUsesThirtySecondListeningMomentRuleAndCountdown() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-moment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        defer { model.endMarginMoment(); model.pause() }
        let store = try SQLiteSessionStore(path: databaseURL.path)
        // The Noop transport never opens this file. No voice is requested during the lead-in.
        try store.saveItem(Item(id: "moment-source", title: "Moment source", mediaType: "podcast", text: nil,
            externalReference: "local", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: root.appending(path: "source.m4a").absoluteString,
                durationMs: 180_000, nativeMediaId: "moment-source")))
        model.startItem(id: "moment-source")
        var margin = shareableInterjection(itemId: "moment-source")
        margin.sessionId = try XCTUnwrap(model.snapshot.sessionId)
        margin.anchor = Anchor(anchorType: .transcript, startChar: 0, endChar: 0,
            anchorBefore: "", anchorAfter: "", mediaTimeMs: 120_000)
        margin.audioPath = root.appending(path: "margin.m4a").path
        margin.audioStatus = "recorded"
        try store.saveInterjection(margin)
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.marginRows.first { $0.interjection.id == margin.id })

        XCTAssertTrue(model.playMarginMoment(row))

        let moment = try XCTUnwrap(model.marginMoment)
        let rule = ListeningMoment.rule(for: .playThisMoment)
        XCTAssertEqual(rule.leadInMs, 30_000, "the owner's call on #1577: keep thirty seconds and add the countdown")
        XCTAssertEqual(moment.startMediaTimeMs, 120_000 - rule.leadInMs)
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, moment.startMediaTimeMs)
        XCTAssertEqual(model.marginMomentTitle, "Your Margin")
        XCTAssertEqual(moment.targetCountdown(currentMediaTimeMs: model.snapshot.currentMediaTimeMs), "0:30")
        XCTAssertEqual(model.marginMomentClock, .media)
        XCTAssertEqual(model.screen, .playback)
    }

    /// #1670: the owner's phone, build 32: playback was set to 1× on screen, but tapping one of his Margins on a podcast
    /// played the Margin's voice and the podcast faster. The Margin's own session came back at the rate it last played
    /// at (here 1.5×, as from a text item), while the screen showed the global media rate. The test layer that should
    /// have caught it is this one: the action, with the stored session rate and the shown rate disagreeing.
    func testPlayThisMomentPlaysAtTheShownRateNotTheMarginsStoredSessionRate() throws {
        for (shown, stored) in [(1.0, 1.5), (1.5, 1.0)] {
            UserDefaults.standard.removeObject(forKey: "mediaPlaybackRate")
            defer { UserDefaults.standard.removeObject(forKey: "mediaPlaybackRate") }
            let root = FileManager.default.temporaryDirectory.appending(path: "margin-moment-rate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appending(path: "library.sqlite")
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
            model.resetAndSeed()
            defer { model.endMarginMoment(); model.pause() }
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.saveItem(Item(id: "rate-source", title: "Rate source", mediaType: "podcast", text: nil,
                externalReference: "local", status: "ready",
                media: ItemMedia(sourceType: .nativeMediaFile, url: root.appending(path: "source.m4a").absoluteString,
                    durationMs: 180_000, nativeMediaId: "rate-source")))
            model.startItem(id: "rate-source")
            var margin = shareableInterjection(itemId: "rate-source")
            margin.sessionId = try XCTUnwrap(model.snapshot.sessionId)
            margin.anchor = Anchor(anchorType: .transcript, startChar: 0, endChar: 0,
                anchorBefore: "", anchorAfter: "", mediaTimeMs: 120_000)
            margin.audioPath = root.appending(path: "margin.m4a").path
            margin.audioStatus = "recorded"
            try store.saveInterjection(margin)
            // The listener's speed now, and the rate the Margin's session last played at.
            model.setMediaPlaybackRate(shown)
            var session = try XCTUnwrap(try store.loadSession(id: margin.sessionId))
            session.playbackRate = stored
            try store.saveSession(session)
            model.refreshMarginRows()
            let row = try XCTUnwrap(model.marginRows.first { $0.interjection.id == margin.id })

            XCTAssertTrue(model.playMarginMoment(row))

            XCTAssertEqual(model.snapshot.playbackRate, shown, "the source plays at the speed shown (stored \(stored))")
            XCTAssertEqual(model.mediaPlaybackRate, shown)
            // Parse the Diagnostics line instead of matching it whole: the fix guarantees the kind and that the Margin's
            // voice and the source both ran at the shown rate; the other fields may change format freely.
            let parts = try XCTUnwrap(model.diagnostics["marginVoice.rate"]).split(separator: ";").map(String.init)
            XCTAssertEqual(parts.first, "moment")
            var fields: [String: String] = [:]
            for part in parts.dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            let voice = try XCTUnwrap(fields["voice"].flatMap(Double.init), "voice rate in \(parts)")
            let source = try XCTUnwrap(fields["source"].flatMap(Double.init), "source rate in \(parts)")
            XCTAssertEqual(voice, shown, accuracy: 0.001, "the Margin's voice reads the shown rate (stored \(stored))")
            XCTAssertEqual(source, shown, accuracy: 0.001, "Diagnostics report the source at the shown rate")
        }
    }

    /// #1577: the owner's phone, build 32: on an article read aloud on the device, Play this moment showed no
    /// countdown and played only the source from the Margin's text anchor, because a Margin anchored by text position
    /// has no media time and the moment needed one. The moment now counts narration time, so the card appears,
    /// the source goes back to a sentence about thirty seconds before the Margin, and the countdown follows the text.
    /// The test layer that should have caught it is this one: the action, on the item type where the Margin lives.
    func testPlayThisMomentOnATextAnchoredMarginInAnArticleReadAloudLeadsInAndCountsDown() throws {
        let fixture = try textAnchoredMomentFixture()
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }

        XCTAssertTrue(model.playMarginMoment(fixture.row))

        let moment = try XCTUnwrap(model.marginMoment, "the card shows; today's next showed none for this Margin")
        let clock = model.marginMomentClock
        XCTAssertEqual(clock, .liveNarration)
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(moment.target.mediaTimeMs, clock.position(forTextOffset: fixture.targetChar))
        XCTAssertEqual(moment.target.mediaTimeMs - moment.startMediaTimeMs, ListeningMoment.rule(for: .playThisMoment).leadInMs,
                       "thirty seconds, through the one moment rule (#807)")

        let leadInStart = try XCTUnwrap(model.snapshot.currentTextStart, "the source moved back for the lead-in")
        XCTAssertEqual(leadInStart % fixture.sentenceLength, 0, "reading starts at the beginning of a sentence")
        XCTAssertGreaterThanOrEqual(leadInStart, clock.textOffset(forPosition: moment.startMediaTimeMs))
        XCTAssertLessThan(leadInStart, fixture.targetChar)
        let remaining = try XCTUnwrap(moment.msUntilTarget(currentMediaTimeMs: model.marginMomentPositionMs))
        XCTAssertTrue((25_000...30_000).contains(remaining), "about thirty seconds to go, not \(remaining) ms")
        XCTAssertNotNil(moment.targetCountdown(currentMediaTimeMs: model.marginMomentPositionMs))
        XCTAssertEqual(model.diagnostics["marginMoment"]?.contains("clock=narrated_text"), true)
        XCTAssertEqual(model.screen, .playback)
    }

    /// "Play it now" on a text-anchored moment goes to the Margin's own place in the text, not to a media time.
    func testPlayItNowOnATextAnchoredMomentReadsFromTheMarginsPlace() throws {
        let fixture = try textAnchoredMomentFixture()
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.playMarginMoment(fixture.row))

        model.playMarginMomentNow()

        XCTAssertEqual(model.snapshot.currentTextStart, fixture.targetChar)
        // The Noop transport has no recording to open, so the voice is reported missing and the source goes on.
        XCTAssertEqual(model.diagnostics["marginMoment.voiceUnavailable"]?.hasSuffix(":recording_missing"), true)
    }

    /// #1646: reading starts on a sentence start, so a Margin in the stretch before that start isn't part of the moment.
    /// It used to stay in the sequence, and reading never crossed it, so the card stayed until Stop.
    /// Sentences are 40 characters; the target is at 1600, so the 30-second rule starts at 1180 and reading starts at 1200.
    /// The Margins sit inside the gap (1190) and well past the start (1300, 1700), not on the start itself.
    /// (Named to run beside the other text-moment tests: under an earlier name the same steps failed on the lane,
    /// and passed again further down the run, which points at state an earlier test leaves behind.)
    func testPlayThisMomentOnATextAnchoredMarginLeavesOutAMarginInTheGapBeforeTheSnappedStart() throws {
        let fixture = try textAnchoredMomentFixture(otherMarginChars: [1_190, 1_300, 1_700])
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.playMarginMoment(fixture.row))

        let leadInStart = try XCTUnwrap(model.snapshot.currentTextStart)
        XCTAssertEqual(leadInStart, 1_200, "reading starts at the first sentence start after the rule's 1180")
        let moment = try XCTUnwrap(model.marginMoment)
        let startChars = moment.unplayed.map { model.marginMomentClock.textOffset(forPosition: $0.mediaTimeMs) }
        XCTAssertEqual(startChars, [1_300, fixture.targetChar, 1_700], "the Margin at 1190 sits before where reading starts")
    }

    /// #1656: a skip from the Lock Screen, headphones, the Watch or CarPlay arrives through the compact controls, not
    /// `skipForward()`, so the moment wasn't told about it. A sentence skip over the next Margin played it once the
    /// next progress reading came in.
    /// Sentences are 40 characters; reading starts at 1200 and the next Margin sits at 1300, three skips on.
    func testPlayThisMomentOnATextAnchoredMarginSkippedFromTheLockScreenDoesNotPlayTheNextMargin() throws {
        let fixture = try textAnchoredMomentFixture(otherMarginChars: [1_300])
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.playMarginMoment(fixture.row))
        XCTAssertEqual(model.snapshot.currentTextStart, 1_200)

        // One progress reading after each skip, as the 500 ms ticker takes them. Without `sourceMoved()` the reading
        // after the third skip (1280 to 1320) crosses the Margin at 1300 and plays it.
        var previous = 1_200
        for _ in 0..<3 {
            model.performGate2CompactCommand(.skipForward)
            let start = try XCTUnwrap(model.snapshot.currentTextStart)
            XCTAssertGreaterThan(start, previous, "a skip moves the reading forward")
            previous = start
            model.marginMomentConductor?.observe(mediaTimeMs: model.marginMomentPositionMs)
        }

        XCTAssertGreaterThan(previous, 1_300, "the skips went past the Margin")
        let startChars = try XCTUnwrap(model.marginMoment).unplayed.map {
            model.marginMomentClock.textOffset(forPosition: $0.mediaTimeMs)
        }
        XCTAssertEqual(startChars, [1_300, fixture.targetChar], "skipping over a Margin doesn't play it")
    }

    /// #1656: a chapter tapped in Timeline is a move of the source like a skip. A heading-only chapter starting at 1320
    /// is 80 characters past 1240, under the reading limit, so without `sourceMoved()` the next reading crosses the
    /// Margin at 1300 and plays it.
    func testPlayThisMomentOnATextAnchoredMarginSkippedToAChapterDoesNotPlayTheNextMargin() throws {
        let fixture = try textAnchoredMomentFixture(otherMarginChars: [1_300], chapterStartChars: [0, 1_320])
        let model = fixture.model
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertTrue(model.playMarginMoment(fixture.row))
        model.performGate2CompactCommand(.skipForward)
        model.marginMomentConductor?.observe(mediaTimeMs: model.marginMomentPositionMs)
        XCTAssertEqual(model.snapshot.currentTextStart, 1_240, "a reading just before the Margin at 1300")

        model.jumpToChapter(Chapter(id: "ch-1", title: "Heading", startChar: 1_320, endChar: 3_200, percent: 41))
        model.marginMomentConductor?.observe(mediaTimeMs: model.marginMomentPositionMs)

        XCTAssertEqual(model.snapshot.currentTextStart, 1_320, "the chapter jump moved the reading past the Margin")
        let startChars = try XCTUnwrap(model.marginMoment).unplayed.map {
            model.marginMomentClock.textOffset(forPosition: $0.mediaTimeMs)
        }
        XCTAssertEqual(startChars, [1_300, fixture.targetChar], "jumping over a Margin doesn't play it")
    }

    /// #1660: a Skim summary lands further on in the episode, and the moment must not play the Margin the landing
    /// passed. Reading stands at 100 s, another spoken Margin sits 1 s ahead and the next scene starts 2 s on, under the
    /// 4,000 ms reading limit, so without `sourceMoved()` in `skimSeekOrStage` the next reading crosses the Margin and plays it.
    /// The moment's lead-in has the target at 120 s; the Margin ahead sits between the reading and the target.
    func testPlayThisMomentOnAPodcastSkimLandingDoesNotPlayTheMarginItPasses() throws {
        let outcome = try skimLandingOnAPodcastMoment(landingAheadMs: 2_000, otherMarginAheadMs: 1_000)

        XCTAssertEqual(outcome.landedAtMs, 102_000, "the Skim landed on the next scene")
        XCTAssertEqual(outcome.unplayedMs, [101_000, 120_000], "skimming over a Margin doesn't play it")
        XCTAssertNil(outcome.voiceAttempt, "no voice was started for the Margin the Skim passed")
    }

    /// #1660: the neighbouring landings. Each Margin sits half way to the landing. Without `sourceMoved()` the conductor
    /// takes the first three for playback and the last two for a seek (`testASkimLandingIsReadAsPlaybackOnlyWhenItIsUnderTheReadingLimit`
    /// in SessionKit pins that split); with it, none of them plays a Margin.
    func testPlayThisMomentOnAPodcastSkimLandingsOfEveryLengthDoNotPlayTheMarginsTheyPass() throws {
        for landingAheadMs in [500, 2_000, 3_900, 4_100, 30_000] {
            let outcome = try skimLandingOnAPodcastMoment(landingAheadMs: landingAheadMs, otherMarginAheadMs: landingAheadMs / 2)

            XCTAssertEqual(outcome.landedAtMs, 100_000 + landingAheadMs, "landing \(landingAheadMs) ms on")
            XCTAssertEqual(outcome.unplayedMs, [100_000 + landingAheadMs / 2, 120_000], "landing \(landingAheadMs) ms on")
            XCTAssertNil(outcome.voiceAttempt, "landing \(landingAheadMs) ms on")
        }
    }

    private struct SkimLandingOutcome {
        let landedAtMs: Int?
        /// Where the moment's unplayed Margins sit, in playback order.
        let unplayedMs: [Int]
        /// Set when the conductor tried to play a Margin's voice (the test voices don't exist, so it reports them missing).
        let voiceAttempt: String?
    }

    /// A podcast moment on a Margin at 120 s, the source reading at 100 s and another spoken Margin `otherMarginAheadMs`
    /// past that reading. A Skim then lands `landingAheadMs` past it: the bridge record is what the controller keeps
    /// for a summary that is playing, and `completeSkimBridge()` runs the landing the app runs when the summary ends.
    /// The progress ticker runs on a timer, so the test takes the readings itself, as the ticker would.
    private func skimLandingOnAPodcastMoment(landingAheadMs: Int, otherMarginAheadMs: Int) throws -> SkimLandingOutcome {
        let readingMs = 100_000
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-moment-skim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        defer { model.endMarginMoment(); model.pause() }
        let store = try SQLiteSessionStore(path: databaseURL.path)
        try store.saveItem(Item(id: "moment-source", title: "Moment source", mediaType: "podcast", text: nil,
            externalReference: "local", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: root.appending(path: "source.m4a").absoluteString,
                durationMs: 180_000, nativeMediaId: "moment-source")))
        model.startItem(id: "moment-source")
        var margin = shareableInterjection(itemId: "moment-source")
        margin.sessionId = try XCTUnwrap(model.snapshot.sessionId)
        margin.anchor = Anchor(anchorType: .transcript, startChar: 0, endChar: 0,
            anchorBefore: "", anchorAfter: "", mediaTimeMs: 120_000)
        margin.audioPath = root.appending(path: "margin.m4a").path
        margin.audioStatus = "recorded"
        try store.saveInterjection(margin)
        var other = margin
        other.id = "other-ahead"
        other.anchor = Anchor(anchorType: .transcript, startChar: 0, endChar: 0,
            anchorBefore: "", anchorAfter: "", mediaTimeMs: readingMs + otherMarginAheadMs)
        try store.saveInterjection(other)
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.marginRows.first { $0.interjection.id == margin.id })
        XCTAssertTrue(model.playMarginMoment(row))
        XCTAssertEqual(try XCTUnwrap(model.marginMoment).unplayed.count, 2, "the Margin ahead is part of the moment")

        // The listener is mid-episode: one reading at 100 s gives the conductor its place.
        XCTAssertTrue(model.seekMedia(toMediaTimeMs: readingMs))
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, readingMs)
        model.marginMomentConductor?.observe(mediaTimeMs: model.marginMomentPositionMs)

        model.snapshot.skimBridgeState = SkimBridgeState(
            direction: .forward, itemId: "moment-source", originMediaTimeMs: readingMs, summarySceneId: "scene-0",
            destinationSceneId: "scene-1", destinationMediaTimeMs: readingMs + landingAheadMs,
            summaryAssetId: "summary", wasSourcePlaying: false, status: .playing
        )
        model.completeSkimBridge()
        XCTAssertNil(model.snapshot.skimBridgeState, "the summary is over")
        let landedAtMs = model.snapshot.currentMediaTimeMs
        model.marginMomentConductor?.observe(mediaTimeMs: model.marginMomentPositionMs)

        return SkimLandingOutcome(
            landedAtMs: landedAtMs,
            unplayedMs: model.marginMoment?.unplayed.map(\.mediaTimeMs) ?? [],
            voiceAttempt: model.diagnostics["marginMoment.voiceUnavailable"]
        )
    }

    private func textAnchoredMomentFixture(
        otherMarginChars: [Int] = [],
        chapterStartChars: [Int] = []
    ) throws -> (model: Gate1AppModel, row: MarginRow, targetChar: Int, sentenceLength: Int) {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-moment-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let sentence = { (number: Int) in String(format: "Sentence %02d is one small thing to hear. ", number) }
        let text = (0..<80).map(sentence).joined()
        try store.saveItem(Item(id: "moment-article", title: "Moment article", mediaType: "text", text: text,
            externalReference: "local", status: "ready"))
        if !chapterStartChars.isEmpty {
            let chapters = chapterStartChars.enumerated().map { index, start in
                Chapter(id: "ch-\(index)", title: "Chapter \(index)", startChar: start,
                        endChar: index + 1 < chapterStartChars.count ? chapterStartChars[index + 1] : text.count,
                        percent: start * 100 / text.count)
            }
            try store.saveListeningMap(ListeningMap(id: "moment-map", itemId: "moment-article", overview: "", chapters: chapters))
        }
        model.startItem(id: "moment-article")
        XCTAssertEqual(model.snapshot.targetType, TargetType.itemTextTTS.rawValue, "read aloud on the device: no media clock")
        let sentenceLength = sentence(0).count
        let targetChar = sentenceLength * 40
        var margin = shareableInterjection(itemId: "moment-article")
        margin.sessionId = try XCTUnwrap(model.snapshot.sessionId)
        margin.anchor = Anchor(anchorType: .text, startChar: targetChar, endChar: targetChar + sentenceLength,
            anchorBefore: "", anchorAfter: "")
        XCTAssertNil(margin.anchor.mediaTimeMs, "a Margin made while the article was read aloud has only a text place")
        margin.audioPath = root.appending(path: "margin.m4a").path
        margin.audioStatus = "recorded"
        try store.saveInterjection(margin)
        for char in otherMarginChars {
            var other = margin
            other.id = "other-\(char)"
            other.anchor = Anchor(anchorType: .text, startChar: char, endChar: char + sentenceLength, anchorBefore: "", anchorAfter: "")
            try store.saveInterjection(other)
        }
        model.refreshMarginRows()
        let row = try XCTUnwrap(model.marginRows.first { $0.interjection.id == margin.id })
        return (model, row, targetChar, sentenceLength)
    }

    func testGlobalMarginSearchStarsAndSharedRowsKeepSessionIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-retrieval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        var before = model.snapshot
        let firstSession = try XCTUnwrap(before.sessionId)
        let store = try SQLiteSessionStore(path: url.path)
        try store.saveItem(Item(id: "retrieval-item", title: "Elsewhere", mediaType: "text", text: "private-source-only-marker and a useful passage", externalReference: "local", status: "ready"))
        try store.saveSession(Session(id: "retrieval-session", itemId: "retrieval-item", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "retrieval-item", position: Position(charOffset: 8), completionPercent: 10, playbackRate: 1.5))
        var original = shareableInterjection(itemId: "item-pill")
        original.id = "same-note-id"
        original.sessionId = firstSession
        original.targetId = "item-pill"
        try store.saveInterjection(original)
        for index in 0..<50 {
            var note = shareableInterjection(itemId: "retrieval-item")
            note.id = index == 23 ? "same-note-id" : "note-\(index)"
            note.sessionId = "retrieval-session"
            note.targetId = "retrieval-item"
            note.transcript = index == 23 ? "A café with an amber notebook" : "Ordinary thought \(index)"
            note.displayText = note.transcript
            note.cleanedTranscript = nil
            note.anchor = Anchor(anchorType: .text, startChar: 8, endChar: 12, anchorBefore: "before", anchorAfter: "after")
            try store.saveInterjection(note)
        }
        let layer = ImportedCommentaryLayer(id: "shared-layer", itemId: "retrieval-item", packageDigest: "shared-digest", packageId: "package", itemIdentity: SharedItemIdentity(itemType: .text, title: "Elsewhere"), displayLabel: "A shared collection", importedAt: Date())
        try store.saveImportedCommentaryLayer(layer)
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(id: "same-note-id", layerId: layer.id, packageScopedId: "shared-note", createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Shared approved words"))
        model.openHome()
        before = model.snapshot
        model.refreshMarginRows()
        model.marginCollectionQuery.text = "CAFE with an amber"
        let found = try XCTUnwrap(model.visiblePrivateMarginRows.first)
        XCTAssertEqual(model.visiblePrivateMarginRows.count, 1)
        XCTAssertEqual(found.interjection.sessionId, "retrieval-session")
        model.openMarginInTimeline(found)
        model.setMarginStarred(found, starred: true)
        XCTAssertEqual(model.snapshot, before)
        XCTAssertEqual(try store.loadInterjections(sessionId: firstSession).first?.isStarredForSharing, original.isStarredForSharing)
        let reconstructed = try SQLiteSessionStore(path: url.path)
        XCTAssertEqual(try reconstructed.loadInterjections(sessionId: "retrieval-session").first { $0.id == "same-note-id" }?.isStarredForSharing, true)
        model.marginCollectionQuery = MarginCollectionQuery(text: "", filter: .starred)
        XCTAssertEqual(model.visiblePrivateMarginRows.map(\.id), [found.id])
        model.marginCollectionQuery.itemID = "item-pill"
        XCTAssertTrue(model.visiblePrivateMarginRows.isEmpty)
        model.marginCollectionQuery.itemID = "retrieval-item"
        XCTAssertEqual(model.visiblePrivateMarginRows.map(\.id), [found.id])
        model.marginCollectionQuery = MarginCollectionQuery(filter: .shared, itemID: "item-pill")
        XCTAssertTrue(model.visibleSharedMarginRows.isEmpty)
        model.marginCollectionQuery.itemID = "retrieval-item"
        XCTAssertEqual(model.visibleSharedMarginRows.count, 1)
        XCTAssertEqual(model.snapshot, before)

        model.marginCollectionQuery = MarginCollectionQuery(text: "private-source-only-marker", filter: .all)
        XCTAssertTrue(model.visiblePrivateMarginRows.isEmpty)
        model.marginCollectionQuery = MarginCollectionQuery(text: "absent words", filter: .all)
        XCTAssertTrue(model.visiblePrivateMarginRows.isEmpty)
        model.marginCollectionQuery = MarginCollectionQuery(text: "shared approved", filter: .shared)
        XCTAssertTrue(model.visiblePrivateMarginRows.isEmpty)
        XCTAssertEqual(model.visibleSharedMarginRows.count, 1)
        XCTAssertNotEqual(model.visibleSharedMarginRows.first?.id, found.id)
        XCTAssertEqual(model.visibleSharedMarginRows.first?.collectionLabel, "A shared collection")
        XCTAssertEqual(model.snapshot, before)
        let playbackBeforeBrowsing = model.snapshot
        model.openItem(id: found.interjection.itemId)
        XCTAssertEqual(model.screen, .item)
        XCTAssertEqual(model.selectedItem.id, found.interjection.itemId)
        XCTAssertEqual(model.snapshot, playbackBeforeBrowsing)
        XCTAssertTrue(model.playMarginMoment(found))
        XCTAssertEqual(model.snapshot.itemId, "retrieval-item")
        XCTAssertEqual(model.snapshot.sessionId, "retrieval-session")
        XCTAssertEqual(model.snapshot.currentTextStart, 8)
    }

    func testGlobalMarginDestructiveActionsAndPrivateCurationAddressTheForeignSession() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        var before = model.snapshot
        let store = try SQLiteSessionStore(path: url.path)
        var foreignSession = try XCTUnwrap(store.loadSession(id: try XCTUnwrap(before.sessionId)))
        foreignSession.id = "foreign-session"
        try store.saveSession(foreignSession)
        var original = shareableInterjection(itemId: "item-pill")
        original.id = "collision"
        original.sessionId = try XCTUnwrap(before.sessionId)
        var foreign = original
        foreign.sessionId = foreignSession.id
        foreign.transcript = "Foreign words"
        try store.saveInterjection(original)
        try store.saveInterjection(foreign)
        model.syncPlaybackProgressForLifecycle()
        before = model.snapshot
        model.setInterjectionPrivateSharingNote(foreign.id, sessionId: foreign.sessionId, note: "Private foreign note")
        model.setInterjectionStarredForSharing(foreign.id, sessionId: foreign.sessionId, starred: true)
        model.deleteTranscript(interjection: foreign)
        let afterTranscript = try XCTUnwrap(store.loadInterjections(sessionId: foreign.sessionId).first)
        XCTAssertNil(afterTranscript.transcript)
        XCTAssertEqual(afterTranscript.privateSharingNote, "Private foreign note")
        XCTAssertEqual(afterTranscript.isStarredForSharing, true)
        model.deleteInterjection(foreign)
        XCTAssertEqual(try store.loadInterjections(sessionId: foreign.sessionId).first?.status, "deleted")
        XCTAssertEqual(try store.loadInterjections(sessionId: original.sessionId).first, original)
        XCTAssertEqual(model.snapshot, before)
    }

    func testDeletingAMarginOffersUndoThatBringsTheSameMarginBack() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-delete-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let store = try SQLiteSessionStore(path: url.path)
        var margin = shareableInterjection(itemId: "item-pill")
        margin.id = "undo-me"
        margin.sessionId = try XCTUnwrap(model.snapshot.sessionId)
        try store.saveInterjection(margin)

        model.deleteInterjection(margin)
        XCTAssertEqual(try store.loadInterjections(sessionId: margin.sessionId).first { $0.id == margin.id }?.status, "deleted")
        let undo = try XCTUnwrap(model.feedbackEvent?.action, "the Deleted Margin banner offers Undo")
        XCTAssertEqual(undo.title, "Undo")

        undo.perform()
        XCTAssertEqual(try store.loadInterjections(sessionId: margin.sessionId).first { $0.id == margin.id }, margin)
    }

    func testLateMicrophoneGrantCannotReplaceWrittenCaptureOrRestartCancelledCapture() async throws {
        let gate = MarginPermissionTestGate()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            microphonePermissionRequest: { await gate.request() }
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        for _ in 0..<100 where gate.continuation == nil { await Task.yield() }
        XCTAssertNotNil(gate.continuation)
        model.switchPendingVoiceCaptureToWrittenMargin()
        let draft = try XCTUnwrap(model.writtenMarginDraft)
        gate.finish(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(model.writtenMarginDraft?.captureID, draft.captureID)
        model.cancelWrittenMargin()
        model.beginInterjection()
        for _ in 0..<100 where gate.continuation == nil { await Task.yield() }
        XCTAssertNotNil(gate.continuation)
        model.cancelInterjection()
        gate.finish(true)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertEqual(model.snapshot.status, .paused)
    }

    func testDeniedMicrophoneOffersIndependentWrittenCapture() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            microphonePermissionRequest: { false }
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        for _ in 0..<100 where model.isRequestingRecordingPermission { await Task.yield() }
        XCTAssertTrue(model.recordingPermissionDenied)
        model.beginWrittenMargin()
        XCTAssertNotNil(model.writtenMarginDraft)
        XCTAssertFalse(model.recordingPermissionDenied)
        XCTAssertFalse(model.snapshot.isRecording)
        model.cancelWrittenMargin()
    }

    /// #783: while iOS hasn't asked yet, one plain line comes before the system prompt; Continue
    /// goes on to the request, and the grant records as today.
    func testUndeterminedMicrophoneShowsThePrimerBeforeTheSystemRequest() async throws {
        let gate = MarginPermissionTestGate()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            microphonePermissionRequest: { await gate.request() },
            microphonePermissionStatus: { .undetermined }
        )
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model.microphonePrimer.isShowing)
        XCTAssertTrue(model.isRequestingRecordingPermission, "The recording screen carries the line")
        XCTAssertEqual(gate.requests, 0, "iOS's prompt must wait for Continue")

        model.continueMicrophonePrimer()
        model.continueMicrophonePrimer()
        for _ in 0..<200 where gate.continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.microphonePrimer.isShowing)
        XCTAssertEqual(gate.requests, 1, "A second Continue tap must not ask twice")
        gate.finish(true)
        for _ in 0..<200 where !model.snapshot.isRecording { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.snapshot.isRecording)
        model.cancelInterjection()
    }

    /// #2852: "Don't Allow" on iOS's first microphone prompt opens a written Margin instead of an error.
    func testDecliningTheFirstMicrophonePromptOpensAWrittenMargin() async throws {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            microphonePermissionRequest: { false },
            microphonePermissionStatus: { .undetermined }
        )
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        model.addFirstMargin()
        XCTAssertTrue(model.microphonePrimer.isShowing)
        model.continueMicrophonePrimer()
        for _ in 0..<200 where model.writtenMarginDraft == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.writtenMarginDraft, "falls back to a written Margin")
        XCTAssertFalse(model.recordingPermissionDenied)
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.isOnboardingStepComplete(.sawFirstMarginPrompt), "the prompt does not come back")
        model.cancelWrittenMargin()
    }

    /// #1043 APM-02: every Margin after the first starts on the "already granted" path, and no test could reach
    /// it: a test recorder jumped straight to recording, and the path read iOS's answer rather than the test's.
    /// With the permission granted, Add Margin must record one turn after the tap, and never ask again.
    func testAnAlreadyGrantedMicrophoneRecordsAfterTheTapWithoutAskingAgain() async throws {
        let recorder = try CountingToneRecordingClient()
        defer { recorder.removeSavedFiles() }
        let gate = MarginPermissionTestGate()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: recorder,
            microphonePermissionRequest: { await gate.request() },
            microphonePermissionStatus: { .granted }
        )
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()

        model.beginInterjection()
        XCTAssertEqual(model.statusMessage, "Starting Margin...", "the tap is acknowledged before the recorder starts")
        XCTAssertTrue(model.isRequestingRecordingPermission)
        XCTAssertEqual(recorder.beginCount, 0)
        try await waitFor("the granted path to start recording") { model.snapshot.isRecording }

        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(gate.requests, 0, "a granted microphone is never asked again")
        XCTAssertFalse(model.microphonePrimer.isShowing)
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertNotNil(model.recordingPresentationContext)
        XCTAssertEqual(model.diagnostics["lastMicrophonePermissionResult"], "granted")
        model.cancelInterjection()
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    /// #1043 APM-02: the compact controls (Live Activity, widget, Lock Screen URL) had their own permission
    /// wrapper, skipped whenever a test injected a recorder. Granted records without asking; denied asks,
    /// records nothing and says why.
    func testCompactControlRecordsWithAGrantedMicrophoneAndRefusesADeniedOne() async throws {
        let recorder = try CountingToneRecordingClient()
        defer { recorder.removeSavedFiles() }
        let gate = MarginPermissionTestGate()
        let granted = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: recorder,
            microphonePermissionRequest: { await gate.request() },
            microphonePermissionStatus: { .granted }
        )
        granted.resetAndSeed()
        granted.declineCurrentTerms()
        granted.startItem(id: "item-pill")
        granted.pause()

        granted.dispatchGate2CompactCommand(.beginInterjection, origin: "live_activity")
        XCTAssertTrue(granted.isRequestingRecordingPermission, "other compact commands wait while the start is pending")
        try await waitFor("the compact control to start recording") { granted.snapshot.isRecording }
        XCTAssertEqual(recorder.beginCount, 1)
        XCTAssertEqual(gate.requests, 0)
        XCTAssertFalse(granted.isRequestingRecordingPermission)
        XCTAssertNil(granted.lastError)
        granted.dispatchGate2CompactCommand(.cancelInterjection)
        XCTAssertFalse(granted.snapshot.isRecording)

        let deniedGate = MarginPermissionTestGate()
        let denied = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: recorder,
            microphonePermissionRequest: { await deniedGate.request() },
            microphonePermissionStatus: { .denied }
        )
        denied.resetAndSeed()
        denied.declineCurrentTerms()
        denied.startItem(id: "item-pill")
        denied.pause()

        denied.dispatchGate2CompactCommand(.beginInterjection, origin: "live_activity")
        try await waitFor("the compact control to ask") { deniedGate.continuation != nil }
        XCTAssertEqual(deniedGate.requests, 1, "a microphone that isn't granted is asked")
        XCTAssertTrue(denied.isRequestingRecordingPermission)
        deniedGate.finish(false)
        try await waitFor("the refusal to land") { !denied.isRequestingRecordingPermission }
        XCTAssertFalse(denied.snapshot.isRecording)
        XCTAssertEqual(recorder.beginCount, 1, "nothing tried to record")
        XCTAssertEqual(denied.lastError, "Microphone access is required to record Margins from compact controls.")
        XCTAssertFalse(denied.recordingNavigationIsLocked)
    }

    /// #783: dismissing the line cancels that Margin like Cancel does; the next try shows it again.
    func testCancellingThePrimerCancelsTheMarginAndShowsItAgainNextTime() async throws {
        let gate = MarginPermissionTestGate()
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient(),
            microphonePermissionRequest: { await gate.request() },
            microphonePermissionStatus: { .undetermined }
        )
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        model.beginInterjection()
        XCTAssertTrue(model.microphonePrimer.isShowing)
        model.cancelInterjection()
        XCTAssertFalse(model.microphonePrimer.isShowing)
        XCTAssertFalse(model.isRequestingRecordingPermission)
        XCTAssertFalse(model.recordingNavigationIsLocked)
        model.continueMicrophonePrimer()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(gate.requests, 0)
        XCTAssertFalse(model.snapshot.isRecording)

        model.beginInterjection()
        XCTAssertTrue(model.microphonePrimer.isShowing)
        model.switchPendingVoiceCaptureToWrittenMargin()
        XCTAssertFalse(model.microphonePrimer.isShowing)
        XCTAssertNotNil(model.writtenMarginDraft)
        model.cancelWrittenMargin()
    }

    /// #783: once the listener has answered, the line never shows; a denial follows today's path.
    func testAnsweredMicrophoneNeverShowsThePrimer() async throws {
        for (status, granted) in [(PermissionPromptStatus.granted, true), (.denied, false)] {
            let model = Gate1AppModel(
                audioPlaybackClient: NoopAudioPlaybackClient(),
                recordingClient: NoopRecordingClient(),
                microphonePermissionRequest: { granted },
                microphonePermissionStatus: { status }
            )
            model.resetAndSeed()
            // On a fresh simulator this test runs first, before any other test has made the first-use
            // voice choice, so the terms sheet held startItem and nothing could record (T3 FAIL on 843e6fd).
            model.declineCurrentTerms()
            model.startItem(id: "item-pill")
            model.pause()
            model.beginInterjection()
            XCTAssertFalse(model.microphonePrimer.isShowing, "\(status)")
            // The injected answer is async and leaves the main actor, so wait on time, not yields.
            for _ in 0..<200 where model.isRequestingRecordingPermission { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(model.snapshot.isRecording, granted, "\(status)")
            XCTAssertEqual(model.recordingPermissionDenied, !granted, "\(status)")
            if granted { model.cancelInterjection() }
        }
    }

    func testAssistantMarginCaptureRetainsTurnPositionAcrossReloadAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "turn-anchors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient(), databaseURLOverride: url)
        model.resetAndSeed()
        // Complete the real first-use system-voice choice, including pending migration consent.
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        model.pause()
        let sourcePosition = model.snapshot.sourceProgressPercent
        let sessionID = try XCTUnwrap(model.snapshot.sessionId)
        var expected: [String: (String, Int)] = [:]
        for responseIndex in 0..<2 {
            model.pastedAssistantResponse = String(repeating: "Response \(responseIndex) contains a distinct argument. ", count: 80)
            model.importPastedAssistantResponse()
            XCTAssertEqual(model.snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
            XCTAssertEqual(model.snapshot.status, .playing)
            model.pause()
            let turn = try XCTUnwrap(model.selectedItem.turns.last)
            for percent in [0, 25, 50, 99] {
                let offset = (turn.text ?? "").count * percent / 100
                model.seekText(toCharOffset: offset)
                model.beginWrittenMargin()
                model.saveWrittenMargin(text: "Note \(responseIndex)-\(percent)")
                let note = try XCTUnwrap(model.selectedItem.interjections.first { $0.displayText == "Note \(responseIndex)-\(percent)" })
                XCTAssertEqual(note.targetType, .assistantTurn)
                XCTAssertEqual(note.targetId, turn.id)
                XCTAssertEqual(note.anchor.startChar, offset)
                XCTAssertLessThanOrEqual(abs(note.roughPercent - percent), 1)
                expected[note.id] = (turn.id, offset)
            }
        }
        XCTAssertEqual(model.snapshot.sourceProgressPercent, sourcePosition)
        let store = try SQLiteSessionStore(path: url.path)
        let notes = try store.loadInterjections(sessionId: sessionID)
        XCTAssertEqual(notes.count, 8)
        for note in notes {
            let identity = try XCTUnwrap(expected[note.id])
            XCTAssertEqual(note.targetId, identity.0)
            XCTAssertEqual(note.anchor.startChar, identity.1)
        }
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "anchor-export", displayName: "Anchor export", capabilities: ["sync": ["canonical_persistence"]]), repository: store)
        let exported = try engine.buildExport(options: ExportOptions(sessionId: sessionID, includeFullText: false, includeReference: false, includeListeningMap: false, includeInterjections: true))
        XCTAssertEqual(exported.interjections.count, 8)
        XCTAssertTrue(exported.interjections.allSatisfy { $0.targetType == InterjectionTargetType.assistantTurn.rawValue })
        XCTAssertEqual(Set(exported.interjections.map(\.targetId)), Set(expected.values.map { $0.0 }))
    }

    func testWrittenMarginAppDraftLocksNavigationAndSurvivesReconstruction() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "written-margin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient(), databaseURLOverride: url)
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let before = model.snapshot
        model.beginWrittenMargin()
        let capture = try XCTUnwrap(model.writtenMarginDraft)
        XCTAssertFalse(capture.priorWasPlaying)
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertTrue(model.recordingNavigationIsLocked)
        model.openLibrary()
        model.startNewSession(id: "item-pill")
        model.beginInterjection()
        XCTAssertEqual(model.snapshot.sessionId, before.sessionId)
        XCTAssertEqual(model.writtenMarginDraft?.captureID, capture.captureID)
        let words = "  A thought in my own words.\n\nKeep this spacing.  "
        model.updateWrittenMarginText(words)
        model.saveWrittenMargin(text: words)
        XCTAssertNil(model.writtenMarginDraft)
        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertEqual(model.snapshot.status, .paused)
        let store = try SQLiteSessionStore(path: url.path)
        let saved = try XCTUnwrap(store.loadInterjections(sessionId: capture.lockedSessionID).first)
        XCTAssertEqual(saved.captureKind, .written)
        XCTAssertEqual(saved.displayText, words)
        XCTAssertEqual(saved.anchor, capture.capture.anchor)
        XCTAssertNil(saved.audioPath)
        model.saveWrittenMargin(text: words)
        XCTAssertEqual(try store.loadInterjections(sessionId: capture.lockedSessionID).count, 1)
        model.beginWrittenMargin()
        model.updateWrittenMarginText("Discard this draft")
        model.cancelWrittenMargin()
        XCTAssertEqual(try store.loadInterjections(sessionId: capture.lockedSessionID).count, 1)
        XCTAssertEqual(model.snapshot.status, .paused)
    }

    func testPlaybackSpeechRateChangeRestartsActiveNativeTextAtCurrentOffset() throws {
        let voicePreferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { voicePreferences.restore() }
        SpokenMarginsTerms.recordAcceptance()
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Rate Change"
        model.importText = "One. Two. Three."

        model.importTextItem()
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(audio.playedOffsets.last, 0,
                       "The fixture must start the injected audio client")
        audio.currentOffset = "One. ".count
        model.speechRate = 0.65
        model.playbackSpeechRateChanged()

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.currentTextStart, "One. ".count)
        XCTAssertEqual(audio.playedOffsets.last, "One. ".count)
        XCTAssertEqual(try XCTUnwrap(audio.configuredSpeechRates.last), Float(0.65), accuracy: Float(0.001))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "speechRate"), 0.65, accuracy: 0.001)
    }

    func testLegacyEmbeddedPiperModeSanitizesToBundledJamesPath() {
        let defaults = UserDefaults.standard
        let keys = [
            "supertonicTTSMigrationV1",
            "supertonicVoicePendingTermsV1",
            "ttsMode",
            "ttsVoiceSelection",
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey
        ]
        let prior = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                restoreUserDefault(prior[key], forKey: key)
            }
        }
        SpokenMarginsTerms.recordAcceptance()
        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())
        model.resetAndSeed()
        model.ttsVoiceSelection = .james
        model.ttsMode = "piper"

        model.speechSettingsChanged()

        XCTAssertEqual(model.ttsMode, "supertonic")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsMode"), "supertonic")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsVoiceSelection"), "supertonic:M2")
    }

    func testPreOnePointZeroTTSMigrationKeepsJamesForASavedVoiceAndRetainsAppleFallbackVoice() {
        let voicePreferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { voicePreferences.restore() }
        let defaults = UserDefaults.standard
        for key in VoicePreferencesSnapshot.keys { defaults.removeObject(forKey: key) }
        // An earlier build saved a (now unknown) voice choice: not a fresh install, so no Phonon (#2858).
        defaults.set("piper", forKey: "ttsVoiceSelection")
        defaults.set("piper", forKey: "ttsMode")
        defaults.set("com.apple.ttsbundle.Samantha-compact", forKey: "speechVoiceIdentifier")
        SpokenMarginsTerms.recordAcceptance(in: defaults)

        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())

        XCTAssertEqual(model.ttsVoiceSelection, .james)
        XCTAssertEqual(model.ttsMode, "supertonic")
        XCTAssertEqual(model.speechVoiceIdentifier, "com.apple.ttsbundle.Samantha-compact")
        XCTAssertTrue(defaults.bool(forKey: "supertonicTTSMigrationV1"))
        XCTAssertFalse(defaults.bool(forKey: FirstRunVoiceDefault.downloadDueKey), "no download is owed to a listener with a saved voice")
    }

    /// #2858: a fresh install is given Phonon, shown as the chosen voice once the Terms are accepted, and owes its
    /// download. The Terms come first, so until then the iOS voice is the saved one and Phonon waits as the pending choice.
    func testAFreshInstallStartsOnPhononAndOwesItsDownloadUntilTheTermsAreAccepted() {
        let voicePreferences = VoicePreferencesSnapshot.capture()
        addTeardownBlock { voicePreferences.restore() }
        let defaults = UserDefaults.standard
        for key in VoicePreferencesSnapshot.keys { defaults.removeObject(forKey: key) }

        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())

        if model.phononFitsThisDevice() {
            XCTAssertEqual(model.pendingTermsVoiceSelection, .phonon)
            XCTAssertEqual(defaults.string(forKey: "supertonicVoicePendingTermsV1"), AppTTSVoiceSelection.phonon.rawValue)
            XCTAssertTrue(defaults.bool(forKey: FirstRunVoiceDefault.downloadDueKey))
        } else {
            XCTAssertEqual(model.pendingTermsVoiceSelection, .james)
            XCTAssertFalse(defaults.bool(forKey: FirstRunVoiceDefault.downloadDueKey))
        }
        XCTAssertEqual(model.ttsVoiceSelection, .system, "the iOS voice reads until the Terms are accepted")
        XCTAssertTrue(defaults.bool(forKey: "supertonicTTSMigrationV1"))
    }

    func testVoiceChangeWhilePausedDoesNotCreatePhantomPlaybackProgress() throws {
        let previousVoice = UserDefaults.standard.string(forKey: "speechVoiceIdentifier")
        defer {
            if let previousVoice {
                UserDefaults.standard.set(previousVoice, forKey: "speechVoiceIdentifier")
            } else {
                UserDefaults.standard.removeObject(forKey: "speechVoiceIdentifier")
            }
        }
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

    func testSupertonicVoiceChangeStopsPlaybackAndCanResumeFromConfirmedPosition() throws {
        let defaults = UserDefaults.standard
        let keys = [
            "supertonicTTSMigrationV1",
            "supertonicVoicePendingTermsV1",
            "ttsMode",
            "ttsVoiceSelection",
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey
        ]
        let prior = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                restoreUserDefault(prior[key], forKey: key)
            }
        }
        SpokenMarginsTerms.recordAcceptance()
        let audio = WorkflowRecordingAudioClient()
        let model = Gate1AppModel(audioPlaybackClient: audio)
        model.resetAndSeed()
        model.importTitle = "Voice switch"
        model.importText = "One sentence. A second sentence follows."
        model.importTextItem()
        audio.currentOffset = "One sentence. ".count
        let playCount = audio.playedOffsets.count

        model.ttsVoiceSelection = .lily
        model.ttsVoiceSelectionChanged()

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.currentTextStart, "One sentence. ".count)
        XCTAssertEqual(audio.playedOffsets.count, playCount)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsVoiceSelection"), "supertonic:F2")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "ttsMode"), "supertonic")

        model.resumePlayback()

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.currentTextStart, "One sentence. ".count)
        XCTAssertEqual(audio.playedOffsets.last, "One sentence. ".count)
    }

    /// A fresh simulator has never accepted the Terms, so its default bundled voice holds text playback behind the
    /// Terms sheet and nothing plays. Tests that need a playing text source accept them first, before the model is
    /// made (it reads them at init), and put the earlier answer back with the returned closure, so they pass in
    /// any order.
    private func acceptTerms() -> () -> Void {
        let keys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
        return { zip(keys, prior).forEach { self.restoreUserDefault($1, forKey: $0) } }
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func shareableInterjection(itemId: String) -> Interjection {
        Interjection(
            id: "margin-\(UUID().uuidString)",
            itemId: itemId,
            sessionId: "session-sharing-test",
            targetType: .item,
            targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 50,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: 5,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "Keep unnecessary words.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active",
            alignedTranscript: AlignedInterjectionTranscript(
                text: "Keep unnecessary words.",
                segments: [
                    .init(id: "word-keep", text: "Keep", startMs: 0, endMs: 200),
                    .init(id: "word-remove", text: "unnecessary", startMs: 240, endMs: 650),
                    .init(id: "word-words", text: "words.", startMs: 690, endMs: 950)
                ]
            )
        )
    }

    private func bulkShareableInterjection(
        itemId: String,
        id: String,
        audioPath: String
    ) -> Interjection {
        Interjection(
            id: id,
            itemId: itemId,
            sessionId: "session-sharing-bulk-test",
            targetType: .item,
            targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 50,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: 5,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: audioPath,
            audioStatus: "saved",
            transcriptionStatus: "transcribed",
            transcript: "Keep um words.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active",
            alignedTranscript: AlignedInterjectionTranscript(
                text: "Keep um words.",
                segments: [
                    .init(id: "\(id)-keep", text: "Keep", startMs: 0, endMs: 200),
                    .init(id: "\(id)-um", text: "um", startMs: 240, endMs: 380),
                    .init(id: "\(id)-words", text: "words.", startMs: 420, endMs: 700)
                ]
            )
        )
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
        // PDF extraction on a cold hosted simulator can overrun the 1 s default (#2548).
        try await waitFor("PDF import to finish", timeoutNanoseconds: 10_000_000_000) {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "Readable PDF")
        XCTAssertTrue(model.selectedItem.text.contains("A readable PDF paragraph for Spoken Margins."))
    }

    func testFilesPDFImportUsesExtractionV2AndKeepsTheAppendix() async throws {
        // v1 cut everything after the references heading, appendix included (#215).
        // Extraction v2 keeps it all in Item.text and labels the references instead.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-pdf-v2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Paper.pdf")
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 20)]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            var y: CGFloat = 60
            func draw(_ text: String, _ attributes: [NSAttributedString.Key: Any], gap: CGFloat = 18) {
                (text as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: attributes)
                y += gap
            }
            draw("The main finding held across every cohort we studied in detail.", body)
            draw("It also held when the analysis was repeated a second time.", body, gap: 30)
            draw("References", heading, gap: 30)
            // Numbered, so v1's reference rule recognises the list and cuts from here.
            draw("[1] A. Agarwal. Pituitary peptides. J Neurosci, 2005.", body)
            draw("[2] B. Brown. Sleep and memory. Nature, 2011.", body)
            draw("[3] D. Dunn. Circadian timing. Cell, 2018.", body)
            draw("[4] F. Fox. Light and mood. Science, 2020.", body, gap: 30)
            draw("Appendix", heading, gap: 30)
            draw("Supplementary methods are described in this appendix section.", body)
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()

        model.importObsidianMarkdownFiles(urls: [file])
        // Extraction runs off the main actor; on a cold hosted iOS 27 simulator
        // it overran the 1 s default (#2548), as the structured import did (#1413).
        try await waitFor("PDF import to finish", timeoutNanoseconds: 10_000_000_000) {
            !model.isImportingSources
        }

        XCTAssertTrue(model.selectedItem.text.contains("Supplementary methods are described in this appendix section."))
        XCTAssertTrue(model.selectedItem.text.contains("Pituitary peptides"), "references stay in Item.text; I14 skips them when spoken")
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
        // Alone this import takes about 0.1 s, but in the full app plan on a
        // loaded simulator it overran the 1 s default (#1413), so give it 10 s.
        try await waitFor("structured PDF import to finish", timeoutNanoseconds: 10_000_000_000) {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.title, "A Structured Report")
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Context", "Evidence", "Tradeoffs", "Recommendations", "Conclusion"])
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.status, "Ready to listen")
    }

    func testPDFContinuedContentsAreNotNarratedOrPromotedToChapters() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            let pages = [
                ["June 2006", "Publisher information remains readable."],
                ["TABLE OF CONTENTS", "I. INTRODUCTION ........ 1", "II. RESULTS ........ 7"],
                ["TABLE OF CONTENTS (Continued)", "8.4 Solar Radiation Pressure ........ 55", "References ........ 61"],
                ["I. INTRODUCTION", "Ordinary prose remains intact, including a measured value of 55"],
                ["II. RESULTS", "The results contain enough ordinary prose to establish the document body font size."]
            ]
            for lines in pages {
                context.beginPage()
                for (index, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: 40, y: 100 + index * 35), withAttributes: [
                        .font: index == 0 ? UIFont.boldSystemFont(ofSize: 20) : UIFont.systemFont(ofSize: 12)
                    ])
                }
            }
        }
        let text = try PDFStructuredTextExtractor.markdown(from: XCTUnwrap(PDFDocument(data: data)))
        XCTAssertFalse(text.contains("CONTENTS"))
        XCTAssertFalse(text.contains("........"))
        XCTAssertFalse(text.contains("Solar Radiation Pressure"))
        XCTAssertTrue(text.contains("Publisher information remains readable."))
        XCTAssertTrue(text.contains("Ordinary prose remains intact, including a measured value of 55"))
        let headings = text.components(separatedBy: .newlines).filter { $0.hasPrefix("#") }
        XCTAssertEqual(headings.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }, ["I. INTRODUCTION", "II. RESULTS"])
    }

    func testPDFRunningHeadersAreRemovedOnlyFromPageMargins() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            for page in 0..<5 {
                context.beginPage()
                let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
                ("Repeated publication header" as NSString).draw(at: CGPoint(x: 40, y: 30), withAttributes: font)
                ("Unique body paragraph \(page)." as NSString).draw(at: CGPoint(x: 40, y: 200), withAttributes: font)
                ("Repeated publication header" as NSString).draw(at: CGPoint(x: 40, y: 240), withAttributes: font)
                ("\(page + 1)" as NSString).draw(at: CGPoint(x: 300, y: 760), withAttributes: font)
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = try PDFStructuredTextExtractor.markdown(from: document)
        XCTAssertEqual(text.components(separatedBy: "Repeated publication header").count - 1, 6)
        for page in 0..<5 { XCTAssertTrue(text.contains("Unique body paragraph \(page).")) }
    }

    func testPDFOutlineMatchesNumberedVisibleHeadingWithoutDuplicatingDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-numbered-outline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Numbered Report.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            ("1 Introduction" as NSString).draw(
                at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)]
            )
            ("The first section contains ordinary body text." as NSString).draw(
                at: CGPoint(x: 40, y: 85),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
            )
        }
        let document = try XCTUnwrap(PDFDocument(url: file))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Numbered Report"]
        let outlineRoot = PDFOutline()
        let introduction = PDFOutline()
        introduction.label = "Introduction"
        introduction.destination = PDFDestination(
            page: try XCTUnwrap(document.page(at: 0)),
            at: CGPoint(x: 40, y: 740)
        )
        outlineRoot.insertChild(introduction, at: 0)
        document.outlineRoot = outlineRoot

        let markdown = try PDFStructuredTextExtractor.markdown(from: document)

        XCTAssertTrue(markdown.contains("# Numbered Report"))
        XCTAssertTrue(markdown.contains("# 1 Introduction"))
        XCTAssertFalse(markdown.contains("# Introduction"))
    }

    func testRemotePDFHandoffRoutingRecognizesShareSurfaceAndPDFPath() {
        XCTAssertTrue(Gate1AppModel.isRemotePDFHandoff(SourceLinkHandoff(
            id: "surface",
            inputURL: "https://example.com/download",
            sourceSurface: "share_sheet_pdf",
            startSession: false
        )))
        XCTAssertTrue(Gate1AppModel.isRemotePDFHandoff(SourceLinkHandoff(
            id: "safari-extension",
            inputURL: "https://arxiv.org/pdf/2609.31218v1",
            sourceSurface: SourceLinkHandoff.safariExtensionPDFSurface,
            startSession: true
        )))
        XCTAssertTrue(Gate1AppModel.isRemotePDFHandoff(SourceLinkHandoff(
            id: "extension",
            inputURL: "https://example.com/card.pdf",
            sourceSurface: "share_sheet",
            startSession: false
        )))
        XCTAssertFalse(Gate1AppModel.isRemotePDFHandoff(SourceLinkHandoff(
            id: "podcast",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            startSession: false
        )))
        XCTAssertFalse(Gate1AppModel.isRemotePDFHandoff(SourceLinkHandoff(
            id: "local-pdf",
            inputURL: "file:///AppGroup/SharedPDFHandoffs/report.pdf",
            sourceSurface: "share_sheet_pdf_file",
            startSession: false
        )))
    }

    func testPDFTableRegionIsAnnouncedOnceAndFlattenedCellsAreNotSpoken() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-table-region-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Table Report.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            for (text, y) in [("Before table.", 40), ("Alpha 10", 100), ("Beta 20", 125), ("After table.", 190)] {
                (text as NSString).draw(
                    at: CGPoint(x: 40, y: y),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
                )
            }
        }
        let document = try XCTUnwrap(PDFDocument(url: file))
        let page = try XCTUnwrap(document.page(at: 0))
        let source = try XCTUnwrap(page.attributedString?.string) as NSString
        let alphaBounds = try XCTUnwrap(page.selection(for: source.range(of: "Alpha 10"))?.bounds(for: page))
        let betaBounds = try XCTUnwrap(page.selection(for: source.range(of: "Beta 20"))?.bounds(for: page))
        let announcement = NativePDFDocumentExtractor.tableAnnouncement(pageIndex: 0, rowCount: 2, columnCount: 2)

        let markdown = try PDFStructuredTextExtractor.markdown(
            from: document,
            tableRegionsByPage: [0: [PDFDetectedTableRegion(
                bounds: alphaBounds.union(betaBounds),
                replacementText: announcement
            )]]
        )

        XCTAssertTrue(markdown.contains("Before table."))
        XCTAssertTrue(markdown.contains("After table."))
        XCTAssertEqual(markdown.components(separatedBy: announcement).count - 1, 1)
        XCTAssertFalse(markdown.contains("Alpha 10"))
        XCTAssertFalse(markdown.contains("Beta 20"))
    }

    func testNativePDFEnhancementPausesForPowerOrSeriousThermalPressure() {
        XCTAssertFalse(NativePDFDocumentExtractor.enhancedAnalysisShouldPause(
            lowPowerMode: false,
            thermalState: .fair
        ))
        XCTAssertTrue(NativePDFDocumentExtractor.enhancedAnalysisShouldPause(
            lowPowerMode: true,
            thermalState: .nominal
        ))
        XCTAssertTrue(NativePDFDocumentExtractor.enhancedAnalysisShouldPause(
            lowPowerMode: false,
            thermalState: .serious
        ))
        XCTAssertEqual(
            NativePDFDocumentExtractor.preferredCellText(
                recognized: "Violent Ilicit behavior",
                exactPDFText: "Violent Illicit behavior"
            ),
            "Violent Illicit behavior"
        )
        XCTAssertEqual(
            NativePDFDocumentExtractor.preferredCellText(
                recognized: "gpt-6 astra",
                exactPDFText: "gpt-6 astr"
            ),
            "gpt-6 astra"
        )
    }

    func testPDFOutlineDestinationsBypassContentsEntriesAndPreserveMoreThanTwelveChapters() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-pdf-contents-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Collected Stories.pdf")
        let storyTitles = (1...20).map { "Story \($0)" }
        // A PDF drawn here with UIFont.systemFont came back with no chapters on the iOS 27 simulator, which
        // falls back to TimesNewRoman, while the same file built on macOS kept all 21 on an iOS 27 iPhone
        // (#2365). The fixture is that file: a printed contents page, then 20 story pages, and an outline
        // of 20 entries. scripts/fixtures/generate-pdf-outline-fixture.swift writes it.
        let fixture = try XCTUnwrap(Bundle(for: Gate1AppModelWorkflowTests.self).url(
            forResource: "pdf-outline-collected-stories",
            withExtension: "pdf"
        ))
        try FileManager.default.copyItem(at: fixture, to: file)
        let document = try XCTUnwrap(PDFDocument(url: file))
        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 20, "the fixture carries its outline")

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importObsidianMarkdownFiles(urls: [file])
        try await waitFor("PDF contents import to finish", timeoutNanoseconds: 5_000_000_000) {
            !model.isImportingSources
        }

        XCTAssertEqual(model.selectedItem.chapters.count, 21)
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Front Matter"] + storyTitles)
        // Read safely: with too few chapters (#347) the index crashed the test host.
        XCTAssertGreaterThan(model.selectedItem.chapters.dropFirst().first?.startChar ?? 0, 0)
        XCTAssertFalse(model.selectedItem.chapters.contains(where: { $0.title == "Contents" }))
        XCTAssertTrue(zip(model.selectedItem.chapters, model.selectedItem.chapters.dropFirst()).allSatisfy {
            $0.endChar == $1.startChar
        })
    }
    #endif

    func testPlaybackControlsRemainUsableWhileObsidianImportIsPending() async throws {
        let priorTermsVersion = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let priorTermsDate = UserDefaults.standard.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            restoreUserDefault(priorTermsVersion, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            restoreUserDefault(priorTermsDate, forKey: SpokenMarginsTerms.acceptanceDateKey)
        }
        SpokenMarginsTerms.recordAcceptance()
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
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.snapshot.itemId, "item-pill")
        XCTAssertEqual(model.selectedItem.id, "item-pill")
        XCTAssertNotNil(model.libraryItems.first(where: { $0.title == "Long Import" }))
    }

    func testFollowCandidatesDeduplicateIdentityAndURLWithoutMergingDistinctFeeds() {
        let source = SourceIdentity(id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed", host: "example.com", title: "Same Title")
        let first = SourceCandidateEvidence(id: "first", source: source, evidenceURL: "https://example.com/article", relation: "html_alternate", confidence: 1)
        var duplicate = first
        duplicate.id = "second-evidence"
        var alias = first
        alias.id = "alias"
        alias.source.id = "legacy-id"
        alias.source.canonicalURL = "https://EXAMPLE.com:443/feed/#fragment"
        var distinct = first
        distinct.id = "distinct"
        distinct.source.id = "distinct-source"
        distinct.source.canonicalURL = "https://example.com/other-feed"
        XCTAssertEqual(FollowedSourceMatching.uniqueUnfollowedCandidates([first, duplicate, alias, distinct], subscriptions: []).map(\.id), ["first", "distinct"])
        let followed = FeedSubscription(id: "followed", source: alias.source, state: .muted)
        XCTAssertEqual(FollowedSourceMatching.uniqueUnfollowedCandidates([first, duplicate, alias, distinct], subscriptions: [followed]).map(\.id), ["distinct"])
    }

    func testFollowDiscoveryRechecksSubscriptionsBeforePublishing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Startup work may outlive this case. Never unlink an open SQLite/WAL
            // file; any retained UUID fixture remains in the test host's temp area.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        var pending: CheckedContinuation<[SourceCandidateEvidence], Never>?
        defer { pending?.resume(returning: []) }
        model.followCandidateDiscoveryHandler = { _, _ in
            await withCheckedContinuation { pending = $0 }
        }
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Source text.", externalReference: "https://example.com/article", status: "ready"))
        try store.saveSession(Session(id: "session-article", itemId: "article", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "article", position: Position(charOffset: 4), completionPercent: 40, playbackRate: 1))
        model.openHome()
        model.openItem(id: "article")
        model.offerFollowSuggestionIfEligible(itemId: "article", store: store)
        try await waitFor("discovery suspended") { pending != nil }
        let source = SourceIdentity(id: "source", kind: .articleFeed, canonicalURL: "https://example.com/feed", host: "example.com")
        try store.saveFeedSubscription(FeedSubscription(id: "followed", source: source))
        pending?.resume(returning: [SourceCandidateEvidence(id: "candidate", source: source, evidenceURL: "https://example.com/article", relation: "html_alternate", confidence: 1)])
        pending = nil
        try await waitFor("subscription reloaded") { model.feedSubscriptions.contains { $0.id == "followed" } }
        XCTAssertTrue(model.sourceFollowSuggestionCandidates.isEmpty)
        XCTAssertNil(try store.loadSourceSuggestionDecision(sourceId: source.id))
    }

    /// #1961: a failed Follow from a suggestion card left `followSourceFailure` empty, while the
    /// Follow button and the candidate list already recorded theirs (#244).
    func testAFailedFollowFromASuggestionRecordsTheFollowFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Never unlink an open SQLite/WAL file; see testFollowDiscoveryRechecksSubscriptionsBeforePublishing.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        model.followCandidateDiscoveryHandler = { _, _ in [] }
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Source text.", externalReference: "https://example.com/article", status: "ready"))
        model.openHome()
        model.openItem(id: "article")
        // An empty feed link is not a URL, so following it throws before any request is made.
        let source = SourceIdentity(id: "source", kind: .articleFeed, canonicalURL: "", host: "example.com")
        let candidate = SourceCandidateEvidence(id: "candidate", source: source, evidenceURL: "https://example.com/article", relation: "html_alternate", confidence: 1)
        model.sourceFollowSuggestionItemId = "article"
        model.storedSourceFollowSuggestionCandidates = [candidate]
        XCTAssertEqual(model.sourceFollowSuggestionCandidates.map(\.id), ["candidate"])
        XCTAssertNil(model.diagnostics["followSourceFailure"])

        model.acceptSourceFollowSuggestion(candidate)

        try await waitFor("follow failure recorded") { model.diagnostics["followSourceFailure"] != nil }
        XCTAssertEqual(model.diagnostics["followSourceFailure"]?.hasPrefix("invalid_url host="), true)
        XCTAssertTrue(model.feedSubscriptions.isEmpty)
        XCTAssertNil(try store.loadSourceSuggestionDecision(sourceId: source.id), "a failed follow records no decision")
    }

    /// #539: diagnostics showed a Follow failure for Noahpinion, which the owner follows. Its
    /// article on www.noahpinion.blog wasn't matched to the followed www.noahpinion.blog/feed, so
    /// opening it ran discovery again and recorded an error.
    func testAnArticleFromAFollowedSiteRunsNoDiscoveryAndRecordsNoFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Never unlink an open SQLite/WAL file; see testFollowDiscoveryRechecksSubscriptionsBeforePublishing.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        var discovered: [String] = []
        model.followCandidateDiscoveryHandler = { item, _ in
            discovered.append(item.id)
            throw FollowedSourceError.noFeedCandidates
        }
        let source = SourceIdentity(id: "source-noahpinion", kind: .articleFeed, canonicalURL: "https://www.noahpinion.blog/feed", host: "www.noahpinion.blog", title: "Noahpinion")
        // Refreshed just now, so loading subscriptions fetches nothing.
        try store.saveFeedSubscription(FeedSubscription(id: "subscription-noahpinion", source: source, lastRefreshAt: Date()))
        try store.saveItem(Item(id: "article", title: "A post", mediaType: "text", text: "Source text.", externalReference: "https://www.noahpinion.blog/p/a-post?utm_source=substack", status: "ready", externalReferenceType: "url"))
        try store.saveSession(Session(id: "session-article", itemId: "article", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "article", position: Position(charOffset: 4), completionPercent: 40, playbackRate: 1))
        model.openHome()
        model.refreshFollowedSources(force: false)
        try await waitFor("subscription loaded") { model.feedSubscriptions.contains { $0.id == "subscription-noahpinion" } }

        model.openItem(id: "article")
        model.offerFollowSuggestionIfEligible(itemId: "article", store: store)
        // The subscriptions are read in the background, so the check has to finish before the negatives mean anything.
        try await waitFor("suggestion check finished") { model.sourceSuggestionChecks.isEmpty }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(discovered, [], "a followed site is not looked up again")
        XCTAssertNil(model.diagnostics["followOffer"])
        XCTAssertNil(model.diagnostics["sourceFollowSuggestion"])
        XCTAssertNil(model.diagnostics["followSourceFailure"])
        XCTAssertFalse(model.canManuallyFollowSelectedSource)
        XCTAssertTrue(model.sourceFollowSuggestionCandidates.isEmpty)
    }

    func testLateFollowDiscoveryCannotPublishUnderAnotherItem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Startup work may outlive this case. Never unlink an open SQLite/WAL
            // file; any retained UUID fixture remains in the test host's temp area.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        var pending: [String: CheckedContinuation<[SourceCandidateEvidence], Never>] = [:]
        defer { pending.values.forEach { $0.resume(returning: []) } }
        model.followCandidateDiscoveryHandler = { item, _ in
            await withCheckedContinuation { pending[item.id] = $0 }
        }
        for id in ["alpha", "bravo"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Source text.", externalReference: "https://\(id).example/article", status: "ready"))
            try store.saveSession(Session(id: "session-\(id)", itemId: id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: id, position: Position(charOffset: 4), completionPercent: 40, playbackRate: 1))
        }
        model.openHome()
        model.openItem(id: "alpha")
        model.offerFollowSuggestionIfEligible(itemId: "alpha", store: store)
        try await waitFor("alpha discovery") { pending["alpha"] != nil }
        model.openItem(id: "bravo")
        model.offerFollowSuggestionIfEligible(itemId: "bravo", store: store)
        try await waitFor("bravo discovery") { pending["bravo"] != nil }
        let candidate: (String) -> SourceCandidateEvidence = { id in
            SourceCandidateEvidence(id: id, source: SourceIdentity(id: id, kind: .articleFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: id), evidenceURL: "https://\(id).example/article", relation: "html_alternate", confidence: 1)
        }
        pending.removeValue(forKey: "bravo")?.resume(returning: [candidate("bravo")])
        try await waitFor("bravo suggestion") { model.sourceFollowSuggestionCandidates.map(\.id) == ["bravo"] }
        pending.removeValue(forKey: "alpha")?.resume(returning: [candidate("alpha")])
        try await waitFor("stale discovery rejected") { model.diagnostics["sourceFollowSuggestion"]?.hasPrefix("discarded_stale_origin ") == true }
        XCTAssertEqual(model.sourceFollowSuggestionCandidates.map(\.id), ["bravo"])
        model.openItem(id: "alpha")
        XCTAssertTrue(model.sourceFollowSuggestionCandidates.isEmpty)
        XCTAssertNil(try store.loadSourceSuggestionDecision(sourceId: "alpha"))
    }

    func testQuickAddFeedExcludesImportedEpisodeAndDismissedFolderRevision() {
        let file = QuickAccessFile(
            id: "notes.md",
            name: "Notes",
            relativePath: "notes.md",
            modifiedAt: Date(timeIntervalSince1970: 100),
            modifiedAtDescription: "now"
        )
        let subscription = FeedSubscription(
            id: "show",
            source: SourceIdentity(
                id: "source-show",
                kind: .podcastFeed,
                canonicalURL: "https://example.com/feed.xml",
                host: "example.com",
                title: "The Show"
            )
        )
        let entry = FeedEntry(
            id: "episode",
            subscriptionId: subscription.id,
            canonicalURL: "https://example.com/feed-entry",
            title: "Already Heard"
        )
        let imported = LibraryItemRow(
            id: "imported",
            title: "Already Heard",
            status: "Ready",
            canDelete: true,
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            sourceTitle: "The Show",
            sourceReference: "https://podcasts.apple.com/episode"
        )

        let candidates = Gate1AppModel.quickAddCandidates(
            folderFiles: [file],
            followedEntries: [entry],
            subscriptions: [subscription],
            libraryItems: [imported],
            dismissedFileKeys: [file.dismissalKey]
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testQuickAddForwarderHidesAnEntryByTheLibraryRowsSourceReference() {
        let entry = FeedEntry(
            id: "episode",
            subscriptionId: "show",
            canonicalURL: "https://example.com/posts/one",
            title: "Unrelated Title"
        )
        let imported = LibraryItemRow(
            id: "imported",
            title: "Something Else",
            status: "Ready",
            canDelete: true,
            mediaType: "text",
            sourceReference: "https://Example.com/posts/one/#top"
        )

        XCTAssertTrue(Gate1AppModel.quickAddCandidates(
            folderFiles: [],
            followedEntries: [entry],
            libraryItems: [imported]
        ).isEmpty)
        XCTAssertEqual(Gate1AppModel.quickAddCandidates(
            folderFiles: [],
            followedEntries: [entry]
        ).map(\.id), ["followed-source:episode"])
    }

    func testLibraryFiltersInferLegacyPDFAndExposeActiveSelections() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.libraryItems = [
            LibraryItemRow(
                id: "paper",
                title: "Paper",
                status: "Ready",
                canDelete: true,
                mediaType: "text",
                sourceReference: "file:///Documents/paper.pdf",
                sourceReferenceType: "file"
            )
        ]
        model.libraryQuery.contentType = .pdf
        model.libraryQuery.listeningState = .unplayed
        model.libraryQuery.sort = .recentlyListened

        XCTAssertEqual(model.visibleLibraryItems.map(\.id), ["paper"])
        XCTAssertEqual(model.libraryFilterDescription, "PDF · Unplayed")
        XCTAssertEqual(model.librarySortDescription, "Recently Listened")
    }

    func testRecentlyAddedUsesStorageRecencyWhenLegacyTimestampIsMissing() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.libraryItems = [
            LibraryItemRow(
                id: "new-legacy",
                title: "New Legacy",
                status: "Ready",
                canDelete: true,
                addedAt: nil,
                storageRecencyRank: 0
            ),
            LibraryItemRow(
                id: "older-dated",
                title: "Older Dated",
                status: "Ready",
                canDelete: true,
                addedAt: Date(timeIntervalSince1970: 10),
                storageRecencyRank: 1
            )
        ]
        model.libraryQuery = LibraryQuery(listeningState: .all, sort: .recentlyAdded)

        XCTAssertEqual(model.visibleLibraryItems.map(\.id), ["new-legacy", "older-dated"])
    }

    func testPlaybackRateCycleOmitsQuarterSpeedAndWraps() {
        XCTAssertEqual(Gate1AppModel.nextPlaybackRate(after: 0.25), 0.5)
        XCTAssertEqual(Gate1AppModel.nextPlaybackRate(after: 1), 1.25)
        XCTAssertEqual(Gate1AppModel.nextPlaybackRate(after: 2), 0.5)
        XCTAssertFalse(Gate1AppModel.supportedPlaybackRates.contains(0.25))
    }

    /// #280: Follow appears only once discovery found a feed, names it from the start, and never
    /// shows for a file from the phone or a site with no feed. #243: never "Follow Podcast" on an article.
    func testFollowAppearsOnlyAfterAFeedIsFound() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Never unlink an open SQLite/WAL file; see testFollowDiscoveryRechecksSubscriptionsBeforePublishing.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        var discovered: [String] = []
        model.followCandidateDiscoveryHandler = { item, url in
            discovered.append(item.id)
            guard url.host == "www.astralcodexten.com" else { throw FollowedSourceError.noFeedCandidates }
            let source = SourceIdentity(id: "source-acx", kind: .articleFeed, canonicalURL: "https://www.astralcodexten.com/feed", host: "www.astralcodexten.com", title: "Astral Codex Ten")
            return [SourceCandidateEvidence(id: "candidate-acx", source: source, evidenceURL: url.absoluteString, relation: "substack_publication", confidence: 0.95)]
        }
        try store.saveItem(Item(id: "article", title: "The Specter of Neuralese", mediaType: "text", text: "Source text.", externalReference: "https://www.astralcodexten.com/p/the-specter-of-neuralese?utm_source=substack", status: "ready", externalReferenceType: "url"))
        try store.saveItem(Item(id: "no-feed", title: "A page", mediaType: "text", text: "Source text.", externalReference: "https://openai.com/index/a-page", status: "ready", externalReferenceType: "url"))
        try store.saveItem(Item(id: "phone-file", title: "Clipped", mediaType: "text", text: "Source text.", externalReference: "https://www.astralcodexten.com/p/clipped", status: "ready", externalReferenceType: "file"))
        // Past a quarter heard, so the suggestion card would be due too.
        try store.saveSession(Session(id: "session-phone-file", itemId: "phone-file", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "phone-file", position: Position(charOffset: 4), completionPercent: 40, playbackRate: 1))
        model.openHome()

        model.openItem(id: "article")
        XCTAssertFalse(model.canManuallyFollowSelectedSource, "nothing is offered before a feed is found")
        try await waitFor("feed found") { model.canManuallyFollowSelectedSource }
        XCTAssertEqual(model.manualFollowButtonTitle, "Follow Astral Codex Ten")
        XCTAssertEqual(model.manualFollowButtonSymbol, "newspaper")

        model.openItem(id: "no-feed")
        try await waitFor("no feed") { model.diagnostics["followOffer"]?.hasPrefix("none:") == true }
        XCTAssertFalse(model.canManuallyFollowSelectedSource)

        model.openItem(id: "phone-file")
        XCTAssertFalse(model.canManuallyFollowSelectedSource)
        await Task.yield()
        XCTAssertTrue(model.sourceFollowSuggestionCandidates.isEmpty)
        XCTAssertFalse(discovered.contains("phone-file"), "a file from the phone is never looked up, by the button or the card")

        // Reopening reuses the result: the label is the same and nothing is fetched again.
        model.openItem(id: "article")
        XCTAssertTrue(model.canManuallyFollowSelectedSource)
        XCTAssertEqual(discovered.filter { $0 == "article" }.count, 1)

        // A Safari import or Continue listening selects the item without openItem; Follow still comes.
        try store.saveItem(Item(id: "imported", title: "Imported", mediaType: "text", text: "Source text.", externalReference: "https://www.astralcodexten.com/p/imported?r=abc", status: "ready", externalReferenceType: "url"))
        model.selectedItem = ItemDetailState(id: "imported", title: "Imported", isNativeAudio: false)
        try await waitFor("feed found without openItem") { model.canManuallyFollowSelectedSource }
        XCTAssertEqual(model.manualFollowButtonTitle, "Follow Astral Codex Ten")
    }

    func testFollowedSourceIdentityUsesCanonicalURLInsteadOfDisplayTitle() {
        let subscription = FeedSubscription(
            id: "show",
            source: SourceIdentity(
                id: "source-show",
                kind: .podcastFeed,
                canonicalURL: "https://EXAMPLE.com/feed.xml/",
                host: "example.com",
                title: "Publisher Feed Title"
            )
        )

        XCTAssertTrue(FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: "https://example.com/feed.xml",
            sourceTitle: "Imported Podcast Title",
            subscriptions: [subscription]
        ))
    }

    func testDifferentCanonicalSourceDoesNotHideManualFollowForMatchingTitle() {
        let subscription = FeedSubscription(
            id: "other-show",
            source: SourceIdentity(
                id: "source-other-show",
                kind: .podcastFeed,
                canonicalURL: "https://other.example/feed.xml",
                host: "other.example",
                title: "The Show"
            )
        )

        XCTAssertFalse(FollowedSourceMatching.isSourceAlreadyFollowed(
            sourceURL: "https://example.com/feed.xml",
            sourceTitle: "The Show",
            subscriptions: [subscription]
        ))
    }

    func testPublisherChaptersAreNotPresentedAsANeedForAListeningMap() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.selectedItem = ItemDetailState(
            id: "episode",
            title: "An Episode",
            status: "needs_listening_map",
            mediaChapters: [
                MediaTimelineChapter(
                    id: "publisher-opening",
                    title: "Opening",
                    startMs: 0,
                    transcriptSegmentId: "publisher-opening-segment"
                )
            ],
            isNativeAudio: true
        )

        XCTAssertFalse(model.canGenerateListeningMap)
        XCTAssertEqual(
            model.listeningMapGenerationAvailabilityDescription,
            "This podcast already includes publisher chapters. A generated Listening Map is unnecessary."
        )
    }

    /// Every field of a Library row except `storageRecencyRank`, so a new field is still compared.
    private func libraryRowFieldsExceptStorageRank(_ row: LibraryItemRow) -> [String] {
        Mirror(reflecting: row).children
            .filter { $0.label != "storageRecencyRank" }
            .map { "\($0.label ?? "?")=\(String(describing: $0.value))" }
    }

    private func waitFor(
        _ description: String,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
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

private actor BulkSharePreparationProbe {
    private var activeRenders = 0
    private var maximumConcurrentRenders = 0
    private var renderCount = 0

    /// What this renderer writes as the cleaned copy, so a test can tell it from the original recording.
    static let cleanedBytes = Data("cleaned voice".utf8)

    /// Behaves like `InterjectionAudioCleanupRenderer` on the filesystem: it clears whatever is at the destination,
    /// then writes the cleaned copy there. A model that handed over the recording as its own destination would
    /// lose the owner's original here, as it would on the phone (#1043 APM-04).
    func render(
        sourceURL: URL,
        destinationURL: URL,
        decisions: [InterjectionCleanupDecision]
    ) async throws -> Int {
        XCTAssertFalse(decisions.isEmpty)
        XCTAssertNotEqual(
            destinationURL.standardizedFileURL.path, sourceURL.standardizedFileURL.path,
            "the cleaned copy must never be written over the recording"
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.cleanedBytes.write(to: destinationURL)
        activeRenders += 1
        maximumConcurrentRenders = max(maximumConcurrentRenders, activeRenders)
        defer { activeRenders -= 1 }
        try await Task.sleep(for: .milliseconds(1))
        renderCount += 1
        return 625
    }

    func snapshot() -> (renderCount: Int, maximumConcurrentRenders: Int) {
        (renderCount, maximumConcurrentRenders)
    }
}

/// A cleanup render that finishes only when the test lets it, and ignores cancellation, as an export already
/// under way does. It then writes its copy at the destination it was given (#1043 APM-08).
private actor HeldCleanupRender {
    private var release: CheckedContinuation<Void, Never>?
    private(set) var heldDestination: URL?
    private(set) var hasReturned = false
    /// The copy was on disk when the render returned, before the model could react to it.
    private(set) var wroteCopy = false

    func render(destinationURL: URL) async throws -> Int {
        await withCheckedContinuation { continuation in
            release = continuation
            heldDestination = destinationURL
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BulkSharePreparationProbe.cleanedBytes.write(to: destinationURL)
        wroteCopy = FileManager.default.fileExists(atPath: destinationURL.path)
        hasReturned = true
        return 625
    }

    func finish() {
        release?.resume()
        release = nil
    }
}

private struct SchemaFiveIngestionLinkResolver: LinkResolutionClient {
    var result: LinkResolutionResult

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(
                url: request.inputURL,
                provider: result.originalLink.provider,
                title: result.originalLink.title,
                role: result.originalLink.role
            ),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private struct SchemaFiveNoopSourceTranscriptionClient: SourceTranscriptionClient {
    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_schema_five_ingestion_test")
    }
}

private struct WorkflowFoundationModelStub: LocalFoundationModelClient {
    let configuredAvailability: LocalFoundationModelAvailability
    let summary: String

    init(
        availability: LocalFoundationModelAvailability,
        summary: String = "Local summary"
    ) {
        configuredAvailability = availability
        self.summary = summary
    }

    func availability() -> LocalFoundationModelAvailability {
        configuredAvailability
    }

    func summarizeInterjections(context: String) async throws -> String {
        summary
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        LocalListeningMapLabel(title: "Chapter \(chapterNumber)", description: "A bounded section description.")
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        "A bounded local listening map."
    }
}

private struct ThrowingWorkflowFoundationModelStub: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability {
        .available
    }

    func summarizeInterjections(context: String) async throws -> String {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }

    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        throw LocalFoundationModelError.invalidInterjectionSummary
    }

    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        throw LocalFoundationModelError.invalidInterjectionSummary
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
    var playbackVolumes: [Float] = []
    var configuredSpeechRates: [Float] = []
    var configuredSpeechVoices: [String?] = []
    var currentOffset: Int?
    /// Whether the player was last told to play or to stop. `stop()` falls back to `pause()`, so both clear it.
    private(set) var isPlaying = false
    private var activeTargetId: String?

    func setPlaybackVolume(_ volume: Float) throws {
        playbackVolumes.append(volume)
    }

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
        isPlaying = true
    }

    func pause() throws {
        isPlaying = false
    }

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

private final class MixedAudioPolicyRecordingClient: AudioPlaybackClient {
    var mixingStates: [Bool] = []
    var backgroundAudioStates: [Bool] = []
    var playbackVolumes: [Float] = []
    var remoteCommandHandlingStates: [Bool] = []

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {}

    func pause() throws {}

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixingStates.append(enabled)
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        backgroundAudioStates.append(enabled)
    }

    func setPlaybackVolume(_ volume: Float) throws {
        playbackVolumes.append(volume)
    }

    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {
        remoteCommandHandlingStates.append(enabled)
    }
}

/// Records nothing, like `NoopRecordingClient`, and lets a test send the interruptions the real
/// recorder reports (#771).
private final class InterruptibleRecordingClient: RecordingClient, RecordingInterruptionReporting, @unchecked Sendable {
    var onInterruption: (@Sendable (_ event: MarginRecordingInterruptionEvent, _ recordedSeconds: TimeInterval?) -> Void)?
    func beginRecording() throws {}
    func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/interrupted.m4a" }
    func cancelRecording() throws {}
}

private final class WorkflowCompletionAudioClient: AudioPlaybackClient {
    private let lock = NSLock()
    private var preparedText = ""
    private var activeTargetId: String?
    private var completedTargetId: String?
    private var currentOffset = 0
    private(set) var playCount = 0
    /// Like a real speech player, report offset 0 once the target has finished.
    var reportsZeroOffsetAfterCompletion = false

    func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        lock.lock()
        preparedText = normalized
        lock.unlock()
        return normalized
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        lock.lock()
        activeTargetId = targetId
        completedTargetId = nil
        currentOffset = charOffset
        playCount += 1
        lock.unlock()
    }

    func pause() throws {}

    func stop() throws {
        lock.lock()
        activeTargetId = nil
        completedTargetId = nil
        lock.unlock()
    }

    func currentCharOffset() -> Int? {
        lock.lock()
        let offset = currentOffset
        lock.unlock()
        return offset
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        lock.lock()
        let complete = completedTargetId == targetId
        lock.unlock()
        return complete
    }

    func completeCurrentTarget() {
        lock.lock()
        currentOffset = reportsZeroOffsetAfterCompletion ? 0 : preparedText.count
        completedTargetId = activeTargetId
        lock.unlock()
    }
}

/// A recorder that counts every call and, like `SystemRecordingClient`, leaves a real AAC file in
/// Application Support/SpokenMargins/interjections and returns its path from there. The tests that used
/// `NoopRecordingClient` could not see whether the microphone was ever asked to start, or whether a saved
/// Margin had any audio behind it (#1043 APM-01, APM-03).
private final class CountingToneRecordingClient: RecordingClient {
    let supportDirectory: URL
    private let tone: UITestingToneRecordingClient
    /// The next starts throw, as `AVAudioRecorder.record()` returning false or a call holding the session does.
    var refusesToStart = false
    /// The next finishes throw before anything is saved, as a recorder whose file can't be closed would.
    var refusesToFinish = false
    private(set) var beginCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var savedPaths: [String] = []

    init() throws {
        supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        tone = UITestingToneRecordingClient(supportDirectory: supportDirectory)
    }

    func beginRecording() throws {
        beginCount += 1
        if refusesToStart { throw SessionKitError.persistenceFailed("recording_failed") }
        try tone.beginRecording()
    }

    func finishRecording(audioRef: String?) throws -> String {
        finishCount += 1
        if refusesToFinish { throw SessionKitError.persistenceFailed("recording_finish_failed") }
        let path = try tone.finishRecording(audioRef: audioRef)
        savedPaths.append(path)
        return path
    }

    func cancelRecording() throws {
        cancelCount += 1
        try tone.cancelRecording()
    }

    func removeSavedFiles() {
        for path in savedPaths { try? FileManager.default.removeItem(at: supportDirectory.appending(path: path)) }
    }
}

/// The audio paths the transcription step was handed, read from the test.
private final class TranscribedAudioPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.withLock { paths.append(path) } }
    var all: [String] { lock.withLock { paths } }
}

@MainActor
private final class MarginPermissionTestGate {
    var continuation: CheckedContinuation<Bool, Never>?
    private(set) var requests = 0
    func request() async -> Bool {
        requests += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ granted: Bool) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: granted)
    }
}

/// Records every URL asked of its session and fails it, so a test can say a request was never made (#2772).
private final class GuidedTourRequestCountingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var urls: [String] = []

    static func reset() { lock.withLock { urls = [] } }
    static var requested: [String] { lock.withLock { urls } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.urls.append(request.url?.absoluteString ?? "") }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
