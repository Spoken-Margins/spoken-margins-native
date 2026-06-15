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
