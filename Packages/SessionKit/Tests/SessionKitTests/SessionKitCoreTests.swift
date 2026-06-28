import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class SessionKitCoreTests: XCTestCase {
    func testSpeechNormalizationPreservesSource() {
        let source = "A [reference](https://example.com/x) and https://example.org/raw plus example.net/path."
        let spoken = SpeechTextNormalizer.normalize(source)
        XCTAssertEqual(spoken, "A reference and plus.")
        XCTAssertTrue(source.contains("https://example.com/x"))
    }

    func testObsidianWebClipperImportCleansTranscriptTimestampsAndMetadata() throws {
        let markdown = """
        ---
        title: "Sarah Paine - Why Putin and Xi can't escape geography"
        source: "https://www.youtube.com/watch?v=OS1NZLgKM2c&list=TLPQMTAwNjIwMjZENlo5qll1wg&index=11"
        tags:
          - "clippings"
        ---
        ![](https://www.youtube.com/watch?v=OS1NZLgKM2c)

        𝐓𝐈𝐌𝐄𝐒𝐓𝐀𝐌𝐏𝐒
        00:00:00 - Setting the stage
        00:12:10 - The continental powers

        ## Transcript

        ### Setting the stage

        **0:00** · Good evening. It's such a pleasure to be with you.
        **0:29** · Geopolitics is the influence of geography on politics.
        """

        let parsed = try ObsidianMarkdownParser.parse(fileName: "Sarah Paine.md", contents: markdown)

        XCTAssertEqual(parsed.title, "Sarah Paine - Why Putin and Xi can't escape geography")
        XCTAssertEqual(parsed.source, "https://www.youtube.com/watch?v=OS1NZLgKM2c&list=TLPQMTAwNjIwMjZENlo5qll1wg&index=11")
        XCTAssertFalse(parsed.text.contains("Timestamps"))
        XCTAssertFalse(parsed.text.contains("00:00:00"))
        XCTAssertFalse(parsed.text.contains("0:29"))
        XCTAssertFalse(parsed.text.contains("youtube.com"))
        XCTAssertTrue(parsed.text.contains("Good evening."))
        XCTAssertTrue(parsed.text.contains("Geopolitics is the influence"))
    }

    func testObsidianWebClipperImportCleansBlogMarkdownLinks() throws {
        let markdown = """
        ---
        title: "We’ve Been Thinking About AI All Wrong"
        source: "https://www.foursightonline.com/blog/weve-been-thinking-about-ai-all-wrong"
        ---
        Last May, someone said:

        > We think of AI as a tool.

        For more information go to [https://atdconference.td.org](https://atdconference.td.org/)
        [See the platform](https://www.foursightonline.com/the-platform-old)
        """

        let parsed = try ObsidianMarkdownParser.parse(fileName: "clip.md", contents: markdown)

        XCTAssertEqual(parsed.title, "We’ve Been Thinking About AI All Wrong")
        XCTAssertTrue(parsed.text.contains("We think of AI as a tool."))
        XCTAssertTrue(parsed.text.contains("See the platform"))
        XCTAssertFalse(parsed.text.contains("---"))
        XCTAssertFalse(parsed.text.contains("https://"))
    }

    func testCapabilityGateRejectsUnsupportedCommand() throws {
        let profile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: ["remoteControl": ["display_snapshot", "send_transport_commands"]],
            forbiddenCapabilities: ["record_audio"]
        )
        let repo = InMemorySessionRepository(items: [
            "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        ])
        let engine = SessionEngine(profile: profile, repository: repo)
        XCTAssertThrowsError(try engine.startSession(itemId: "item-pill"))
    }

    func testCompactControlSnapshotExposesOnlyDelegatedCommands() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["chapter_timing"],
                "interjection": ["delegate_interjection_to_canonical_runtime"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands"]
            ],
            forbiddenCapabilities: ["record_audio", "summarize_interjections", "continue_discussion"]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")

        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)
        let snapshot = dispatcher.snapshot()

        XCTAssertEqual(snapshot.title, "Pill")
        XCTAssertEqual(snapshot.chapterTitle, "Opening")
        XCTAssertTrue(snapshot.compactSurfaceReady)
        XCTAssertTrue(snapshot.exposedCommands.contains(.play))
        XCTAssertTrue(snapshot.exposedCommands.contains(.pause))
        XCTAssertTrue(snapshot.exposedCommands.contains(.togglePlayPause))
        XCTAssertTrue(snapshot.exposedCommands.contains(.jumpToChapter))
        XCTAssertTrue(snapshot.exposedCommands.contains(.beginInterjection))
        XCTAssertFalse(snapshot.exposedCommands.contains(.finishInterjection))
        XCTAssertFalse(snapshot.availableCommands.contains(.play))
        XCTAssertTrue(snapshot.availableCommands.contains(.pause))
        XCTAssertTrue(snapshot.availableCommands.contains(.togglePlayPause))
        XCTAssertTrue(snapshot.availableCommands.contains(.skipBack))
        XCTAssertTrue(snapshot.availableCommands.contains(.skipForward))
        XCTAssertTrue(snapshot.availableCommands.contains(.jumpToChapter))
        XCTAssertTrue(snapshot.availableCommands.contains(.beginInterjection))
        XCTAssertFalse(snapshot.availableCommands.contains(.finishInterjection))
        XCTAssertEqual(snapshot.timeline.first?.kind, "overview")
        XCTAssertEqual(snapshot.timeline.first?.title, "Summary")
        XCTAssertEqual(snapshot.timeline.filter { $0.kind == "source_chapter" }.map(\.title), ["Opening", "Middle"])
    }

    func testCompactControlCommandsDelegateToCanonicalRuntime() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "lock-screen-widget",
            displayName: "Lock Screen / Widget",
            capabilities: [
                "timeline": ["chapter_timing"],
                "interjection": ["delegate_interjection_to_canonical_runtime"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands", "send_ai_commands"]
            ]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)

        let paused = try dispatcher.dispatch(.togglePlayPause)
        XCTAssertTrue(paused.delegatedToCanonicalRuntime)
        XCTAssertEqual(paused.snapshot.status, .paused)

        let played = try dispatcher.dispatch(.play)
        XCTAssertTrue(played.delegatedToCanonicalRuntime)
        XCTAssertEqual(played.snapshot.status, .playing)

        let pausedAgain = try dispatcher.dispatch(.pause)
        XCTAssertTrue(pausedAgain.delegatedToCanonicalRuntime)
        XCTAssertEqual(pausedAgain.snapshot.status, .paused)

        _ = try dispatcher.dispatch(.play)

        let jumped = try dispatcher.dispatch(.jumpToChapter, chapterId: "ch-middle")
        XCTAssertTrue(jumped.delegatedToCanonicalRuntime)
        XCTAssertEqual(jumped.snapshot.chapterTitle, "Middle")

        let recording = try dispatcher.dispatch(.beginInterjection)
        XCTAssertTrue(recording.delegatedToCanonicalRuntime)
        XCTAssertEqual(recording.snapshot.phase, .recordingInterjection)
        XCTAssertFalse(recording.snapshot.exposedCommands.contains(.beginInterjection))
        XCTAssertTrue(recording.snapshot.exposedCommands.contains(.finishInterjection))

        let finished = try dispatcher.dispatch(.finishInterjection)
        XCTAssertTrue(finished.delegatedToCanonicalRuntime)
        XCTAssertEqual(finished.snapshot.phase, .itemPlayback)
        XCTAssertEqual(finished.snapshot.status, .playing)
        XCTAssertEqual(engine.currentSession?.itemId, "item-pill")
        XCTAssertTrue(finished.snapshot.timeline.contains { $0.kind == "interjection" })

        let summary = try dispatcher.dispatch(.generateInterjectionSummary)
        XCTAssertTrue(summary.delegatedToCanonicalRuntime)
        XCTAssertEqual(summary.snapshot.pendingAiJobKind, "interjection_summary")
        XCTAssertEqual(summary.snapshot.pendingAiJobStatus, "pending")
        XCTAssertTrue(summary.snapshot.timeline.contains { $0.kind == "interjection_summary" && $0.title == "Interjection Summary 1" })

        let discussion = try dispatcher.dispatch(.submitFollowup, followUpText: "Can you respond to my interjection?")
        XCTAssertTrue(discussion.delegatedToCanonicalRuntime)
        XCTAssertEqual(discussion.snapshot.phase, .conversation)
        XCTAssertEqual(discussion.snapshot.lastUserTurnType, "user_response")
        XCTAssertEqual(discussion.snapshot.pendingAiJobKind, "assistant_response")
    }

    func testCompactControlRejectsUnsupportedSurfaceCommands() throws {
        let surfaceProfile = RuntimeCapabilityProfile(
            id: "car-basic",
            displayName: "Basic Car",
            capabilities: ["remoteControl": ["display_snapshot", "send_transport_commands"]]
        )
        let engine = try compactControlEngine()
        _ = try engine.startSession(itemId: "item-pill")
        let dispatcher = CompactControlDispatcher(surfaceProfile: surfaceProfile, canonicalRuntime: engine)

        XCTAssertThrowsError(try dispatcher.dispatch(.jumpToChapter, chapterId: "ch-middle")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("jumpToChapter"))
        }
        XCTAssertThrowsError(try dispatcher.dispatch(.beginInterjection)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("beginInterjection"))
        }
        XCTAssertThrowsError(try dispatcher.dispatch(.generateInterjectionSummary)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("generateInterjectionSummary"))
        }
        XCTAssertThrowsError(try dispatcher.dispatch(.submitFollowup, followUpText: "Discuss this.")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("submitFollowup"))
        }
    }

    func testDirectAICommandsRejectProfilesWithoutAIOrDeferralCapability() throws {
        let profile = RuntimeCapabilityProfile(
            id: "watch-untethered",
            displayName: "Watch Untethered",
            capabilities: [
                "playback": ["realtime_tts"],
                "timeline": ["text_char_offsets"],
                "interjection": ["record_audio", "capture_text_anchor"],
                "sync": ["canonical_persistence"]
            ],
            forbiddenCapabilities: ["summarize_interjections", "continue_discussion", "defer_ai_jobs"]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/watch.m4a")

        XCTAssertThrowsError(try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: engine.currentSession?.id))) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("generateInterjectionSummary"))
        }
        XCTAssertThrowsError(try engine.submitFollowup(text: "Discuss this.")) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("submitFollowup"))
        }
    }

    func testPlaybackStartRemainsStartingUntilAudioConfirms() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio
        )

        let starting = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(starting.status, .starting)

        audio.startStatus = .confirmed
        let confirmed = try engine.syncPlaybackProgress()
        XCTAssertEqual(confirmed.status, .playing)
    }

    func testPlaybackStartFailurePublishesFailedWithoutClaimingPlaying() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .failed("native_audio_failed")
        let engine = SessionEngine(
            profile: phonePlaybackProfile(),
            repository: InMemorySessionRepository(items: [
                "item-pill": Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
            ]),
            audio: audio
        )

        let failed = try engine.startSession(itemId: "item-pill")
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastFailure, "playback_start_failed:native_audio_failed")
    }

    func testSQLiteStorePersistsCoreRecords() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        try store.seed(item: item)
        let session = Session(id: "session-1", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        try store.saveSession(session)
        let interjection = Interjection(
            id: "ij-1",
            itemId: item.id,
            sessionId: session.id,
            targetType: .item,
            targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 3, anchorBefore: "One.", anchorAfter: "Two."),
            audioPath: "ij.m4a",
            audioStatus: "saved",
            transcriptionStatus: "pending",
            transcript: nil,
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        try store.saveInterjection(interjection)
        let job = AIJob(id: "job-1", kind: "assistant_response", itemId: item.id, sessionId: session.id, turnId: "turn-1", providerType: "fixture", model: "fixture", status: "retryable", attempts: 1, lastError: "offline", messages: ["hello"], playbackMode: "item_text_tts")
        try store.saveAIJob(job)
        let transcript = SourceTranscriptTimeline(
            id: "transcript-1",
            itemId: item.id,
            createdAt: Date(timeIntervalSince1970: 2),
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 1_000, text: "One.")],
                chapters: [MediaTimelineChapter(id: "ch-1", title: "One", startMs: 0, transcriptSegmentId: "seg-1")],
                durationMs: 1_000
            )
        )
        try store.saveTranscriptTimeline(transcript)

        XCTAssertEqual(try store.loadItem(id: item.id), item)
        XCTAssertEqual(try store.loadSession(id: session.id), session)
        XCTAssertEqual(try store.loadInterjections(sessionId: session.id).first?.audioPath, "ij.m4a")
        XCTAssertEqual(try store.loadAIJobs(sessionId: session.id).first?.status, "retryable")
        XCTAssertEqual(try store.loadTranscriptTimeline(itemId: item.id)?.id, transcript.id)
    }

    func testSQLiteStorePersistsWatchPackageEventsAndRequests() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let package = WatchAudioPackage(
            id: "watch-package-1",
            itemId: "item-audio",
            sessionId: "session-watch-1",
            createdAt: Date(timeIntervalSince1970: 1),
            item: WatchPackageItem(title: "Audio Item", mediaType: "text", externalReference: "icloud://item-audio"),
            audioAssets: [WatchPackageAudioAsset(audioAssetId: "asset-1", fileName: "asset.m4a", durationMs: 60_000)],
            transcript: WatchPackageTranscript(
                transcriptId: "transcript-1",
                segments: [MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, startChar: 0, endChar: 12, text: "Opening line.")]
            ),
            chapters: [MediaTimelineChapter(id: "ch-1", title: "Opening", startMs: 0, transcriptSegmentId: "seg-1")],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let event = WatchSyncEvent(
            id: "watch-event-1",
            watchPackageId: package.id,
            sessionId: package.sessionId,
            itemId: package.itemId,
            eventType: "interjection_recorded",
            createdAt: Date(timeIntervalSince1970: 2),
            payload: WatchSyncEventPayload(mediaTimeMs: 1_000, transcriptSegmentId: "seg-1", audioFileName: "watch-ij-1.m4a")
        )
        let request = WatchPackageRequestEvent(
            id: "request-1",
            itemId: package.itemId,
            packageId: package.id,
            requestType: .watchTransferRequested,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        try store.saveWatchAudioPackage(package)
        try store.saveWatchSyncEvent(event)
        try store.markWatchSyncEventImported(id: event.id)
        try store.saveWatchPackageRequest(request)

        XCTAssertEqual(try store.loadWatchAudioPackage(id: package.id)?.id, package.id)
        XCTAssertEqual(try store.loadWatchSyncEvent(id: event.id)?.payload.audioFileName, "watch-ij-1.m4a")
        XCTAssertEqual(try store.loadWatchSyncEvents(sessionId: package.sessionId).map(\.id), [event.id])
        XCTAssertEqual(try store.hasImportedWatchSyncEvent(id: event.id), true)
        XCTAssertEqual(try store.loadWatchPackageRequests(itemId: package.itemId).map(\.requestType), [.watchTransferRequested])
        XCTAssertEqual(try store.loadWatchAudioPackages(itemId: package.itemId).map(\.id), [package.id])
    }

    func testMediaTimelineResolverUsesBoundaryToleranceAndFallback() throws {
        let timeline = MediaTimeline(
            segments: [
                MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, startChar: 0, endChar: 10, text: "First"),
                MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, startChar: 11, endChar: 20, text: "Second")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-1", title: "One", startMs: 0, transcriptSegmentId: "seg-1"),
                MediaTimelineChapter(id: "ch-2", title: "Two", startMs: 10_000, transcriptSegmentId: "seg-2")
            ],
            durationMs: 20_000
        )

        let boundary = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 9_900, timeline: timeline, boundaryToleranceMs: 250)
        XCTAssertEqual(boundary.transcriptSegmentId, "seg-1")
        XCTAssertEqual(boundary.chapterId, "ch-1")

        let toleratedNext = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 10_020, timeline: timeline, boundaryToleranceMs: 250)
        XCTAssertEqual(toleratedNext.transcriptSegmentId, "seg-2")
        XCTAssertEqual(toleratedNext.chapterId, "ch-2")

        let fallback = MediaTimelineAnchorResolver.resolve(mediaTimeMs: 40_000, timeline: timeline, boundaryToleranceMs: 250)
        XCTAssertEqual(fallback.transcriptSegmentId, "seg-2")
        XCTAssertEqual(fallback.mediaTimeMs, 40_000)
    }

    func testTextPlaybackPositionMapsInterjectionToSourceContext() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"]
            ]
        )
        let text = "First sentence. Second sentence."
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let audio = RecordingAudioClient()
        let transcriber = RecordingTranscriptionClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio, transcriber: transcriber)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "First ".count
        let progress = try engine.syncPlaybackProgress()

        XCTAssertEqual(progress.currentTextStart, "First ".count)
        XCTAssertEqual(progress.currentAnchorConfidence, .textRange)

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/text.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .text)
        XCTAssertEqual(interjection.anchor.startChar, "First ".count)
        XCTAssertTrue(interjection.anchor.anchorBefore.contains("sentence"))
        XCTAssertEqual(transcriber.scheduledInterjectionIds, [interjection.id])
    }

    func testMediaPlaybackPositionPublishesTimelineAnchorAndDuration() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-offline",
            displayName: "Phone/Tablet Offline",
            capabilities: [
                "sync": ["receive_prepared_packages", "canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let package = WatchAudioPackage(
            id: "package-media",
            itemId: "item-media",
            sessionId: "session-media",
            createdAt: Date(timeIntervalSince1970: 1),
            item: WatchPackageItem(title: "Media", mediaType: "transcript_backed_media", externalReference: "https://example.com/audio.mp3"),
            audioAssets: [WatchPackageAudioAsset(audioAssetId: "asset-media", fileName: "media.m4a", durationMs: 20_000)],
            transcript: WatchPackageTranscript(
                transcriptId: "transcript-media",
                segments: [
                    MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, startChar: 0, endChar: 14, text: "First segment."),
                    MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, startChar: 15, endChar: 30, text: "Second segment.")
                ]
            ),
            chapters: [
                MediaTimelineChapter(id: "ch-1", title: "Opening", startMs: 0, transcriptSegmentId: "seg-1"),
                MediaTimelineChapter(id: "ch-2", title: "Middle", startMs: 10_000, transcriptSegmentId: "seg-2")
            ],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(watchPackages: [package.id: package])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.loadWatchPackage(watchPackageId: package.id)
        _ = try engine.resumePlayback()
        audio.currentMediaTimeValue = 12_000
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.currentMediaTimeMs, 12_000)
        XCTAssertEqual(snapshot.currentPlaybackDurationMs, 20_000)
        XCTAssertEqual(snapshot.currentTranscriptSegmentId, "seg-2")
        XCTAssertEqual(snapshot.currentAnchorConfidence, .transcriptSpan)
        XCTAssertEqual(snapshot.chapterTitle, "Middle")
    }

    func testLinkResolutionContractCanRepresentResolvedPodcastEpisode() throws {
        let request = LinkResolutionRequest(
            id: "link-request-1",
            inputURL: "https://open.spotify.com/episode/example",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", title: "Example Show", role: "canonical_feed"),
            title: "Episode Title",
            showTitle: "Example Show",
            durationMs: 1_800_000,
            publishedAt: "2026-06-19",
            audioURL: "https://cdn.example.com/episode.mp3",
            confidence: 0.96
        )
        let result = LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, provider: "spotify", role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        )

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(result.originalLink.role, "discovery")
    }

    func testImportSourceLinkCreatesPlayableNativeAudioItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let request = LinkResolutionRequest(
            id: "link-request-episode",
            inputURL: "https://open.spotify.com/episode/example",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", title: "Example Show", role: "canonical_feed"),
            title: "Episode Title",
            showTitle: "Example Show",
            durationMs: 1_800_000,
            publishedAt: "2026-06-19",
            audioURL: "https://cdn.example.com/episode.mp3",
            confidence: 0.96
        )
        let resolver = StaticLinkResolutionClient(result: LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, provider: "spotify", role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        ))
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo, linkResolver: resolver)

        let snapshot = try engine.importSourceLink(request)

        XCTAssertEqual(snapshot.linkResolutionStatus, LinkResolutionStatus.playable.rawValue)
        XCTAssertNil(snapshot.linkResolutionFailureReason)
        XCTAssertEqual(snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(snapshot.currentPlaybackDurationMs, 1_800_000)
        XCTAssertEqual(snapshot.currentAnchorConfidence, .providerMetadata)

        let itemId = try XCTUnwrap(snapshot.itemId)
        let item = try repo.loadItem(id: itemId)
        XCTAssertEqual(item.title, "Episode Title")
        XCTAssertEqual(item.mediaType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(item.externalReference, request.inputURL)
        XCTAssertEqual(item.externalReferenceType, "url")
        XCTAssertEqual(item.media?.sourceType, .remoteStream)
        XCTAssertEqual(item.media?.url, "https://cdn.example.com/episode.mp3")
        XCTAssertEqual(item.media?.durationMs, 1_800_000)
    }

    func testImportSourceLinkUnsupportedDoesNotCreateItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: ["sync": ["canonical_persistence"]]
        )
        let request = LinkResolutionRequest(
            id: "link-request-unsupported",
            inputURL: "https://example.com/not-a-podcast",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository())

        let snapshot = try engine.importSourceLink(request)

        XCTAssertEqual(snapshot.linkResolutionStatus, LinkResolutionStatus.unsupported.rawValue)
        XCTAssertEqual(snapshot.linkResolutionFailureReason, "no_link_resolver_configured")
        XCTAssertNil(snapshot.itemId)
        XCTAssertNil(engine.currentItem)
    }

    func testImportSourceLinkRequiresCanonicalPersistence() throws {
        let profile = RuntimeCapabilityProfile(
            id: "widget",
            displayName: "Widget",
            capabilities: ["remoteControl": ["display_snapshot"]]
        )
        let request = LinkResolutionRequest(
            id: "link-request-denied",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository())

        XCTAssertThrowsError(try engine.importSourceLink(request)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("importSourceLink"))
        }
    }

    func testImportedNativeAudioItemStartsMediaPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let request = LinkResolutionRequest(
            id: "link-request-start",
            inputURL: "https://example.com/episode",
            sourceSurface: "share_sheet",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: SourceLink(url: "https://feeds.example.com/show.xml", provider: "rss", role: "canonical_feed"),
            title: "Playable Episode",
            durationMs: 600_000,
            audioURL: "https://cdn.example.com/playable.mp3",
            confidence: 0.9
        )
        let resolver = StaticLinkResolutionClient(result: LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            selectedCandidate: candidate,
            candidates: [candidate]
        ))
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository(), audio: audio, linkResolver: resolver)

        let snapshot = try engine.importSourceLink(request, startSessionWhenPlayable: true)

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(snapshot.targetId, "https://cdn.example.com/playable.mp3")
        XCTAssertEqual(snapshot.currentMediaTimeMs, 0)
        XCTAssertEqual(snapshot.currentPlaybackDurationMs, 600_000)
        XCTAssertEqual(audio.playedTargets, ["https://cdn.example.com/playable.mp3"])
        XCTAssertEqual(audio.playedOffsets, [0])
        XCTAssertEqual(audio.preparedTexts, [])
        let mediaContext = try XCTUnwrap(audio.mediaContexts.compactMap { $0 }.last)
        XCTAssertEqual(mediaContext.itemId, snapshot.itemId)
        XCTAssertEqual(mediaContext.title, "Playable Episode")
        XCTAssertEqual(mediaContext.durationMs, 600_000)
        XCTAssertEqual(mediaContext.sourceType, .remoteStream)
    }

    func testTranscriptlessNativeAudioInterjectionAnchorsToMediaTime() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-source-audio",
            title: "Native Audio",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 123_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/media.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .media)
        XCTAssertEqual(interjection.anchor.mediaTimeMs, 123_000)
        XCTAssertNil(interjection.anchor.transcriptSegmentId)
        XCTAssertEqual(interjection.anchor.playbackRateObserved, 1)

        let export = try engine.buildExport(options: ExportOptions(
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)
        XCTAssertEqual(export.item.mediaSourceType, AudioSourceType.remoteStream.rawValue)
        XCTAssertEqual(export.interjections.first?.mediaTimeMs, 123_000)
        XCTAssertTrue(markdown.contains("Media time: 2:03"))
        XCTAssertTrue(markdown.contains("Source Type: remote_stream"))
    }

    func testSourceWindowContextUpdatesMediaInterjectionAnchorWithoutChangingNoteTranscript() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-source-window",
            title: "Windowed Native Audio",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 900_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 123_000
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/media-window.m4a")
        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        let window = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "window-seg-1", startMs: 90_000, endMs: 122_000, text: "Context before the note."),
                MediaTimelineSegment(id: "window-seg-2", startMs: 122_000, endMs: 150_000, text: "Context at the note."),
                MediaTimelineSegment(id: "window-seg-3", startMs: 150_000, endMs: 180_000, text: "Context after the note.")
            ],
            chapters: [],
            durationMs: 900_000
        )

        _ = try engine.sourceWindowContextCompleted(interjectionId: interjection.id, timeline: window)

        let updated = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(updated.anchor.anchorType, .transcript)
        XCTAssertEqual(updated.anchor.mediaTimeMs, 123_000)
        XCTAssertEqual(updated.anchor.anchorBefore, "Context at the note.")
        XCTAssertEqual(updated.anchor.anchorAfter, "Context after the note.")
        XCTAssertNotNil(updated.anchor.transcriptSegmentId)
        XCTAssertNil(updated.transcript)
        XCTAssertEqual(updated.transcriptionStatus, "pending")
    }

    func testNativeAudioSkipWorksWithoutWatchPackage() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-skip",
            title: "Native Skip",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 90_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 30_000
        let forward = try engine.skipForward(unit: "time_15s")
        XCTAssertEqual(forward.currentMediaTimeMs, 45_000)
        XCTAssertEqual(audio.playedOffsets.last, 45_000)

        audio.currentMediaTimeValue = 45_000
        let back = try engine.skipBack(unit: "time_15s")
        XCTAssertEqual(back.currentMediaTimeMs, 30_000)
        XCTAssertEqual(audio.playedOffsets.last, 30_000)
    }

    func testNativeAudioPlaybackRatePropagatesToAudioClientAndSnapshot() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"]
            ]
        )
        let item = Item(
            id: "item-native-rate",
            title: "Native Rate",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 120_000)
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        let snapshot = try engine.setPlaybackRate(1.5)

        XCTAssertEqual(snapshot.playbackRate, 1.5)
        XCTAssertEqual(engine.currentSession?.playbackRate, 1.5)
        XCTAssertEqual(audio.playbackRates.last, 1.5)
    }

    func testPreparedTextAudioUsesMediaPlaybackAndTranscriptAnchors() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                "interjection": ["record_audio", "capture_transcript_anchor"]
            ]
        )
        let item = Item(
            id: "item-text-audio",
            title: "Prepared Text",
            mediaType: "text",
            text: "First sentence. Second sentence.",
            externalReference: nil,
            status: "ready"
        )
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2")
            ],
            durationMs: 2_300
        )
        let prepared = PreparedTextAudio(
            normalizedText: "First sentence. Second sentence.",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-text.caf",
                durationMs: 2_300,
                nativeMediaId: "file:///tmp/generated-text.caf"
            ),
            timeline: timeline
        )
        let audio = RecordingAudioClient()
        let textAudio = RecordingTextAudioPreparationClient(prepared: prepared)
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio, textAudio: textAudio)

        let started = try engine.startSession(itemId: item.id)

        XCTAssertEqual(started.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(started.targetId, "file:///tmp/generated-text.caf")
        XCTAssertEqual(started.currentPlaybackDurationMs, 2_300)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/generated-text.caf")
        XCTAssertEqual(audio.playedOffsets.last, 0)
        XCTAssertEqual(audio.playbackRates.last, 1)
        let mediaContext = try XCTUnwrap(audio.mediaContexts.compactMap { $0 }.last)
        XCTAssertEqual(mediaContext.title, "Prepared Text")
        XCTAssertEqual(mediaContext.sourceType, .generatedTTSPrerendered)
        XCTAssertEqual(mediaContext.chapters.map(\.id), ["ch-tts-1", "ch-tts-2"])
        XCTAssertEqual(try repo.loadItem(id: item.id).media?.sourceType, .generatedTTSPrerendered)
        XCTAssertEqual(try repo.loadTranscriptTimeline(itemId: item.id)?.timeline.segments.map(\.id), ["tts-1", "tts-2"])

        audio.currentMediaTimeValue = 1_200
        let progress = try engine.syncPlaybackProgress()
        XCTAssertEqual(progress.currentTranscriptSegmentId, "tts-2")
        XCTAssertEqual(progress.currentAnchorConfidence, .transcriptSpan)
        XCTAssertEqual(progress.chapterTitle, "Second")

        _ = try engine.setPlaybackRate(1.5)
        XCTAssertEqual(audio.playbackRates.last, 1.5)

        _ = try engine.seekMedia(toMediaTimeMs: 1_000)
        XCTAssertEqual(audio.playedOffsets.last, 1_000)

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/generated-text.m4a")
        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .transcript)
        XCTAssertEqual(interjection.anchor.transcriptSegmentId, "tts-2")
        XCTAssertEqual(interjection.anchor.anchorBefore, "Second sentence.")
    }

    func testPreparedTextAudioAttachmentMigratesActiveLiveTextSessionToMedia() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-live-to-media",
            title: "Live To Media",
            mediaType: "text",
            text: "First sentence. Second sentence.",
            externalReference: nil,
            status: "ready"
        )
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2")
            ],
            durationMs: 2_300
        )
        let prepared = PreparedTextAudio(
            normalizedText: item.text ?? "",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/live-to-media.caf",
                durationMs: 2_300,
                nativeMediaId: "file:///tmp/live-to-media.caf"
            ),
            timeline: timeline
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(engine.currentSession?.currentTargetType, .itemTextTTS)
        audio.currentOffset = 16

        let migrated = try engine.attachPreparedTextAudio(itemId: item.id, prepared: prepared)

        XCTAssertEqual(migrated.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(migrated.targetId, "file:///tmp/live-to-media.caf")
        XCTAssertEqual(migrated.currentMediaTimeMs, 1_000)
        XCTAssertEqual(migrated.currentTranscriptSegmentId, "tts-2")
        XCTAssertEqual(engine.currentSession?.currentTargetType, .transcriptBackedMedia)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/live-to-media.caf")
        XCTAssertEqual(audio.playedOffsets.last, 1_000)
    }

    func testPreparedTextAudioAttachmentReplacesStarterMediaWithoutLosingPlayhead() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-starter-to-full",
            title: "Starter To Full",
            mediaType: "text",
            text: "First sentence. Second sentence. Third sentence.",
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-starter.caf",
                durationMs: 1_000,
                nativeMediaId: "file:///tmp/generated-starter.caf"
            ),
            transcriptId: "generated-transcript-item-starter-to-full"
        )
        let starterTimeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1")
            ],
            durationMs: 1_000
        )
        let fullTimeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "tts-2", startMs: 1_000, endMs: 2_300, startChar: 16, endChar: 32, text: "Second sentence."),
                MediaTimelineSegment(id: "tts-3", startMs: 2_300, endMs: 3_600, startChar: 33, endChar: 48, text: "Third sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1"),
                MediaTimelineChapter(id: "ch-tts-2", title: "Second", startMs: 1_000, transcriptSegmentId: "tts-2"),
                MediaTimelineChapter(id: "ch-tts-3", title: "Third", startMs: 2_300, transcriptSegmentId: "tts-3")
            ],
            durationMs: 3_600
        )
        let prepared = PreparedTextAudio(
            normalizedText: item.text ?? "",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-full.caf",
                durationMs: 3_600,
                nativeMediaId: "file:///tmp/generated-full.caf"
            ),
            timeline: fullTimeline
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-starter-to-full",
            itemId: item.id,
            createdAt: Date(),
            timeline: starterTimeline
        ))
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/generated-starter.caf")
        audio.currentMediaTimeValue = 700

        let replaced = try engine.attachPreparedTextAudio(itemId: item.id, prepared: prepared)

        XCTAssertEqual(replaced.targetId, "file:///tmp/generated-full.caf")
        XCTAssertEqual(replaced.currentMediaTimeMs, 733)
        XCTAssertEqual(replaced.currentPlaybackDurationMs, 3_600)
        XCTAssertEqual(audio.playedTargets.last, "file:///tmp/generated-full.caf")
        XCTAssertEqual(audio.playedOffsets.last, 733)
        XCTAssertEqual(engine.currentSession?.currentTargetId, "file:///tmp/generated-full.caf")
        XCTAssertEqual(try repo.loadItem(id: item.id).media?.url, "file:///tmp/generated-full.caf")
        XCTAssertEqual(try repo.loadTranscriptTimeline(itemId: item.id)?.timeline.segments.map(\.id), ["tts-1", "tts-2", "tts-3"])
    }

    func testPartialStarterGeneratedTextAudioCompletionDoesNotCompleteSource() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"]
            ]
        )
        let item = Item(
            id: "item-partial-starter",
            title: "Partial Starter",
            mediaType: "text",
            text: "First sentence. Second sentence. Third sentence.",
            externalReference: nil,
            status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: "file:///tmp/generated-partial-starter.caf",
                durationMs: 1_000,
                nativeMediaId: "file:///tmp/generated-partial-starter.caf"
            ),
            transcriptId: "generated-transcript-item-partial-starter"
        )
        let starterTimeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "tts-1", startMs: 0, endMs: 1_000, startChar: 0, endChar: 15, text: "First sentence.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-tts-1", title: "First", startMs: 0, transcriptSegmentId: "tts-1")
            ],
            durationMs: 1_000
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        try repo.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-partial-starter",
            itemId: item.id,
            createdAt: Date(),
            timeline: starterTimeline
        ))
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 1_000
        audio.completedTargetIds.insert("file:///tmp/generated-partial-starter.caf")
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(snapshot.preparedTextAudioStatus, "starter_ready")
        XCTAssertLessThan(snapshot.sourceProgressPercent, 100)
        XCTAssertLessThan(snapshot.currentPlaybackProgressPercent, 100)
    }

    func testSourceTranscriptTimelineAnchorsNativeAudioAndGeneratesListeningMap() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                "ai": ["generate_listening_map"],
                "interjection": ["record_audio", "capture_media_anchor"]
            ]
        )
        let item = Item(
            id: "item-native-transcript",
            title: "Native Transcript",
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: "https://example.com/episode",
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 30_000)
        )
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 10_000, text: "Opening thought."),
                MediaTimelineSegment(id: "seg-2", startMs: 10_000, endMs: 20_000, text: "Important middle point."),
                MediaTimelineSegment(id: "seg-3", startMs: 20_000, endMs: 30_000, text: "Closing thought.")
            ],
            chapters: [
                MediaTimelineChapter(id: "ch-1", title: "Opening", startMs: 0, transcriptSegmentId: "seg-1"),
                MediaTimelineChapter(id: "ch-2", title: "Middle", startMs: 10_000, transcriptSegmentId: "seg-2")
            ],
            durationMs: 30_000
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.attachTranscriptTimeline(itemId: item.id, timeline: timeline)
        _ = try engine.startSession(itemId: item.id)
        audio.currentMediaTimeValue = 12_000
        let progress = try engine.syncPlaybackProgress()

        XCTAssertEqual(progress.currentTranscriptSegmentId, "seg-2")
        XCTAssertEqual(progress.currentAnchorConfidence, .transcriptSpan)
        XCTAssertEqual(progress.chapterTitle, "Middle")

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/native-transcript.m4a")
        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: engine.currentSession?.id ?? "").first)
        XCTAssertEqual(interjection.anchor.anchorType, .transcript)
        XCTAssertEqual(interjection.anchor.transcriptSegmentId, "seg-2")
        XCTAssertEqual(interjection.anchor.anchorBefore, "Important middle point.")

        let mapSnapshot = try engine.generateListeningMap(itemId: item.id)
        let map = try XCTUnwrap(try repo.loadListeningMap(itemId: item.id))
        XCTAssertEqual(mapSnapshot.itemId, item.id)
        XCTAssertFalse(map.chapters.isEmpty)
        XCTAssertTrue((try repo.loadItem(id: item.id).text ?? "").contains("Important middle point."))
    }

    func testInMemoryRepositoryListsWatchPackagesByItem() throws {
        let first = WatchAudioPackage(
            id: "package-1",
            itemId: "item-a",
            sessionId: "session-1",
            createdAt: Date(timeIntervalSince1970: 1),
            item: WatchPackageItem(title: "First", mediaType: "text"),
            audioAssets: [],
            transcript: WatchPackageTranscript(transcriptId: "transcript-1", segments: []),
            chapters: [],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let second = WatchAudioPackage(
            id: "package-2",
            itemId: "item-a",
            sessionId: "session-2",
            createdAt: Date(timeIntervalSince1970: 2),
            item: WatchPackageItem(title: "Second", mediaType: "text"),
            audioAssets: [],
            transcript: WatchPackageTranscript(transcriptId: "transcript-2", segments: []),
            chapters: [],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let other = WatchAudioPackage(
            id: "package-3",
            itemId: "item-b",
            sessionId: "session-3",
            createdAt: Date(timeIntervalSince1970: 3),
            item: WatchPackageItem(title: "Other", mediaType: "text"),
            audioAssets: [],
            transcript: WatchPackageTranscript(transcriptId: "transcript-3", segments: []),
            chapters: [],
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
        let repository = InMemorySessionRepository(
            watchPackages: [
                first.id: first,
                second.id: second,
                other.id: other
            ]
        )

        XCTAssertEqual(try repository.loadWatchAudioPackages(itemId: "item-a").map(\.id), ["package-1", "package-2"])
    }

    private func compactControlEngine() throws -> SessionEngine {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone / Tablet Online",
            capabilities: [
                "playback": ["realtime_tts", "assistant_turn_tts", "summary_turn_tts"],
                "timeline": ["text_char_offsets", "chapter_timing"],
                "interjection": ["record_audio", "capture_text_anchor", "capture_turn_anchor"],
                "ai": ["summarize_interjections", "continue_discussion"],
                "sync": ["canonical_persistence"],
                "remoteControl": ["display_snapshot", "send_transport_commands", "send_chapter_jump", "send_interjection_commands", "send_ai_commands"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let map = ListeningMap(
            id: "map-pill",
            itemId: item.id,
            overview: "Overview.",
            chapters: [
                Chapter(id: "ch-opening", title: "Opening", startChar: 0, endChar: 8, percent: 0),
                Chapter(id: "ch-middle", title: "Middle", startChar: 10, endChar: 22, percent: 50)
            ]
        )
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        return SessionEngine(profile: profile, repository: repo)
    }

    private func phonePlaybackProfile() -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone / Tablet Online",
            capabilities: [
                "playback": ["realtime_tts", "assistant_turn_tts", "summary_turn_tts"],
                "timeline": ["text_char_offsets", "chapter_timing"],
                "interjection": ["record_audio", "capture_text_anchor", "capture_turn_anchor"],
                "ai": ["summarize_interjections", "continue_discussion", "defer_ai_jobs"],
                "sync": ["canonical_persistence"]
            ]
        )
    }

    func testSQLiteStoreListsAndDeletesItemScopedRecords() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let keep = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One.", externalReference: nil, status: "ready")
        let remove = Item(id: "item-import-1", title: "Import", mediaType: "text", text: "Two.", externalReference: nil, status: "ready")
        try store.seed(item: keep)
        try store.seed(item: remove)
        try store.saveSession(Session(id: "session-import", itemId: remove.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: remove.id, position: Position(), completionPercent: 0, playbackRate: 1))

        XCTAssertEqual(Set(try store.listItems().map(\.id)), ["item-pill", "item-import-1"])

        try store.deleteItem(id: remove.id)

        XCTAssertEqual(try store.listItems().map(\.id), ["item-pill"])
        XCTAssertNil(try store.loadSession(id: "session-import"))
    }

    func testSQLiteStoreReplacesListeningMapForItem() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        try store.seed(item: item)
        try store.saveListeningMap(ListeningMap(
            id: "map-original",
            itemId: item.id,
            overview: "Original",
            chapters: [Chapter(id: "original", title: "Original", startChar: 0, endChar: 4, percent: 0)]
        ))
        try store.saveListeningMap(ListeningMap(
            id: "map-manual",
            itemId: item.id,
            overview: "Manual",
            chapters: [Chapter(id: "manual-process", title: "Manual Process", startChar: 5, endChar: 9, percent: 50)]
        ))

        let loaded = try XCTUnwrap(try store.loadListeningMap(itemId: item.id))
        XCTAssertEqual(loaded.id, "map-manual")
        XCTAssertEqual(loaded.chapters.map(\.id), ["manual-process"])
    }

    func testManualListeningMapGenerationPersistsMapAndEnablesChapterJump() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"],
                "ai": ["generate_listening_map"]
            ]
        )
        let item = Item(
            id: "item-generated",
            title: "Generated",
            mediaType: "text",
            text: "Opening context is first. The middle explains the claim. The ending gives the consequence.",
            externalReference: nil,
            status: "needs_listening_map"
        )
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.generateListeningMap(itemId: item.id)

        let map = try XCTUnwrap(try repo.loadListeningMap(itemId: item.id))
        XCTAssertEqual(map.chapters.count, 3)
        XCTAssertEqual(try repo.loadItem(id: item.id).status, "ready")

        let target = map.chapters[1]
        let snapshot = try engine.jumpToChapter(chapterId: target.id)
        XCTAssertEqual(snapshot.chapterTitle, target.title)
        XCTAssertEqual(engine.currentSession?.position.charOffset, target.startChar)
    }

    func testStartSessionSpeaksListeningMapOverviewBeforeItemText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: "This item contrasts one with two.", chapters: [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 5, percent: 0)
        ])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)

        XCTAssertEqual(audio.preparedTexts.last, "Overview. This item contrasts one with two.\n\nOne. Two.")
        XCTAssertEqual(audio.playedOffsets.last, 0)
        XCTAssertEqual(engine.lastSpokenText, "Overview. This item contrasts one with two. One. Two.")
    }

    func testPauseAndResumePreserveSourcePosition() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.skipForward(unit: "sentence")
        let offsetBeforePause = try XCTUnwrap(engine.currentSession?.position.charOffset)
        let paused = try engine.pause()
        let offsetAfterPause = try XCTUnwrap(engine.currentSession?.position.charOffset)
        let resumed = try engine.resumePlayback()

        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(resumed.status, .playing)
        XCTAssertEqual(offsetAfterPause, offsetBeforePause)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), offsetBeforePause)
        XCTAssertEqual(audio.playedTargets, [item.id, item.id, item.id])
        XCTAssertEqual(audio.playedOffsets, [0, offsetBeforePause, offsetBeforePause])
    }

    func testSkipForwardUsesCurrentAudioPositionWhenAvailable() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 10
        let snapshot = try engine.skipForward(unit: "sentence")

        XCTAssertGreaterThanOrEqual(snapshot.progressPercent, 50)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 17)
        XCTAssertEqual(audio.playedOffsets.last, 17)
    }

    func testSkipForwardCanRequireMinimumDistanceForChunkedPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four. Five. Six.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 2
        let snapshot = try engine.skipForward(unit: "sentence", minimumDistance: 12)

        XCTAssertGreaterThan(snapshot.progressPercent, 50)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 17)
        XCTAssertEqual(audio.playedOffsets.last, 17)
    }

    func testParagraphSkipFallsBackToSentenceForSingleParagraphText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 0
        let forward = try engine.skipForward(unit: "paragraph")

        XCTAssertEqual(forward.progressPercent, 31)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 5)
        XCTAssertEqual(audio.playedOffsets.last, 5)

        audio.currentOffset = 10
        let back = try engine.skipBack(unit: "paragraph")

        XCTAssertEqual(back.progressPercent, 31)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 5)
    }

    func testSkipBackUsesCurrentAudioPositionAndPreviousBoundaryIsStrict() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 10
        let snapshot = try engine.skipBack(unit: "sentence")

        XCTAssertEqual(snapshot.progressPercent, 31)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 5)
        XCTAssertEqual(audio.playedOffsets.last, 5)
    }

    func testSyncPlaybackProgressPublishesCurrentAudioPosition() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three. Four.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 10
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.progressPercent, 45)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), 10)
        XCTAssertEqual(audio.playedOffsets, [0])
    }

    func testSyncPlaybackProgressMarksItemFinishedWhenAudioCompletes() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.completedTargetIds.insert(item.id)
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .finished)
        XCTAssertEqual(snapshot.progressPercent, 100)
        XCTAssertEqual(try XCTUnwrap(engine.currentSession?.position.charOffset), try XCTUnwrap(item.text).count)
    }

    func testAIJobCompletedPreservesActivePlaybackPhase() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = RecordingAudioClient()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = 0
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: engine.currentSession?.id))
        _ = try engine.aiStreamDelta(turnId: "turn-summary-001", content: "<sm_response>Summary text.</sm_response>")
        let snapshot = try engine.aiJobCompleted(turnId: "turn-summary-001")

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
    }

    func testFinishInterjectionSchedulesTranscriptionAfterAudioIsSaved() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let transcriber = RecordingTranscriptionClient()
        let engine = SessionEngine(profile: profile, repository: repo, transcriber: transcriber)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/ij-001.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)
        XCTAssertEqual(interjection.audioPath, "interjections/ij-001.m4a")
        XCTAssertEqual(interjection.transcriptionStatus, "pending")
        XCTAssertEqual(transcriber.scheduledInterjectionIds, [interjection.id])
        XCTAssertEqual(engine.lastScheduledTranscriptionInterjectionId, interjection.id)
    }

    func testPlayTurnPreparesTurnTextInsteadOfReusingItemText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "summary_turn_tts", "assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Original item text.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let summary = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary text should be spoken.", rawText: nil, sourceInterjectionIds: [])
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Response text should be spoken.", rawText: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [summary.id: summary, response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: summary.id)
        XCTAssertEqual(audio.preparedTexts.last, "Summary text should be spoken.")
        XCTAssertEqual(engine.snapshot.targetType, "summary_turn_tts")

        _ = try engine.playTurn(turnId: response.id)
        XCTAssertEqual(audio.preparedTexts.last, "Response text should be spoken.")
        XCTAssertEqual(engine.snapshot.targetType, "assistant_turn_tts")
    }

    func testJumpToChapterFromSummaryPlaybackReturnsToItemText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "summary_turn_tts"],
                "timeline": ["chapter_timing"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: "Map", chapters: [
            Chapter(id: "ch-1", title: "One", startChar: 0, endChar: 5, percent: 0),
            Chapter(id: "ch-2", title: "Two", startChar: 5, endChar: 16, percent: 31)
        ])
        let summary = ConversationTurn(id: "turn-summary-001", sessionId: "session-\(item.id)-gate1-001", role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary text.", rawText: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map], turns: [summary.id: summary])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.playTurn(turnId: summary.id)
        let snapshot = try engine.jumpToChapter(chapterId: "ch-2")

        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(audio.preparedTexts.last, "Overview. Map\n\nOne. Two. Three.")
        XCTAssertEqual(audio.playedOffsets.last, "Overview. Map\n\n".count + 5)
    }

    func testInspectSessionDoesNotStartPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let session = Session(id: "session-existing", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: 5), completionPercent: 45, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let snapshot = try engine.inspectSession(sessionId: session.id)

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.progressPercent, 45)
        XCTAssertEqual(snapshot.targetId, item.id)
        XCTAssertTrue(audio.playedOffsets.isEmpty)
    }

    func testInterjectionsOnAssistantTurnCanBeSummarizedAfterItemSummary() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "assistant_turn_tts"],
                "interjection": ["record_audio"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Assistant response text.", rawText: nil, sourceInterjectionIds: [])
        let itemInterjection = Interjection(id: "ij-item", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "One.", anchorAfter: "Two."), audioPath: "item.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "item note", cleanedTranscript: nil, displayText: "item note", status: "active")
        let turnInterjection = Interjection(id: "ij-turn", itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: response.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 0, anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 8, anchorBefore: "Assistant response text.", anchorAfter: ""), audioPath: "turn.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "turn note", cleanedTranscript: nil, displayText: "turn note", status: "active")
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [itemInterjection.id: itemInterjection, turnInterjection.id: turnInterjection], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "turn", sessionId: session.id, turnId: response.id))

        let summaries = try repo.loadTurns(sessionId: session.id).filter { $0.turnType == "interjection_summary" }.sorted { $0.id < $1.id }
        XCTAssertEqual(summaries.map(\.sourceInterjectionIds), [["ij-item"], ["ij-turn"]])
        XCTAssertEqual(summaries.map(\.id), ["turn-summary-001", "turn-summary-002"])
    }

    func testInterjectionSummaryRegenerationRequiresNewInterjectionAndReplacesCurrentTargetSummary() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["summarize_interjections"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two. Three.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let firstInterjection = Interjection(id: "ij-001", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "One.", anchorAfter: "Two."), audioPath: "one.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "first note", cleanedTranscript: nil, displayText: "first note", status: "active")
        let secondInterjection = Interjection(id: "ij-002", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 25, anchor: Anchor(anchorType: .text, startChar: 5, endChar: 9, anchorBefore: "Two.", anchorAfter: "Three."), audioPath: "two.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "second note", cleanedTranscript: nil, displayText: "second note", status: "active")
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [firstInterjection.id: firstInterjection])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))
        XCTAssertThrowsError(try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForState("interjection_summary_already_current"))
        }

        try repo.saveInterjection(secondInterjection)
        _ = try engine.aiStreamDelta(turnId: "turn-summary-001", content: "<sm_response>Old summary.</sm_response>")
        _ = try engine.aiJobCompleted(turnId: "turn-summary-001")
        _ = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item", sessionId: session.id))

        let summaries = try repo.loadTurns(sessionId: session.id).filter { $0.turnType == "interjection_summary" }
        XCTAssertEqual(summaries.map(\.id), ["turn-summary-001"])
        XCTAssertEqual(summaries.first?.sourceInterjectionIds, ["ij-001", "ij-002"])
        XCTAssertEqual(summaries.first?.status, "pending")
        XCTAssertNil(summaries.first?.text)
    }

    func testCancelInterjectionDoesNotCreateInterjectionAndResumes() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.beginInterjection()
        let snapshot = try engine.cancelInterjection()

        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(try repo.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).count, 0)
    }

    func testRepeatedStartsCreateDistinctSessionsForSameItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        let first = try XCTUnwrap(engine.currentSession?.id)
        _ = try engine.startSession(itemId: item.id)
        let second = try XCTUnwrap(engine.currentSession?.id)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set(repo.sessions.keys), [first, second])
    }

    func testRepeatedFollowupsCreateDistinctAssistantTurnsAndJobs() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "ai": ["continue_discussion"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "One. Two.", externalReference: nil, status: "ready")
        let repo = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.submitFollowup(text: "First")
        _ = try engine.submitFollowup(text: "Second")

        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        let responseTurns = try repo.loadTurns(sessionId: sessionId).filter { $0.turnType == "assistant_response" }.map(\.id).sorted()
        let jobs = try repo.loadAIJobs(sessionId: sessionId).filter { $0.kind == "assistant_response" }.map(\.id).sorted()
        XCTAssertEqual(responseTurns, ["turn-response-001", "turn-response-002"])
        XCTAssertEqual(jobs, ["job-assistant-response-001", "job-assistant-response-002"])
    }

    func testAssistantPlayableTextSpeaksSummaryBeforeResponse() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: "Full response.", rawText: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: response.id)

        XCTAssertEqual(audio.preparedTexts.last, "Brief intro.\n\nFull response.")
        XCTAssertEqual(audio.playedOffsets.last, 0)
    }

    func testAICompletionParsesSummaryResponseAndChapters() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: "<sm_summary>Two parts.</sm_summary><sm_response>Hello world. Second point.</sm_response><sm_chapters_json>{\"schemaVersion\":\"assistant-response-map.v1\",\"chapters\":[{\"id\":\"ch-1\",\"title\":\"Opening\",\"anchor\":\"Hello world.\"}]}</sm_chapters_json>"
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")

        let turn = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first)
        XCTAssertEqual(turn.summary, "Two parts.")
        XCTAssertEqual(turn.text, "Hello world. Second point.")
        XCTAssertEqual(turn.chapters?.first?.id, "ch-1")
    }

    func testImportAssistantResponseCreatesCompletedPlayableTurn() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        let snapshot = try engine.importAssistantResponse(
            text: "<sm_summary>Short setup.</sm_summary><sm_response>External response. Second point.</sm_response>",
            autoPlay: true
        )

        let turn = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first)
        XCTAssertEqual(turn.status, "complete")
        XCTAssertEqual(turn.summary, "Short setup.")
        XCTAssertEqual(turn.text, "External response. Second point.")
        XCTAssertEqual(snapshot.phase, .aiResponsePlayback)
        XCTAssertEqual(audio.preparedTexts.last, "Short setup.\n\nExternal response. Second point.")
    }

    func testScopedExportFiltersTargetInterjectionsAndMarkdown() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: "[[Pill]]", status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 20, playbackRate: 1)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief.", text: "Response text.", rawText: nil, sourceInterjectionIds: [])
        let itemInterjection = Interjection(id: "ij-item", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 6, anchorBefore: "Source.", anchorAfter: ""), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "source note", cleanedTranscript: "clean source note", displayText: nil, status: "active")
        let turnInterjection = Interjection(id: "ij-turn", itemId: item.id, sessionId: session.id, targetType: .assistantTurn, targetId: response.id, createdAt: Date(timeIntervalSince1970: 2), roughPercent: 30, anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 8, anchorBefore: "Response", anchorAfter: "text."), audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "turn note", cleanedTranscript: nil, displayText: nil, status: "active")
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [itemInterjection.id: itemInterjection, turnInterjection.id: turnInterjection], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo)

        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: true,
            scope: "target",
            targetType: InterjectionTargetType.assistantTurn.rawValue,
            targetId: response.id
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)

        XCTAssertEqual(export.interjections.map(\.id), ["ij-turn"])
        XCTAssertEqual(export.turns.map(\.id), [response.id])
        XCTAssertTrue(markdown.contains("turn note"))
        XCTAssertFalse(markdown.contains("source note"))
    }

    func testMalformedAIChaptersPreserveResponseText() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session])
        let engine = SessionEngine(profile: profile, repository: repo)

        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: "<sm_summary>Intro.</sm_summary><sm_response>Keep this usable response.</sm_response><sm_chapters_json>{bad json</sm_chapters_json>"
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")

        let turn = try XCTUnwrap(try repo.loadTurns(sessionId: session.id).first)
        XCTAssertEqual(turn.summary, "Intro.")
        XCTAssertEqual(turn.text, "Keep this usable response.")
        XCTAssertEqual(turn.chapters, [])
    }

    func testJumpToAssistantTurnChapterUsesSummaryPrefaceOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1)
        let chapter = Chapter(id: "ch-2", title: "Second", startChar: 16, endChar: 29, percent: 50)
        let response = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: "First response. Second point.", rawText: nil, chapters: [chapter], sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [response.id: response])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.jumpToTurnChapter(turnId: response.id, chapterId: chapter.id)

        XCTAssertEqual(audio.preparedTexts.last, "Brief intro.\n\nFirst response. Second point.")
        XCTAssertEqual(audio.playedOffsets.last, "Brief intro.\n\n".count + chapter.startChar)
    }

    func testSummaryPlaybackPublishesCurrentTargetProgressSeparateFromSourceProgress() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["summary_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "This summary is still playing.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        audio.currentOffset = 5
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.sourceProgressPercent, 100)
        XCTAssertLessThan(snapshot.currentPlaybackProgressPercent, 100)
        XCTAssertEqual(snapshot.chapterTitle, "Interjection Summary 1")
    }

    func testSummaryTurnCompletionPausesWithoutChangingSourceCompletion() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["summary_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        audio.completedTargetIds.insert(turn.id)
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .summaryPlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.summaryTurnTTS.rawValue)
        XCTAssertEqual(snapshot.sourceProgressPercent, 100)
    }

    func testAssistantTurnCompletionPausesInAIResponsePlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source complete.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .finished, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Response.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        _ = try engine.playTurn(turnId: turn.id)
        audio.completedTargetIds.insert(turn.id)
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.status, .paused)
        XCTAssertEqual(snapshot.phase, .aiResponsePlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(snapshot.sourceProgressPercent, 100)
    }

    func testFirstChapterJumpSkipsListeningMapSummaryPreface() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "timeline": ["chapter_timing"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "First chapter starts here. Second chapter follows.", externalReference: nil, status: "ready")
        let map = ListeningMap(
            id: "map-pill",
            itemId: item.id,
            overview: "Short source summary.",
            chapters: [
                Chapter(id: "ch-1", title: "First", startChar: 0, endChar: 26, percent: 0),
                Chapter(id: "ch-2", title: "Second", startChar: 27, endChar: item.text?.count ?? 0, percent: 60)
            ]
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.jumpToChapter(chapterId: "ch-1")

        XCTAssertEqual(audio.playedOffsets.last, "Overview. Short source summary.\n\n".count)
    }

    func testChapterJumpAlwaysStartsSelectedChapterPlayback() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "timeline": ["chapter_timing"],
                "playback": ["realtime_tts"]
            ]
        )
        let text = "First chapter starts here. Second chapter follows. Third chapter ends."
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: text, externalReference: nil, status: "ready")
        let map = ListeningMap(
            id: "map-pill",
            itemId: item.id,
            overview: "Short source summary.",
            chapters: [
                Chapter(id: "ch-1", title: "First", startChar: 0, endChar: 26, percent: 0),
                Chapter(id: "ch-2", title: "Second", startChar: 27, endChar: 51, percent: 45),
                Chapter(id: "ch-3", title: "Third", startChar: 52, endChar: text.count, percent: 80)
            ]
        )
        let prefixLength = "Overview. Short source summary.\n\n".count
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        _ = try engine.pause()
        let snapshot = try engine.jumpToChapter(chapterId: "ch-2")

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(audio.playedOffsets.last, prefixLength + 27)

        _ = try engine.jumpToChapter(chapterId: "ch-1")

        XCTAssertEqual(audio.playedOffsets.last, prefixLength)
    }

    func testListeningMapSummaryPrefaceProgressIsSummaryLocal() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: String(repeating: "Long source text. ", count: 20), externalReference: nil, status: "ready")
        let overview = "Short source summary."
        let map = ListeningMap(id: "map-pill", itemId: item.id, overview: overview, chapters: [
            Chapter(id: "ch-1", title: "First Chapter", startChar: 0, endChar: 50, percent: 0)
        ])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], mapsByItemId: [item.id: map])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.startSession(itemId: item.id)
        audio.currentOffset = "Overview. \(overview)\n\n".count / 2
        let snapshot = try engine.syncPlaybackProgress()

        XCTAssertEqual(snapshot.sourceProgressPercent, 0)
        XCTAssertGreaterThan(snapshot.currentPlaybackProgressPercent, 40)
        XCTAssertLessThan(snapshot.currentPlaybackProgressPercent, 60)
        XCTAssertEqual(snapshot.chapterTitle, "Summary")
    }

    func testGeneratedTurnPauseSavesOffsetForResume() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: "First response. Second point.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: turn.id)
        audio.currentOffset = "Brief intro.\n\nFirst".count
        _ = try engine.pause()
        _ = try engine.resumePlayback()

        XCTAssertEqual(audio.pauseCount, 1)
        XCTAssertEqual(audio.playedOffsets.last, "Brief intro.\n\nFirst".count)
    }

    func testAssistantInterjectionResumesNearRecordedTurnOffset() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let responseText = "First response. Second point has the detail. Third point closes."
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: responseText, rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: turn.id)
        audio.currentOffset = "Brief intro.\n\nFirst response. Second".count
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/ij-ai-001.m4a")

        let interjection = try XCTUnwrap(try repo.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(interjection.targetType, .assistantTurn)
        XCTAssertEqual(interjection.anchor.anchorBefore, "Second point has the detail.")
        XCTAssertEqual(audio.playedOffsets.last, "Brief intro.\n\nFirst response. ".count)
    }

    func testCancelAssistantInterjectionResumesNearRecordedTurnOffsetWithoutSavingInterjection() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["assistant_turn_tts"],
                "interjection": ["record_audio"]
            ]
        )
        let item = Item(id: "item-pill", title: "Pill", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        let session = Session(id: "session-pill", itemId: item.id, status: "in_progress", phase: .conversation, currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(), completionPercent: 100, playbackRate: 1)
        let responseText = "First response. Second point has the detail. Third point closes."
        let turn = ConversationTurn(id: "turn-response-001", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: "Brief intro.", text: responseText, rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.playTurn(turnId: turn.id)
        audio.currentOffset = "Brief intro.\n\nFirst response. Second".count
        _ = try engine.beginInterjection()
        let snapshot = try engine.cancelInterjection()

        XCTAssertEqual(snapshot.phase, .aiResponsePlayback)
        XCTAssertEqual(snapshot.targetType, TargetType.assistantTurnTTS.rawValue)
        XCTAssertEqual(try repo.loadInterjections(sessionId: session.id).count, 0)
        XCTAssertEqual(audio.playedOffsets.last, "Brief intro.\n\nFirst response. ".count)
    }

    func testPlaySourceFromBeginningWorksWithoutListeningMap() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let item = Item(id: "item-mapless", title: "Mapless", mediaType: "text", text: "First. Second.", externalReference: nil, status: "ready")
        let session = Session(id: "session-mapless", itemId: item.id, status: "in_progress", phase: .summaryPlayback, currentTargetType: .summaryTurnTTS, currentTargetId: "turn-summary-001", position: Position(charOffset: item.text?.count ?? 0), completionPercent: 100, playbackRate: 1)
        let turn = ConversationTurn(id: "turn-summary-001", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary.", rawText: nil, chapters: nil, sourceInterjectionIds: [])
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [turn.id: turn])
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)

        _ = try engine.inspectSession(sessionId: session.id)
        let snapshot = try engine.playSourceFromBeginning()

        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(snapshot.targetId, item.id)
        XCTAssertEqual(snapshot.sourceProgressPercent, 0)
        XCTAssertEqual(audio.playedTargets.last, item.id)
        XCTAssertEqual(audio.playedOffsets.last, 0)
    }

    func testBrowserTextImportCreatesURLBackedTextItem() throws {
        let profile = RuntimeCapabilityProfile(
            id: "browser-text",
            displayName: "Browser Text",
            capabilities: [
                "sync": ["browser_session_handoff"],
                "playback": ["realtime_tts"]
            ]
        )
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo)
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-selected",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/pill", title: "Browser Pill"),
            text: "Selected browser text."
        )

        let snapshot = try engine.importBrowserText(handoff)
        let item = try repo.loadItem(id: "item-browser-selected")

        XCTAssertEqual(snapshot.itemId, item.id)
        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(item.title, "Browser Pill")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.text, "Selected browser text.")
        XCTAssertEqual(item.externalReference, "https://example.com/pill")
        XCTAssertEqual(item.externalReferenceType, "url")
        XCTAssertEqual(item.status, "needs_listening_map")
    }

    func testBrowserTextImportCanStartSessionWhenRequested() throws {
        let profile = RuntimeCapabilityProfile(
            id: "browser-text",
            displayName: "Browser Text",
            capabilities: [
                "sync": ["browser_session_handoff"],
                "playback": ["realtime_tts"]
            ]
        )
        let audio = RecordingAudioClient()
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repo, audio: audio)
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-readable",
            captureMode: .readablePage,
            source: BrowserTextSource(url: "https://example.com/readable", title: "Readable Page"),
            text: "Readable page text.",
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "browser_or_app")
        )

        let snapshot = try engine.importBrowserText(handoff)

        XCTAssertEqual(snapshot.status, .playing)
        XCTAssertEqual(snapshot.phase, .itemPlayback)
        XCTAssertEqual(snapshot.itemId, "item-browser-readable")
        XCTAssertEqual(audio.playedTargets.last, "item-browser-readable")
    }

    func testBrowserTextImportRequiresSyncImportCapability() throws {
        let profile = RuntimeCapabilityProfile(
            id: "phone-tablet-online",
            displayName: "Phone/Tablet Online",
            capabilities: [
                "playback": ["realtime_tts"]
            ]
        )
        let engine = SessionEngine(profile: profile, repository: InMemorySessionRepository())
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-denied",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/denied", title: "Denied"),
            text: "Denied text."
        )

        XCTAssertThrowsError(try engine.importBrowserText(handoff)) { error in
            XCTAssertEqual(error as? SessionKitError, .invalidCommandForCapability("importBrowserText"))
        }
    }
}

private final class RecordingAudioClient: AudioPlaybackClient {
    var playedTargets: [String] = []
    var playedOffsets: [Int] = []
    var preparedTexts: [String] = []
    var pauseCount = 0
    var currentOffset: Int?
    var currentMediaTimeValue: Int?
    var currentDurationMs: Int?
    var activeTargetId: String?
    var completedTargetIds = Set<String>()
    var seekRequests: [Int] = []
    var playbackRates: [Double] = []
    var playbackRate = 1.0
    var mediaContexts: [PlaybackMediaContext?] = []
    var startStatus: PlaybackStartStatus = .confirmed

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        mediaContexts.append(context)
    }

    func prepareSpeechText(_ text: String) throws -> String {
        preparedTexts.append(text)
        return SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        activeTargetId = targetId
        playedTargets.append(targetId)
        playedOffsets.append(0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        activeTargetId = targetId
        currentMediaTimeValue = nil
        playedTargets.append(targetId)
        playedOffsets.append(charOffset)
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        currentOffset = nil
        currentMediaTimeValue = mediaTimeMs
        playedTargets.append(targetId)
        playedOffsets.append(mediaTimeMs)
    }

    func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        currentMediaTimeValue = mediaTimeMs
        seekRequests.append(mediaTimeMs)
    }

    func setPlaybackRate(_ rate: Double) throws {
        playbackRate = rate
        playbackRates.append(rate)
    }

    func pause() throws {
        pauseCount += 1
    }

    func currentCharOffset() -> Int? {
        currentOffset
    }

    func currentMediaTimeMs() -> Int? {
        currentMediaTimeValue
    }

    func currentPlaybackDurationMs() -> Int? {
        currentDurationMs
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        if let currentMediaTimeValue {
            return PlaybackPosition(
                targetId: activeTargetId,
                mediaTimeMs: currentMediaTimeValue,
                durationMs: currentDurationMs,
                playbackRate: playbackRate,
                anchorConfidence: .mediaTime
            )
        }
        if let currentOffset {
            return PlaybackPosition(
                targetId: activeTargetId,
                textStart: currentOffset,
                textEnd: currentOffset + 1,
                anchorConfidence: .textRange
            )
        }
        return nil
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        completedTargetIds.contains(targetId)
    }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        startStatus
    }
}

private final class RecordingTextAudioPreparationClient: TextAudioPreparationClient, @unchecked Sendable {
    var prepared: PreparedTextAudio?
    var requests: [(itemId: String, title: String, text: String)] = []

    init(prepared: PreparedTextAudio?) {
        self.prepared = prepared
    }

    func prepareTextAudio(itemId: String, title: String, text: String) throws -> PreparedTextAudio? {
        requests.append((itemId, title, text))
        return prepared
    }
}

private final class RecordingTranscriptionClient: TranscriptionClient {
    var scheduledInterjectionIds: [String] = []

    func scheduleTranscription(interjection: Interjection) throws {
        scheduledInterjectionIds.append(interjection.id)
    }
}

private struct StaticLinkResolutionClient: LinkResolutionClient {
    var result: LinkResolutionResult

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        result
    }
}
