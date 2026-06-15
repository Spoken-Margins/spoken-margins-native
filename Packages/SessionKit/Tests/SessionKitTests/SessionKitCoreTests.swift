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
        XCTAssertEqual(snapshot.availableCommands, snapshot.exposedCommands)
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

        let summary = try dispatcher.dispatch(.generateInterjectionSummary)
        XCTAssertTrue(summary.delegatedToCanonicalRuntime)
        XCTAssertEqual(summary.snapshot.pendingAiJobKind, "interjection_summary")
        XCTAssertEqual(summary.snapshot.pendingAiJobStatus, "pending")

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

        XCTAssertEqual(try store.loadItem(id: item.id), item)
        XCTAssertEqual(try store.loadSession(id: session.id), session)
        XCTAssertEqual(try store.loadInterjections(sessionId: session.id).first?.audioPath, "ij.m4a")
        XCTAssertEqual(try store.loadAIJobs(sessionId: session.id).first?.status, "retryable")
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
}

private final class RecordingAudioClient: AudioPlaybackClient {
    var playedTargets: [String] = []
    var playedOffsets: [Int] = []
    var preparedTexts: [String] = []
    var pauseCount = 0
    var currentOffset: Int?
    var completedTargetIds = Set<String>()

    func prepareSpeechText(_ text: String) throws -> String {
        preparedTexts.append(text)
        return SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        playedTargets.append(targetId)
        playedOffsets.append(0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        playedTargets.append(targetId)
        playedOffsets.append(charOffset)
    }

    func pause() throws {
        pauseCount += 1
    }

    func currentCharOffset() -> Int? {
        currentOffset
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        completedTargetIds.contains(targetId)
    }
}

private final class RecordingTranscriptionClient: TranscriptionClient {
    var scheduledInterjectionIds: [String] = []

    func scheduleTranscription(interjection: Interjection) throws {
        scheduledInterjectionIds.append(interjection.id)
    }
}
