import Combine
import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp
import SQLite3
#if canImport(UIKit)
import UIKit
import PDFKit
#endif

@MainActor
final class Gate1AppModelWorkflowTests: XCTestCase {
    func testRichClipboardRestoresOnlyExplicitHTMLHeadings() {
        let plain = "Article & notes\nA paragraph.\nNext section\nMore prose."
        let html = "<h1>Article &amp; notes</h1><p>A paragraph.</p><h2><em>Next section</em></h2><p>More prose.</p>"
        XCTAssertEqual(Gate1AppModel.pastedSourceText(plainText: plain, html: html),
                       "# Article & notes\nA paragraph.\n## Next section\nMore prose.")
        XCTAssertEqual(Gate1AppModel.pastedSourceText(plainText: plain, html: nil), plain)
    }

    func testItemMarginsOpenExportWithAllSessionMarginsWithoutChangingPlayback() throws {
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
        model.openMarginItemExport(itemID: row.interjection.itemId)
        XCTAssertEqual(model.screen, .export)
        XCTAssertEqual(model.exportShareCandidates.count, 2)
        model.prepareExportShareInterjections()
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.sharingState.drafts.count, 2)
        XCTAssertEqual(model.snapshot.sessionId, session)
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

    func testSleepTimerExpiryDefersThroughInterjectionRecording() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.armSleepTimer(.minutes15)
        guard case .armed(_, let deadline?, _) = model.sleepTimerState else {
            return XCTFail("Expected armed sleep timer")
        }
        model.snapshot.isRecording = true
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(1))
        XCTAssertEqual(model.sleepTimerState, .expiryDeferred(mode: .minutes15))

        model.snapshot.isRecording = false
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(2))
        XCTAssertEqual(model.sleepTimerState, .inactive)
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
    /// left them unplaced, the Timeline row says that, not "Position not matched", which reads as a match that
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
        XCTAssertEqual(fingerprinted.positionDescription, "Position not matched")

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
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)

        let firstID = try XCTUnwrap(model.sharingState.drafts.first?.id)
        model.undoShareDraftEdit(firstID)
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep um words.")
        model.redoShareDraftEdit(firstID)
        XCTAssertEqual(model.sharingState.drafts[0].approvedTranscript, "Keep words.")
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

    func testCancellingBulkSharePreparationMakesInFlightMarginEligibleAgain() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appending(path: "bulk-margin-cancel-\(UUID().uuidString).m4a")
        try Data([0x01]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            shareMarginSilenceAnalysisHandler: { _, _ in [] },
            shareMarginAudioCleanupHandler: { _, _, _ in
                try await Task.sleep(for: .seconds(5))
                return 625
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

        model.cancelBulkSharePreparation()

        XCTAssertFalse(model.sharingState.isBulkPreparing)
        XCTAssertEqual(model.sharingState.bulkPreparationCompleted, 0)
        XCTAssertEqual(model.bulkSharePreparationEligibleCount, 1)
        XCTAssertFalse(try XCTUnwrap(model.sharingState.drafts.first).currentEditState.automaticCleanupEnabled)
        XCTAssertNil(model.sharingState.drafts.first?.cleanup)
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

    func testPrioritizePinsOnlySelectedJobAndLeavesFutureImportsOrderedByRecency() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "queue-priority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let old = AudioPreparationJob(id: "old", itemId: "old", manifestId: "old", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 1), maximumChunkCount: 2)
        let selected = AudioPreparationJob(id: "selected", itemId: "selected", manifestId: "selected", policy: .demandWindow, requestedAt: Date(timeIntervalSince1970: 0), maximumChunkCount: 2)
        try store.saveAudioPreparationJob(old)
        try store.saveAudioPreparationJob(selected)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.prioritizeAudioPreparationJob(id: selected.id)
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

    func testPreparedSupertonicOverviewNeverReplacesCanonicalItemTextOrOffsets() throws {
        let itemText = "First source sentence. Second source sentence."
        let overview = "Overview. A brief listening map.\n\n"
        let prefixLength = overview.count
        let combined = overview + itemText
        let media = ItemMedia(
            sourceType: .generatedTTSPrerendered,
            url: "file:///tmp/overview-source.caf",
            durationMs: 3_000,
            nativeMediaId: "file:///tmp/overview-source.caf"
        )
        let prepared = PreparedTextAudio(
            normalizedText: combined,
            media: media,
            timeline: TranscriptTimeline(
                segments: [
                    MediaTimelineSegment(
                        id: "overview",
                        startMs: 0,
                        endMs: 1_000,
                        startChar: 0,
                        endChar: prefixLength,
                        text: overview
                    ),
                    MediaTimelineSegment(
                        id: "source-1",
                        startMs: 1_000,
                        endMs: 2_000,
                        startChar: prefixLength,
                        endChar: prefixLength + 22,
                        text: "First source sentence."
                    ),
                    MediaTimelineSegment(
                        id: "source-2",
                        startMs: 2_000,
                        endMs: 3_000,
                        startChar: prefixLength + 23,
                        endChar: combined.count,
                        text: "Second source sentence."
                    )
                ],
                chapters: [
                    MediaTimelineChapter(id: "overview-chapter", title: "Overview", startMs: 0, transcriptSegmentId: "overview"),
                    MediaTimelineChapter(id: "source-chapter", title: "First source sentence", startMs: 1_000, transcriptSegmentId: "source-1")
                ],
                durationMs: 3_000
            )
        )

        let canonical = try XCTUnwrap(Gate1AppModel.canonicalSupertonicPreparedAudio(
            prepared,
            itemText: itemText
        ))

        XCTAssertEqual(canonical.normalizedText, itemText)
        XCTAssertEqual(canonical.media, media)
        XCTAssertEqual(canonical.timeline.segments[0].startChar, 0)
        XCTAssertEqual(canonical.timeline.segments[0].endChar, 0)
        XCTAssertEqual(canonical.timeline.segments[1].startChar, 0)
        XCTAssertEqual(canonical.timeline.segments[1].endChar, 22)
        XCTAssertEqual(canonical.timeline.segments.last?.endChar, itemText.count)
        XCTAssertEqual(canonical.timeline.chapters.map(\.id), ["source-chapter"])
    }

    func testConfiguredProviderKeyIgnoresWhitespaceOnlyValues() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.providerAPIKey = "   \n"
        XCTAssertFalse(model.hasConfiguredProviderAPIKey)

        model.providerAPIKey = "configured-key"
        XCTAssertTrue(model.hasConfiguredProviderAPIKey)
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
        XCTAssertEqual(model.selectedItem.chapters.count, 5)
    }

    func testGuidedOnboardingAdvancesOnlyFromCompletedProductActions() throws {
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

        model.screen = .settings
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
        try await waitFor("capture cooldown") { !model.isMarginCaptureCoolingDown }
        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.snapshot.isRecording)
        model.dispatchGate2CompactCommand(.cancelInterjection)
    }

    func testFinishAndCancelAreTheOnlyRecordingExits() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            recordingClient: NoopRecordingClient()
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionID = model.snapshot.sessionId
        let targetID = model.snapshot.targetId
        let anchor = model.snapshot.currentPlaybackProgressPercent

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.recordingNavigationIsLocked)
        model.dispatchGate2CompactCommand(.finishInterjection)

        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertNil(model.recordingPresentationContext)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.targetId, targetID)
        XCTAssertEqual(model.snapshot.currentPlaybackProgressPercent, anchor)
        let savedCount = model.selectedItem.interjections.count
        XCTAssertEqual(savedCount, 1)

        model.dispatchGate2CompactCommand(.beginInterjection)
        XCTAssertTrue(model.recordingNavigationIsLocked)
        model.dispatchGate2CompactCommand(.cancelInterjection)

        XCTAssertFalse(model.recordingNavigationIsLocked)
        XCTAssertNil(model.recordingPresentationContext)
        XCTAssertEqual(model.snapshot.sessionId, sessionID)
        XCTAssertEqual(model.snapshot.targetId, targetID)
        XCTAssertEqual(model.snapshot.currentPlaybackProgressPercent, anchor)
        XCTAssertEqual(model.selectedItem.interjections.count, savedCount)
        model.openHome()
        XCTAssertEqual(model.screen, .home)
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
        XCTAssertEqual(model.selectedItem.chapters.map(\.title), ["Source Heading", "First Claim", "Counterpoint", "Conclusion"])
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

    func testTrashUndoPreservesItemSessions() throws {
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
        model.openItem(id: "item-pill")

        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.recentlyDeletedItems.contains(where: { $0.id == "item-pill" }))
        XCTAssertFalse(model.selectedItem.sessions.isEmpty, "Restoring an item should restore its existing sessions")
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

    func testUnfinishedLibraryCompletionUndoPreservesHistoryAndSearch() throws {
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
        XCTAssertFalse(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.undoMarkedCompletion()
        XCTAssertNil(model.completionUndo)
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        XCTAssertEqual(model.selectedItem.sessions, history)
        XCTAssertEqual(model.snapshot, snapshot)
        model.markItemCompleted(id: "item-pill")
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
        XCTAssertTrue(model.libraryIsCaughtUp)
        model.showCompletedLibraryItems()
        XCTAssertFalse(model.libraryIsCaughtUp)
        XCTAssertFalse(model.visibleLibraryItems.isEmpty)
    }

    func testMarkItemCompletedPersistsListeningStateAndStopsOfferingItAsContinueHero() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        let history = model.selectedItem.sessions
        model.markItemCompleted(id: "item-pill")

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
    func testItemMarkedCompleteByHandCanBeMarkedUnfinishedAfterTheUndoBannerIsGone() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        model.startItem(id: "item-pill")
        let history = model.selectedItem.sessions
        model.markItemCompleted(id: "item-pill")
        model.completionUndo = nil
        XCTAssertTrue(try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" }).canMarkUnfinished)

        model.markItemUnfinished(id: "item-pill")

        let row = try XCTUnwrap(model.libraryItems.first { $0.id == "item-pill" })
        XCTAssertFalse(row.isCompleted)
        XCTAssertFalse(row.canMarkUnfinished)
        model.libraryQuery.listeningState = .unfinished
        XCTAssertTrue(model.visibleLibraryItems.contains { $0.id == "item-pill" })
        model.openItem(id: "item-pill")
        XCTAssertEqual(model.selectedItem.sessions, history, "the listening position is unchanged")
    }

    func testUnplayedItemCanBeMarkedCompletedWithoutStartingPlayback() throws {
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
        model.openItem(id: itemID)

        XCTAssertTrue(try XCTUnwrap(model.libraryItems.first { $0.id == itemID }).isCompleted)
        XCTAssertEqual(model.selectedItem.sessions, history)
        XCTAssertFalse(model.snapshot.status.isPlaybackActive)
        let reopened = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        reopened.bootstrapLibraryIfNeeded()
        XCTAssertTrue(try XCTUnwrap(reopened.libraryItems.first { $0.id == itemID }).isCompleted)
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

    func testClearAudioPreparationQueueKeepsLibraryItemsAndRemovesEveryJob() throws {
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
        model.refreshAudioPreparationPresentation()
        let itemCount = model.libraryItems.count
        XCTAssertEqual(model.audioPreparationQueue.count, 200)

        model.clearAudioPreparationQueue()

        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty)
        XCTAssertEqual(model.libraryItems.count, itemCount)
        XCTAssertEqual(Set(defaults.stringArray(forKey: suppressionKey) ?? []), ["item-pill", "item-essay"])
    }

    func testCompletedItemIsLabeledCompleteAndPurgedFromPreparationQueue() throws {
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
        XCTAssertFalse(reloadedModel.audioPreparationQueue.contains(where: { $0.itemId == "item-pill" }))
        XCTAssertFalse(try store.loadAudioPreparationJobs().contains(where: { $0.itemId == "item-pill" }))
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

    func testStoppingTextPlaybackKeepsSessionInProgressAndResumable() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionId = model.snapshot.sessionId

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
        model.dismissFeedback()
        if let saved {
            model.resumeSession(saved)
        }
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNil(model.feedbackEvent)
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

    func testMissingAPIKeySummaryPreflightDoesNotMutateSession() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: true)
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        model.providerAPIKey = ""
        let snapshotBefore = model.snapshot
        let turnsBefore = model.selectedItem.turns

        model.summarize()

        XCTAssertTrue(model.isAISetupNeededPresented)
        XCTAssertEqual(model.snapshot, snapshotBefore)
        XCTAssertEqual(model.selectedItem.turns, turnsBefore)
        XCTAssertEqual(model.diagnostics["summaryPreflight"], "api_key_missing")
    }

    func testReleaseFeatureFlagDisablesRemoteProviderAndProbe() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .unavailable("Unsupported test device"))
        )
        model.providerAPIKey = "configured-but-unused"

        model.probeProvider()

        XCTAssertFalse(model.remoteProviderExperienceEnabled)
        XCTAssertFalse(model.aiSummaryExperienceAvailable)
        XCTAssertEqual(model.providerProbeStatus, "Disabled by release feature flag")
        XCTAssertEqual(model.lastError, "Remote provider access is disabled in this release.")
    }

    func testUnavailableLocalModelDoesNotCreateRemoteSummaryOrDiscussionJobs() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .unavailable("Unsupported test device"))
        )
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.pause()
        let snapshotBefore = model.snapshot
        let turnsBefore = model.selectedItem.turns

        model.summarize()
        model.discuss(followUp: "Send this remotely")

        XCTAssertEqual(model.snapshot, snapshotBefore)
        XCTAssertEqual(model.selectedItem.turns, turnsBefore)
        XCTAssertEqual(model.diagnostics["summaryPreflight"], "local_model_unavailable")
        XCTAssertEqual(model.lastError, "Discuss is disabled in this release. Copy your notes to another chatbot and paste its response back here instead.")
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
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(
                availability: .available,
                summary: "The listener wants to preserve the relationship between structure and recall."
            )
        )
        model.providerAPIKey = ""
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
        XCTAssertEqual(model.providerAPIKey, "")
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
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
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
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
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

        XCTAssertFalse(model.isSummarizingInterjections)
        XCTAssertFalse(model.canSummarizeInterjections)

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)

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
        XCTAssertFalse(model.isSummarizingInterjections)

        model.snapshot.targetType = TargetType.summaryTurnTTS.rawValue
        XCTAssertFalse(model.isSummarizingInterjections)
    }

    func testDefaultReleaseBuildsDeterministicTextMapOnPasteInsteadOfUsingFoundationModel() {
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            featureFlags: SpokenMarginsFeatureFlags(remoteProviderExperienceEnabled: false),
            localFoundationModelClient: WorkflowFoundationModelStub(availability: .available)
        )
        model.resetAndSeed()
        model.importTitle = "Deterministic Map Source"
        model.importText = "# Opening\n\nA first section.\n\n## Next Topic\n\nA second section."
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
        firstModel.startItem(id: "item-pill")
        firstModel.pause()
        let sessionID = try XCTUnwrap(firstModel.snapshot.sessionId)

        let relaunchedModel = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        relaunchedModel.bootstrapLibraryIfNeeded()

        XCTAssertEqual(relaunchedModel.snapshot.sessionId, sessionID)
        XCTAssertEqual(relaunchedModel.snapshot.status, .paused)
        XCTAssertTrue(relaunchedModel.shouldShowMiniPlayer)
        XCTAssertEqual(relaunchedModel.diagnostics["restoredSessionMode"], "paused_without_autoplay")
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
        XCTAssertFalse(model.canPlayLiveSpeechInstead)
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
        XCTAssertFalse(Gate1AppModel.itemIsCompleted([belowCutoff]))
        XCTAssertTrue(Gate1AppModel.itemIsCompleted([atCutoff]))
        XCTAssertTrue(Gate1AppModel.itemIsCompleted([completed]))
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

    func testPreOnePointZeroTTSMigrationDefaultsToJamesAndRetainsAppleFallbackVoice() {
        let defaults = UserDefaults.standard
        let keys = [
            "supertonicTTSMigrationV1",
            "ttsMode",
            "ttsVoiceSelection",
            "speechVoiceIdentifier",
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey
        ]
        let prior = keys.reduce(into: [String: Any]()) { values, key in
            values[key] = defaults.object(forKey: key)
        }
        defer {
            for key in keys {
                if let value = prior[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.removeObject(forKey: "supertonicTTSMigrationV1")
        defaults.removeObject(forKey: "ttsVoiceSelection")
        defaults.set("piper", forKey: "ttsMode")
        defaults.set("com.apple.ttsbundle.Samantha-compact", forKey: "speechVoiceIdentifier")
        SpokenMarginsTerms.recordAcceptance(in: defaults)

        let model = Gate1AppModel(audioPlaybackClient: WorkflowRecordingAudioClient())

        XCTAssertEqual(model.ttsVoiceSelection, .james)
        XCTAssertEqual(model.ttsMode, "supertonic")
        XCTAssertEqual(model.speechVoiceIdentifier, "com.apple.ttsbundle.Samantha-compact")
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
        try await waitFor("PDF import to finish") {
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
        try await waitFor("PDF import to finish") {
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
        try await waitFor("structured PDF import to finish") {
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
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: file) { context in
            context.beginPage()
            ("Collected Stories" as NSString).draw(
                at: CGPoint(x: 40, y: 35),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26)]
            )
            ("Edited by Example Author" as NSString).draw(
                at: CGPoint(x: 40, y: 78),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
            )
            ("Contents" as NSString).draw(
                at: CGPoint(x: 40, y: 110),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)]
            )
            for (index, title) in storyTitles.enumerated() {
                (title as NSString).draw(
                    at: CGPoint(x: 55, y: 145 + CGFloat(index * 23)),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 12)]
                )
            }

            for title in storyTitles {
                context.beginPage()
                (title as NSString).draw(
                    at: CGPoint(x: 40, y: 40),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)]
                )
                ("This is the readable body of \(title), with enough ordinary prose to establish the document body font size." as NSString).draw(
                    at: CGPoint(x: 40, y: 85),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 12)]
                )
            }
        }

        let document = try XCTUnwrap(PDFDocument(url: file))
        let outlineRoot = PDFOutline()
        for (index, title) in storyTitles.enumerated() {
            let page = try XCTUnwrap(document.page(at: index + 1))
            let child = PDFOutline()
            child.label = title
            child.destination = PDFDestination(page: page, at: CGPoint(x: 40, y: 740))
            outlineRoot.insertChild(child, at: outlineRoot.numberOfChildren)
        }
        document.outlineRoot = outlineRoot
        XCTAssertTrue(document.write(to: file))

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

    func testSourceSuggestionEngagementUsesLivePlaybackProgressBeforeLibraryRefresh() {
        var snapshot = SessionSnapshot()
        snapshot.itemId = "active-item"
        snapshot.currentPlaybackProgressPercent = 31

        XCTAssertEqual(
            Gate1AppModel.sourceSuggestionEngagementProgress(
                itemId: "active-item",
                persistedProgress: 4,
                snapshot: snapshot
            ),
            31
        )
        XCTAssertEqual(
            Gate1AppModel.sourceSuggestionEngagementProgress(
                itemId: "different-item",
                persistedProgress: 18,
                snapshot: snapshot
            ),
            18
        )
    }

    func testQuickFolderScanOffersOnlyImportableTextAndPDFFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spoken-margins-quick-add-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["Notes.md", "Draft.markdown", "Excerpt.txt", "Paper.pdf", "Cover.jpg"] {
            try "content".write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }

        let scan = Gate1AppModel.scanQuickAccessFolder(directory)

        XCTAssertNil(scan.errorDescription)
        XCTAssertEqual(Set(scan.files.map(\.relativePath)), ["Notes.md", "Draft.markdown", "Excerpt.txt", "Paper.pdf"])
    }

    func testQuickAddFeedCombinesFolderFilesAndFollowedEntriesByRecency() {
        let olderFile = QuickAccessFile(
            id: "older.md",
            name: "Older",
            relativePath: "older.md",
            modifiedAt: Date(timeIntervalSince1970: 100),
            modifiedAtDescription: "2h ago"
        )
        let newerEntry = FeedEntry(
            id: "episode",
            subscriptionId: "show",
            canonicalURL: "https://example.com/episode",
            title: "New Episode",
            publishedAt: Date(timeIntervalSince1970: 200)
        )

        let candidates = Gate1AppModel.quickAddCandidates(
            folderFiles: [olderFile],
            followedEntries: [newerEntry]
        )

        XCTAssertEqual(candidates.map(\.id), ["followed-source:episode", "local-file:older.md"])
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

private actor BulkSharePreparationProbe {
    private var activeRenders = 0
    private var maximumConcurrentRenders = 0
    private var renderCount = 0

    func render(
        sourceURL: URL,
        destinationURL: URL,
        decisions: [InterjectionCleanupDecision]
    ) async throws -> Int {
        _ = sourceURL
        _ = destinationURL
        XCTAssertFalse(decisions.isEmpty)
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
