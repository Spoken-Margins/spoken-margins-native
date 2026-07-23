import XCTest
import SessionKit
@testable import SpokenMarginsApp
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SourceLinkImportTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSourceLinkURLParsesHandoff() throws {
        let handoff = SourceLinkHandoff(
            id: "source-link-url-test",
            inputURL: "https://feeds.example.com/show.xml",
            sourceSurface: "paste",
            startSession: false
        )

        let parsed = try XCTUnwrap(SourceLinkHandoffURL.handoff(from: SourceLinkHandoffURL.url(for: handoff)))

        XCTAssertEqual(parsed.inputURL, "https://feeds.example.com/show.xml")
        XCTAssertEqual(parsed.sourceSurface, "paste")
        XCTAssertEqual(parsed.startSession, false)
    }

    func testSourceLinkPayloadStoreRoundTripsAndDeletes() throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "payload-source-link",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "share_sheet",
            startSession: true
        )

        try store.save(handoff)
        XCTAssertEqual(try store.handoff(payloadID: handoff.id), handoff)
        try store.deletePayload(payloadID: handoff.id)

        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(handoff.id))
        }
    }

    func testSourceLinkPayloadStoreQuarantinesAndRetriesFailure() throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "payload-source-link-failed",
            inputURL: "https://example.com/unresolved",
            sourceSurface: "share_sheet",
            startSession: false
        )
        try store.save(handoff)

        try store.quarantine(payloadID: handoff.id, reason: "No playable audio")

        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id))
        let failed = try XCTUnwrap(store.failedHandoffs().first)
        XCTAssertEqual(failed.handoff, handoff)
        XCTAssertEqual(failed.reason, "No playable audio")

        try store.retryFailed(payloadID: handoff.id)

        XCTAssertEqual(try store.handoff(payloadID: handoff.id), handoff)
        XCTAssertTrue(try store.failedHandoffs().isEmpty)
    }

    func testIncomingSourceLinkURLImportsAndStartsPlayableItem() {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Episode Audio",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()

        model.handleIncomingURL(SourceLinkHandoffURL.url(for: SourceLinkHandoff(
            id: "source-link-direct",
            inputURL: "https://example.com/episode",
            sourceSurface: "url",
            startSession: true
        )))

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(model.snapshot.targetId, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(model.selectedItem.externalReference, "https://example.com/episode")
        XCTAssertEqual(model.libraryItems.first(where: { $0.id == model.snapshot.itemId })?.status, "Audio ready")
        XCTAssertEqual(model.diagnostics["lastSourceLinkStatus"], LinkResolutionStatus.playable.rawValue)

        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.seekToMediaTime) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.setPlaybackRate) == true)
        model.dispatchGate2CompactCommand(.seekToMediaTime, mediaTimeMs: 120_000, origin: "now_playing")
        model.dispatchGate2CompactCommand(.setPlaybackRate, playbackRate: 1.5, origin: "now_playing")

        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 120_000)
        XCTAssertEqual(model.snapshot.playbackRate, 1.5)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], CompactControlCommand.setPlaybackRate.rawValue)
        XCTAssertEqual(model.diagnostics["gate2LastResult"], "delegated")
        XCTAssertNil(model.lastError)
    }

    func testNativeAudioInterjectionRequestsFullShoulderContext() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Windowed Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/windowed.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let transcriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "window-early", startMs: 33_000, endMs: 62_000, text: "Earlier context."),
                MediaTimelineSegment(id: "window-before", startMs: 63_000, endMs: 122_000, text: "Minute before."),
                MediaTimelineSegment(id: "window-current", startMs: 122_000, endMs: 124_000, text: "Interjection context."),
                MediaTimelineSegment(id: "window-after", startMs: 124_000, endMs: 183_000, text: "Minute after."),
                MediaTimelineSegment(id: "window-late", startMs: 184_000, endMs: 243_000, text: "Later context.")
            ],
            chapters: [],
            durationMs: 300_000
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: transcriber,
            interjectionTranscriptionHandler: { _ in "Recorded note." }
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        let request = await transcriber.waitForWindowRequest()
        try await waitFor("source window context to attach") {
            model.diagnostics["sourceWindowTranscription:ij-001"] == "complete:speech_window"
        }

        XCTAssertEqual(request.anchorMediaTimeMs, 123_000)
        XCTAssertEqual(request.windowBeforeMs, 90_000)
        XCTAssertEqual(request.windowAfterMs, 120_000)
        XCTAssertEqual(request.durationMs, 300_000)
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorBefore, "Earlier context. Minute before. Interjection context.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchor.anchorAfter, "Minute after. Later context.")
        XCTAssertEqual(model.selectedItem.interjections.first?.anchorContextStatus, .ready)
        XCTAssertEqual(model.diagnostics["sourceWindowContextProvenance:ij-001"], "bounded_remote_window")
    }

    func testInterjectionTranscriptionFinishesBeforeSourceWindowTranscriptionStarts() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Serialized Transcription Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/serialized.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let sourceTranscriber = RecordingSourceWindowTranscriptionClient(timeline: TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "context", startMs: 120_000, endMs: 125_000, text: "Source context.")],
            chapters: [],
            durationMs: 300_000
        ))
        let interjectionTranscriber = ControlledInterjectionTranscriber()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: sourceTranscriber,
            interjectionTranscriptionHandler: { audioPath in
                try await interjectionTranscriber.transcribe(audioPath: audioPath)
            }
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        await interjectionTranscriber.waitForRequest()

        let sourceRequestsBeforeNoteFinished = await sourceTranscriber.windowRequestCount()
        XCTAssertEqual(sourceRequestsBeforeNoteFinished, 0)

        await interjectionTranscriber.complete(with: "My recorded note.")
        _ = await sourceTranscriber.waitForWindowRequest()
        try await waitFor("both transcription stages to finish") {
            model.diagnostics["sourceWindowTranscription:ij-001"] == "complete:speech_window"
        }

        XCTAssertEqual(model.diagnostics["interjectionTranscription:ij-001"], "complete")
        XCTAssertEqual(
            model.diagnostics["interjectionAnchorAtCapture:ij-001"],
            "type=media;media_time=present;segment=missing;before=missing;after=missing;context=pending"
        )
        XCTAssertEqual(model.selectedItem.interjections.first?.transcript, "My recorded note.")
    }

    func testSavedInterjectionAudioCanReplaceATruncatedTranscript() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Recoverable Interjection",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/recoverable.mp3",
                confidence: 1
            )
        ))
        let transcriber = SequencedInterjectionTranscriber(transcripts: [
            "Only the ending survived.",
            "The complete saved interjection is restored from its original audio."
        ])
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: WindowContextAudioClient(),
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient(),
            interjectionTranscriptionHandler: { audioPath in
                try await transcriber.transcribe(audioPath: audioPath)
            }
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))

        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("initial transcript") {
            model.selectedItem.interjections.first?.transcript == "Only the ending survived."
        }
        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)

        model.retryInterjectionTranscription(interjection)
        try await waitFor("replacement transcript") {
            model.selectedItem.interjections.first?.transcript == "The complete saved interjection is restored from its original audio."
        }

        XCTAssertFalse(model.retryingInterjectionTranscriptionIds.contains(interjection.id))
        XCTAssertEqual(model.diagnostics["interjectionTranscription:\(interjection.id)"], "complete")

        let recovered = try XCTUnwrap(model.selectedItem.interjections.first)
        model.retryInterjectionTranscription(recovered)
        try await waitFor("failed retry evidence") {
            model.diagnostics["interjectionTranscription:\(interjection.id)"]?.hasPrefix("retry_failed:") == true
        }

        XCTAssertEqual(model.selectedItem.interjections.first?.transcript, "The complete saved interjection is restored from its original audio.")
        XCTAssertEqual(model.selectedItem.interjections.first?.displayText, "The complete saved interjection is restored from its original audio.")
        XCTAssertFalse(model.retryingInterjectionTranscriptionIds.contains(interjection.id))
    }

    func testUnavailablePodcastContextKeepsTimestampAndPersistedRetryState() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Offline Context Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/offline-context.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            recordingClient: NoopRecordingClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient(),
            interjectionTranscriptionHandler: { _ in "Recorded note." }
        )
        model.resetAndSeed()

        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        audio.currentMediaTimeValue = 123_000
        model.dispatchGate2CompactCommand(.beginInterjection)
        model.dispatchGate2CompactCommand(.finishInterjection)
        try await waitFor("source window failure to persist") {
            model.selectedItem.interjections.first?.anchorContextStatus == .unavailable
        }

        let interjection = try XCTUnwrap(model.selectedItem.interjections.first)
        XCTAssertEqual(interjection.anchor.mediaTimeMs, 123_000)
        XCTAssertEqual(interjection.anchorContextStatus, .unavailable)
        XCTAssertEqual(interjection.anchor.anchorBefore, "")
        XCTAssertEqual(interjection.anchor.anchorAfter, "")
    }

    func testConfiguredNativeAudioSkipIntervalsAreAppliedAndPersisted() {
        defer {
            UserDefaults.standard.removeObject(forKey: "mediaSkipBackSeconds")
            UserDefaults.standard.removeObject(forKey: "mediaSkipForwardSeconds")
        }
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/episode", provider: "direct_audio", role: "audio_file"),
                title: "Configurable Skip Episode",
                durationMs: 300_000,
                audioURL: "https://cdn.example.com/configurable-skip.mp3",
                confidence: 1
            )
        ))
        let audio = WindowContextAudioClient()
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: audio,
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        XCTAssertTrue(model.importSourceLink(urlString: "https://example.com/episode", sourceSurface: "paste"))
        model.mediaSkipBackSeconds = 30
        model.mediaSkipForwardSeconds = 45
        model.mediaSkipSettingsChanged()

        audio.currentMediaTimeValue = 60_000
        model.skipForwardMedia()
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 105_000)
        audio.currentMediaTimeValue = 105_000
        model.skipBackMedia()
        XCTAssertEqual(model.snapshot.currentMediaTimeMs, 75_000)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "mediaSkipBackSeconds"), 30)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "mediaSkipForwardSeconds"), 45)
    }

    func testStoredTranscriptWindowUsesFullShoulderAndAllowsTimestampGaps() throws {
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "early", startMs: 35_000, endMs: 55_000, text: "Earlier context."),
                MediaTimelineSegment(id: "before", startMs: 70_000, endMs: 120_000, text: "Before."),
                MediaTimelineSegment(id: "after", startMs: 125_000, endMs: 175_000, text: "After."),
                MediaTimelineSegment(id: "late", startMs: 200_000, endMs: 240_000, text: "Later context."),
                MediaTimelineSegment(id: "far", startMs: 500_000, endMs: 550_000, text: "Far away.")
            ],
            chapters: [],
            durationMs: 600_000
        )

        let window = try XCTUnwrap(Gate1AppModel.sourceContextWindow(from: timeline, anchorMediaTimeMs: 123_000))

        XCTAssertEqual(
            window.segments.map(\.id),
            ["early", "before", "after", "late"],
            "The stored transcript should preserve the full 90-second/120-second shoulder despite normal word-timestamp gaps"
        )
        XCTAssertNil(Gate1AppModel.sourceContextWindow(from: timeline, anchorMediaTimeMs: 350_000))
    }

    func testClipboardButtonExtractsSourceLinkURL() throws {
        #if canImport(UIKit)
        UIPasteboard.general.string = "Listen here: https://podcasts.apple.com/us/podcast/show/id123456?i=999"
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())

        model.pasteSourceLinkFromClipboard()

        XCTAssertEqual(model.sourceLinkURL, "https://podcasts.apple.com/us/podcast/show/id123456?i=999")
        XCTAssertEqual(model.statusMessage, "Pasted link from Clipboard.")
        #else
        throw XCTSkip("Clipboard is only available with UIKit")
        #endif
    }

    func testTextClipboardButtonFillsManualImportField() throws {
        #if canImport(UIKit)
        UIPasteboard.general.string = "A fresh passage to import."
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())

        model.pasteImportTextFromClipboard()

        XCTAssertEqual(model.importText, "A fresh passage to import.")
        XCTAssertEqual(model.statusMessage, "Pasted text from Clipboard.")
        #else
        throw XCTSkip("Clipboard is only available with UIKit")
        #endif
    }

    func testAsyncSourceLinkFormClearsLinkAfterSuccessfulProcessing() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "audio_file"),
                title: "Form Episode",
                audioURL: "https://cdn.example.com/form-episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        model.sourceLinkURL = "https://example.com/form-episode"

        model.beginSourceLinkImportFromForm()
        try await waitFor("source link field to clear") {
            model.sourceLinkURL.isEmpty
        }

        XCTAssertEqual(model.selectedItem.title, "Form Episode")
    }

    func testSourceLinkFormRejectsMalformedURLWithoutClearingAndDeduplicatesActiveResolution() async throws {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://example.com/form-episode", provider: "direct_audio", role: "audio_file"),
                title: "Form Episode",
                audioURL: "https://cdn.example.com/form-episode.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: ThrowingSourceTranscriptionClient()
        )
        model.resetAndSeed()
        model.sourceLinkURL = "not a URL"

        XCTAssertFalse(model.beginSourceLinkImportFromForm())
        XCTAssertEqual(model.sourceLinkURL, "not a URL")
        XCTAssertEqual(model.sourceLinkImportState, "failure")

        model.sourceLinkURL = "https://example.com/form-episode"
        XCTAssertTrue(model.beginSourceLinkImportFromForm())
        XCTAssertFalse(model.beginSourceLinkImportFromForm())
        try await waitFor("source resolution to finish") { model.sourceLinkImportState == "success" }
        XCTAssertEqual(model.selectedItem.title, "Form Episode")
    }

    func testIncomingPayloadIsQuarantinedAfterUnsupportedImport() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "source-link-unsupported",
            inputURL: "https://open.spotify.com/episode/abc123",
            sourceSurface: "share_sheet",
            startSession: true
        )
        try store.save(handoff)
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .unsupported,
            originalLink: SourceLink(url: handoff.inputURL, provider: "spotify", role: "discovery"),
            selectedCandidate: nil,
            failureReason: "spotify_audio_requires_provider_playback"
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        model.handleIncomingURL(SourceLinkHandoffURL.url(forPayloadID: handoff.id))
        try await waitFor("unsupported share quarantine") {
            (try? store.failedHandoffs().count) == 1
        }

        XCTAssertEqual(model.diagnostics["lastSourceLinkPayloadCleanup"], "queued:\(handoff.id)")
        XCTAssertTrue(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"]?.hasPrefix("quarantined:") == true)
        XCTAssertEqual(model.diagnostics["lastSourceLinkFailureCategory"], "spotify_audio_requires_provider_playback")
        XCTAssertNil(model.lastError)
        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id))
        let failed = try XCTUnwrap(store.failedHandoffs().first)
        XCTAssertEqual(failed.handoff, handoff)
        XCTAssertTrue(
            failed.reason.contains("could not find a public audio file"),
            "Unexpected quarantine reason: \(failed.reason)"
        )
        XCTAssertFalse(failed.reason.contains("open.spotify.com"))
        XCTAssertEqual(model.importInbox.first?.payloadID, handoff.id)
    }

    func testForegroundActivationImportsSavedShareWithoutReplacingPlayback() async throws {
        let store = makePayloadStore()
        let sharedHandoff = SourceLinkHandoff(
            id: "source-link-shared",
            inputURL: "https://example.com/shared-episode",
            sourceSurface: "share_sheet",
            startSession: false
        )
        try store.save(sharedHandoff)
        let resolver = CountingAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: sharedHandoff.inputURL, provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: sharedHandoff.inputURL, provider: "direct_audio", role: "audio_file"),
                title: "Shared Episode",
                audioURL: "https://cdn.example.com/shared.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()
        let activeItemID = try XCTUnwrap(model.libraryItems.first?.id)
        model.startItem(id: activeItemID)
        let snapshotBeforeImport = model.snapshot

        model.handleAppBecameActive()
        try await waitFor("shared episode import") {
            model.libraryItems.contains { $0.title == "Shared Episode" }
        }

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.sessionId, snapshotBeforeImport.sessionId)
        XCTAssertEqual(model.snapshot.itemId, snapshotBeforeImport.itemId)
        XCTAssertEqual(model.snapshot.targetId, snapshotBeforeImport.targetId)
        XCTAssertEqual(model.snapshot.status, snapshotBeforeImport.status)
        XCTAssertEqual(model.snapshot.phase, snapshotBeforeImport.phase)
        XCTAssertEqual(model.snapshot.currentTextStart, snapshotBeforeImport.currentTextStart)
        XCTAssertNotEqual(model.selectedItem.title, "Shared Episode")
        XCTAssertTrue(model.libraryItems.contains { $0.title == "Shared Episode" })
        XCTAssertEqual(resolver.resolveCount, 1)
        XCTAssertThrowsError(try store.handoff(payloadID: sharedHandoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(sharedHandoff.id))
        }
    }

    func testPendingSourceLinkHandoffImportsAndDeletesOnSuccess() async throws {
        let store = makePayloadStore()
        let handoff = SourceLinkHandoff(
            id: "source-link-pending",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            startSession: true
        )
        try store.save(handoff)
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: handoff.inputURL, provider: "direct_audio", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: handoff.inputURL, provider: "direct_audio", role: "audio_file"),
                title: "Pending Episode",
                audioURL: "https://cdn.example.com/pending.mp3",
                confidence: 1
            )
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            sourceLinkHandoffStore: store,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        model.importPendingSourceLinkHandoffs()
        try await waitFor("pending episode import") {
            model.libraryItems.contains { $0.title == "Pending Episode" }
        }

        XCTAssertEqual(model.screen, .home)
        XCTAssertNotEqual(model.selectedItem.title, "Pending Episode")
        XCTAssertEqual(model.diagnostics["pendingSourceLinkPayload:\(handoff.id)"], "imported")
        XCTAssertThrowsError(try store.handoff(payloadID: handoff.id)) { error in
            XCTAssertEqual(error as? SourceLinkHandoffStoreError, .missingPayload(handoff.id))
        }
    }

    func testAppleProviderDoesNotUseSpotifyExclusiveFailureCopy() {
        let resolver = StaticAppLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .needsReview,
            originalLink: SourceLink(url: "https://podcasts.apple.com/us/podcast/show/id123456?i=999", provider: "apple_podcasts", role: "discovery"),
            selectedCandidate: nil,
            failureReason: "spotify_audio_requires_provider_playback"
        ))
        let model = Gate1AppModel(
            sourceLinkResolver: resolver,
            audioPlaybackClient: NoopAudioPlaybackClient()
        )
        model.resetAndSeed()

        model.importSourceLink(
            urlString: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste"
        )

        XCTAssertEqual(model.diagnostics["lastSourceLinkProvider"], "apple_podcasts")
        XCTAssertEqual(
            model.lastError,
            "This provider did not expose a public audio file that Spoken Margins can play yet."
        )
    }

    func testPublicResolverAcceptsDirectAudioURL() throws {
        let request = LinkResolutionRequest(
            id: "request-direct",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data() }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, request.inputURL)
        XCTAssertEqual(result.originalLink.provider, "direct_audio")
    }

    func testPublicResolverRejectsInsecureHTTPBeforeFetching() throws {
        let request = LinkResolutionRequest(
            id: "request-http",
            inputURL: "http://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in throw URLError(.badURL) }).resolve(request)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.failureReason, "invalid_url")
    }

    func testPublicResolverAsyncAcceptsDirectAudioURL() async throws {
        let request = LinkResolutionRequest(
            id: "request-direct-async",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try await PublicPodcastLinkResolver().resolveAsync(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, request.inputURL)
        XCTAssertEqual(result.originalLink.provider, "direct_audio")
    }

    func testPublicResolverExtractsRSSAudioEnclosure() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Example Show</title>
            <item>
              <title>Episode One</title>
              <guid>episode-one</guid>
              <pubDate>Fri, 19 Jun 2026 12:00:00 GMT</pubDate>
              <itunes:duration>00:30:00</itunes:duration>
              <enclosure url="https://cdn.example.com/episode-one.mp3" type="audio/mpeg" length="1" />
              <podcast:transcript url="https://cdn.example.com/episode-one.vtt" type="text/vtt" language="en" rel="captions" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-rss",
            inputURL: "https://feeds.example.com/show.xml",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(feed.utf8) }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Episode One")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Example Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/episode-one.mp3")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 1_800_000)
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks, [
            SourceTranscriptLink(
                url: "https://cdn.example.com/episode-one.vtt",
                type: "text/vtt",
                language: "en",
                rel: "captions"
            )
        ])
    }

    func testPublicResolverUsesAppleLookupAudioURL() throws {
        let lookup = """
        {
          "resultCount": 3,
          "results": [
            {
              "wrapperType": "track",
              "kind": "podcast",
              "trackId": 123456,
              "collectionName": "Apple Show",
              "feedUrl": "https://feeds.example.com/apple-show.xml"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackId": 111,
              "trackName": "Different Episode",
              "episodeUrl": "https://cdn.example.com/wrong-episode.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackId": 999,
              "trackName": "Apple Episode",
              "collectionName": "Apple Show",
              "episodeUrl": "https://cdn.example.com/apple-episode.mp3"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            XCTAssertTrue(url.absoluteString.contains("itunes.apple.com/lookup"))
            XCTAssertTrue(url.absoluteString.contains("id=123456"))
            XCTAssertTrue(url.absoluteString.contains("entity=podcastEpisode"))
            XCTAssertTrue(url.absoluteString.contains("limit=200"))
            return Data(lookup.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/apple-episode.mp3")
    }

    func testPublicResolverAcceptsAppleLookupExtensionlessAudioURL() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "trackId": 999,
            "trackName": "Apple Episode",
            "collectionName": "Apple Show",
            "episodeUrl": "https://traffic.example.net/APPLEEPISODE123"
          }]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple-extensionless",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(lookup.utf8) }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://traffic.example.net/APPLEEPISODE123")
    }

    func testPublicResolverFallsBackToApplePageStreamWhenLookupIsEmpty() throws {
        let html = #"""
        <html>
          <head><title>Apple Page Episode - Apple Podcasts</title></head>
          <body>
            <script>
              {"title":"Apple Page Episode","collectionName":"Apple Page Show","streamUrl":"https:\/\/traffic.example.net\/page-episode.mp3","duration":1971}
            </script>
          </body>
        </html>
        """#
        let request = LinkResolutionRequest(
            id: "request-apple-page",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.absoluteString.contains("itunes.apple.com/lookup") {
                return Data(#"{"resultCount":0,"results":[]}"#.utf8)
            }
            XCTAssertTrue(url.absoluteString.contains("podcasts.apple.com"))
            return Data(html.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Page Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Page Show")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 1_971_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://traffic.example.net/page-episode.mp3")
    }

    func testPublicResolverFallsBackToFeedWhenEpisodeIsOutsideAppleLookupWindow() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/wrong-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Requested Old Episode</title>
              <enclosure url="https://cdn.example.com/requested-old-episode.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-apple-feed-fallback",
            inputURL: "https://podcasts.apple.com/us/podcast/requested-old-episode/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "itunes.apple.com" {
                return Data(lookup.utf8)
            }
            XCTAssertEqual(url.absoluteString, "https://feeds.example.com/apple-show.xml")
            return Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Requested Old Episode")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/requested-old-episode.mp3")
    }

    func testAppleFeedFallbackNeverSelectsADifferentEpisode() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Newest Episode</title>
              <enclosure url="https://cdn.example.com/newest-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/another-episode.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-apple-no-wrong-fallback",
            inputURL: "https://podcasts.apple.com/us/podcast/requested-missing-episode/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            url.host == "itunes.apple.com" ? Data(lookup.utf8) : Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.failureReason, "rss_episode_ambiguous")
    }

    func testPublicResolverExplainsWhenSpotifyEpisodeHasNoAppleMatch() throws {
        let oEmbed = #"{"title":"Spotify Episode"}"#
        let request = LinkResolutionRequest(
            id: "request-spotify",
            inputURL: "https://open.spotify.com/episode/abc123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                return Data(oEmbed.utf8)
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            return Data(#"{"resultCount":0,"results":[]}"#.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.candidates.first?.title, "Spotify Episode")
        XCTAssertEqual(result.failureReason, "spotify_episode_not_found_on_apple")
    }

    func testPublicResolverRequiresASpecificSpotifyEpisodeLink() throws {
        let request = LinkResolutionRequest(
            id: "request-spotify-show",
            inputURL: "https://open.spotify.com/show/show123",
            sourceSurface: "share_extension",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in
            XCTFail("A Spotify show link should be rejected before network resolution")
            return Data()
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.originalLink.provider, "spotify")
        XCTAssertEqual(result.failureReason, "spotify_specific_episode_required")
    }

    func testPublicResolverNormalizesSpotifyEpisodeToExactAppleMatch() throws {
        let oEmbed = #"{"title":"The Shared Episode!"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "A Different Episode",
              "collectionName": "Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "The Shared Episode",
              "collectionName": "Shared Show",
              "trackViewUrl": "https://podcasts.apple.com/us/podcast/shared-show/id123?i=456",
              "episodeUrl": "https://cdn.example.com/shared.mp3",
              "trackTimeMillis": 123000,
              "releaseDate": "2026-07-01T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-apple-match",
            inputURL: "https://open.spotify.com/episode/shared123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                XCTAssertEqual(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                    request.inputURL
                )
                return Data(oEmbed.utf8)
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "entity" })?.value, "podcastEpisode")
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "spotify")
        XCTAssertEqual(result.selectedCandidate?.sourceLink.provider, "apple_podcasts")
        XCTAssertEqual(result.selectedCandidate?.title, "The Shared Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Shared Show")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 123_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/shared.mp3")
    }

    func testPublicResolverDoesNotGuessBetweenAmbiguousSpotifyAppleMatches() throws {
        let oEmbed = #"{"title":"Trailer"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "trackName": "Trailer",
              "collectionName": "Show One",
              "episodeUrl": "https://cdn.example.com/show-one.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "trackName": "Trailer",
              "collectionName": "Show Two",
              "episodeUrl": "https://cdn.example.com/show-two.mp3"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-ambiguous",
            inputURL: "https://open.spotify.com/episode/trailer123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            url.path == "/oembed" ? Data(oEmbed.utf8) : Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.failureReason, "spotify_episode_match_ambiguous")
    }

    private func makePayloadStore() -> SourceLinkHandoffStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-source-link-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return SourceLinkHandoffStore(baseDirectory: directory)
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
}

private struct StaticAppLinkResolver: LinkResolutionClient {
    var result: LinkResolutionResult

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(url: request.inputURL, provider: result.originalLink.provider, title: result.originalLink.title, role: result.originalLink.role),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private final class CountingAppLinkResolver: LinkResolutionClient {
    var result: LinkResolutionResult
    private(set) var resolveCount = 0

    init(result: LinkResolutionResult) {
        self.result = result
    }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        resolveCount += 1
        return LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(url: request.inputURL, provider: result.originalLink.provider, title: result.originalLink.title, role: result.originalLink.role),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private struct ThrowingSourceTranscriptionClient: SourceTranscriptionClient {
    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_test")
    }
}

private final class WindowContextAudioClient: AudioPlaybackClient {
    var currentMediaTimeValue: Int?
    private var activeTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        activeTargetId = targetId
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        currentMediaTimeValue = mediaTimeMs
    }

    func pause() throws {}

    func currentPlaybackPosition() -> PlaybackPosition? {
        guard let currentMediaTimeValue else { return nil }
        return PlaybackPosition(
            targetType: .transcriptBackedMedia,
            targetId: activeTargetId,
            mediaTimeMs: currentMediaTimeValue,
            durationMs: 300_000,
            playbackRate: 1,
            anchorConfidence: .mediaTime
        )
    }
}

private actor RecordingSourceWindowTranscriptionClient: SourceTranscriptionClient {
    struct WindowRequest: Sendable {
        var anchorMediaTimeMs: Int
        var durationMs: Int?
        var windowBeforeMs: Int
        var windowAfterMs: Int
    }

    private let timeline: TranscriptTimeline
    private var windowRequest: WindowRequest?
    private var continuations: [CheckedContinuation<WindowRequest, Never>] = []

    init(timeline: TranscriptTimeline) {
        self.timeline = timeline
    }

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_transcription_disabled_for_test")
    }

    func transcribeSourceAudioWindow(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) async throws -> TranscriptTimeline {
        let request = WindowRequest(
            anchorMediaTimeMs: anchorMediaTimeMs,
            durationMs: durationMs,
            windowBeforeMs: windowBeforeMs,
            windowAfterMs: windowAfterMs
        )
        windowRequest = request
        for continuation in continuations {
            continuation.resume(returning: request)
        }
        continuations.removeAll()
        return timeline
    }

    func waitForWindowRequest() async -> WindowRequest {
        if let windowRequest {
            return windowRequest
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func windowRequestCount() -> Int {
        windowRequest == nil ? 0 : 1
    }
}

private actor ControlledInterjectionTranscriber {
    private var requested = false
    private var requestContinuations: [CheckedContinuation<Void, Never>] = []
    private var transcriptContinuation: CheckedContinuation<String, Error>?

    func transcribe(audioPath: String) async throws -> String {
        requested = true
        for continuation in requestContinuations {
            continuation.resume()
        }
        requestContinuations.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            transcriptContinuation = continuation
        }
    }

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    func complete(with transcript: String) {
        transcriptContinuation?.resume(returning: transcript)
        transcriptContinuation = nil
    }
}

private actor SequencedInterjectionTranscriber {
    private var transcripts: [String]

    init(transcripts: [String]) {
        self.transcripts = transcripts
    }

    func transcribe(audioPath: String) throws -> String {
        guard !transcripts.isEmpty else {
            throw SessionKitError.persistenceFailed("no_scripted_transcript")
        }
        return transcripts.removeFirst()
    }
}
