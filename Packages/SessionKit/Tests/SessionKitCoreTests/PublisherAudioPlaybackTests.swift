import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #547 (slice 3 of #239): an article with its publisher's recording and a text-to-time map plays the
/// recording, anchors Margins to the article's words through the map, and reads the text with on-device
/// speech from the same place when the recording can't play. The article stays a plain article in the
/// Library, so Build 29 opens it and resumes it as an article.
final class PublisherAudioPlaybackTests: XCTestCase {
    private let recordingURL = "https://publisher.example/post/voiceover.mp3"
    private let sentences = [
        "The harbour shelters fishing boats.",
        "Gulls circle the old pier at dawn.",
        "Night fog rolls in from the sea."
    ]

    private var text: String { sentences.joined(separator: " ") }

    private func article(media: ItemMedia? = nil, mediaType: String = "text") -> Item {
        Item(id: "item-post", title: "A harbour", mediaType: mediaType, text: text,
             externalReference: "https://example.com/harbour", status: "ready", media: media)
    }

    /// The voiceover opens with a 1 s intro; each sentence then takes 3 s with a 1 s pause after it.
    private func map() -> TranscriptTimeline {
        var segments: [MediaTimelineSegment] = []
        var cursor = 0
        for (index, sentence) in sentences.enumerated() {
            let startMs = 1_000 + index * 4_000
            segments.append(MediaTimelineSegment(
                id: "publisher-audio-\(index + 1)", startMs: startMs, endMs: startMs + 3_000,
                startChar: cursor, endChar: cursor + sentence.count, text: sentence))
            cursor += sentence.count + 1
        }
        return TranscriptTimeline(segments: segments, chapters: [], durationMs: 13_000)
    }

    private func record(map: TranscriptTimeline?, status: String? = "aligned(3 of 3 sentences)", url: String? = nil) -> PublisherAudio {
        PublisherAudio(itemId: "item-post", audioURL: url ?? recordingURL, durationMs: 13_000,
                       detectedFrom: "feed_enclosure", textMap: map, textMapStatus: status)
    }

    private func profile() -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(
            id: "phone", displayName: "Phone",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                "interjection": ["record_audio"]
            ]
        )
    }

    private func repository(map: TranscriptTimeline?, status: String? = "aligned(3 of 3 sentences)", item: Item? = nil) -> InMemorySessionRepository {
        let item = item ?? article()
        let repository = InMemorySessionRepository(items: [item.id: item])
        repository.publisherAudio[item.id] = record(map: map, status: status)
        return repository
    }

    // MARK: The rules

    func testOnlyAnArticleWithAUsableMapAndAddressPlaysItsRecording() {
        XCTAssertNotNil(PublisherAudioPlayback.plan(for: article(), record: record(map: map())))
        let plain = article()
        let cases: [(String, Item, PublisherAudio?)] = [
            ("no record", plain, nil),
            ("no map yet", plain, record(map: nil, status: nil)),
            ("map not kept", plain, record(map: nil, status: "no_match(1 of 3 sentences)")),
            ("empty map", plain, record(map: TranscriptTimeline(segments: [], chapters: [], durationMs: 0))),
            ("map without text places", plain, record(map: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "a", startMs: 0, endMs: 1_000, text: "x")], chapters: [], durationMs: 1_000))),
            ("a file address", plain, record(map: map(), url: "file:///private/var/voiceover.mp3")),
            ("no address", plain, record(map: map(), url: "not a url")),
            ("another scheme", plain, record(map: map(), url: "ftp://publisher.example/voiceover.mp3")),
            ("a record of another item", plain, { var other = record(map: map()); other.itemId = "item-other"; return other }()),
            ("an audiobook", article(mediaType: "audiobook"), record(map: map())),
            ("a podcast episode", article(mediaType: TargetType.transcriptBackedMedia.rawValue), record(map: map())),
            ("an imported recording", article(media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///a.m4a")), record(map: map())),
            ("a streamed episode", article(media: ItemMedia(sourceType: .remoteStream, url: "https://x.example/a.mp3")), record(map: map())),
            ("a browser-owned player", article(media: ItemMedia(sourceType: .browserOwnedMedia, url: "https://x.example/p")), record(map: map())),
            ("no text", { var empty = article(); empty.text = " \n"; return empty }(), record(map: map())),
            ("a deleted article", { var gone = article(); gone.deletedAt = Date(timeIntervalSince1970: 1); return gone }(), record(map: map()))
        ]
        for (name, item, record) in cases {
            XCTAssertNil(PublisherAudioPlayback.plan(for: item, record: record), name)
        }
        for media in [ItemMedia(sourceType: .generatedTTSRealtime), ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///tmp/n.caf")] {
            XCTAssertNotNil(PublisherAudioPlayback.plan(for: article(media: media), record: record(map: map())),
                            "generated narration gives way to the publisher's own recording: \(media.sourceType)")
        }
    }

    func testThePlayingCopyHasTheRecordingAndTheStoredCopyGetsItsOwnAudioBack() throws {
        let narration = ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///tmp/n.caf", nativeMediaId: "file:///tmp/n.caf")
        for original in [nil, narration] as [ItemMedia?] {
            let item = article(media: original)
            let plan = try XCTUnwrap(PublisherAudioPlayback.plan(for: item, record: record(map: map())))
            let playing = plan.playing(item)
            XCTAssertEqual(playing.media?.sourceType, .remoteStream)
            XCTAssertEqual(playing.media?.url, recordingURL)
            XCTAssertEqual(playing.media?.durationMs, 13_000)
            XCTAssertEqual(plan.playing(playing), playing, "playing twice changes nothing")
            XCTAssertEqual(plan.stored(playing), item, "what is saved is the article as it was")
            XCTAssertEqual(plan.stored(item), item, "an item that never had the recording is untouched")
        }
    }

    func testAStoredArticleSessionPlaysAtTheTimeTheMapGivesAndIsStoredBackAsTheArticle() throws {
        let plan = try XCTUnwrap(PublisherAudioPlayback.plan(for: article(), record: record(map: map())))
        let secondStart = sentences[0].count + 1
        let stored = Session(id: "s", itemId: "item-post", status: "in_progress", phase: .itemPlayback,
                             currentTargetType: .itemTextTTS, currentTargetId: "item-post",
                             position: Position(charOffset: secondStart + 10), completionPercent: 40, playbackRate: 1)
        let playing = try XCTUnwrap(plan.playingSession(from: stored))
        XCTAssertEqual(playing.currentTargetType, .transcriptBackedMedia)
        XCTAssertEqual(playing.currentTargetId, recordingURL)
        XCTAssertEqual(playing.position.mediaTimeMs, 5_000 + Int((3_000 * 10.0 / Double(sentences[1].count)).rounded()))
        let again = plan.stored(playing, item: article())
        XCTAssertEqual(again.currentTargetType, .itemTextTTS)
        XCTAssertEqual(again.currentTargetId, "item-post")
        XCTAssertNil(again.position.mediaTimeMs)
        assertClose(again.position.charOffset, secondStart + 10, within: 1)

        var summary = stored
        summary.currentTargetType = .summaryTurnTTS
        XCTAssertNil(plan.playingSession(from: summary), "an answer or summary isn't the article")
        var finished = stored
        finished.phase = .finished
        XCTAssertNil(plan.playingSession(from: finished), "a finished article starts again, as a new session")
        var pastTheEnd = stored
        pastTheEnd.position.charOffset = text.count
        XCTAssertNil(plan.playingSession(from: pastTheEnd), "a place the recording doesn't reach stays on-device speech")
        var elsewhere = playing
        elsewhere.currentTargetId = "https://other.example/a.mp3"
        XCTAssertEqual(plan.stored(elsewhere, item: article()), elsewhere, "another target is stored as it is")
    }

    // MARK: The engine

    func testStartingAnArticleWithAMapPlaysTheRecordingAndLeavesTheArticleAlone() throws {
        let repository = repository(map: map())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)

        let started = try engine.startSession(itemId: "item-post")

        XCTAssertEqual(started.status, .playing)
        XCTAssertEqual(started.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(started.targetId, recordingURL)
        XCTAssertEqual(audio.mediaPlays.map(\.targetId), [recordingURL])
        XCTAssertEqual(audio.mediaPlays.first?.timeMs, 0)
        XCTAssertTrue(audio.textPlays.isEmpty, "no on-device speech")
        XCTAssertEqual(started.sourceTranscriptStatus, "ready")

        XCTAssertNil(try repository.loadItem(id: "item-post").media, "the Library keeps a plain article")
        XCTAssertNil(try repository.loadTranscriptTimeline(itemId: "item-post"), "the map stays in the publisher_audio record")
        let sessionId = try XCTUnwrap(started.sessionId)
        let saved = try XCTUnwrap(try repository.loadSession(id: sessionId))
        XCTAssertEqual(saved.currentTargetType, .itemTextTTS, "stored as the article being read")
        XCTAssertEqual(saved.currentTargetId, "item-post")
        XCTAssertNil(saved.position.mediaTimeMs)
    }

    func testTheTextPlaceFollowsTheRecordingThroughTheMap() throws {
        let repository = repository(map: map())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")

        audio.mediaTimeMs = 6_500 // halfway through the second sentence
        let synced = try engine.syncPlaybackProgress()
        let secondStart = sentences[0].count + 1
        assertClose(synced.currentTextStart, secondStart + sentences[1].count / 2, within: 1)

        _ = try engine.pause()
        let saved = try XCTUnwrap(try repository.loadSession(id: try XCTUnwrap(engine.currentSession?.id)))
        XCTAssertEqual(saved.currentTargetType, .itemTextTTS)
        assertClose(saved.position.charOffset, secondStart + sentences[1].count / 2, within: 1)
        XCTAssertGreaterThan(saved.completionPercent, 30)
        XCTAssertNil(try repository.loadItem(id: "item-post").media)
    }

    func testAMarginRecordedDuringTheRecordingAnchorsToTheWordsTheMapGives() throws {
        let repository = repository(map: map())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")

        audio.mediaTimeMs = 6_500
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A note on the gulls")

        let sessionId = try XCTUnwrap(engine.currentSession?.id)
        let margin = try XCTUnwrap(try repository.loadInterjections(sessionId: sessionId).first)
        let expected = PreparedNarrationFallback.textOffset(mediaTimeMs: 6_500, timeline: map())
        XCTAssertEqual(margin.anchor.anchorType, .text, "an ordinary article anchor")
        XCTAssertEqual(margin.anchor.startChar, expected)
        XCTAssertNil(margin.anchor.mediaTimeMs, "nothing about the recording leaves in the anchor")
        XCTAssertNil(margin.anchor.transcriptSegmentId)
        let characters = Array(text)
        let opened = String(characters[margin.anchor.startChar..<min(margin.anchor.endChar, characters.count)])
        XCTAssertTrue(sentences[1].contains(opened.trimmingCharacters(in: .whitespaces)), "opens inside the second sentence: \(opened)")
        XCTAssertFalse(margin.anchor.anchorBefore.isEmpty && margin.anchor.anchorAfter.isEmpty, "has words around it")
        XCTAssertEqual(engine.snapshot.targetType, TargetType.transcriptBackedMedia.rawValue, "the recording carries on")
        XCTAssertNil(try repository.loadItem(id: "item-post").media)
    }

    func testAMarginOnTheRecordingOpensHearingTheRecordingAtThatPlace() throws {
        let repository = repository(map: map())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        audio.mediaTimeMs = 6_500
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A note on the gulls")
        let margin = try XCTUnwrap(try repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)
        audio.mediaPlays.removeAll()

        let played = try engine.playInterjectionAnchor(margin)

        XCTAssertEqual(played.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(audio.mediaPlays.last?.targetId, recordingURL)
        let time = try XCTUnwrap(audio.mediaPlays.last?.timeMs)
        assertClose(time, 6_500, within: 300, "the time the text place maps back to")
    }

    func testWithoutAMapTheArticleKeepsOnDeviceSpeech() throws {
        for (map, status) in [(nil, nil), (nil, "no_match(0 of 3 sentences)"), (nil, "waiting_for_speech_recognition")] as [(TranscriptTimeline?, String?)] {
            let repository = repository(map: map, status: status)
            let audio = FakePublisherAudioClient()
            let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
            let started = try engine.startSession(itemId: "item-post")
            XCTAssertEqual(started.targetType, TargetType.itemTextTTS.rawValue, status ?? "no status")
            XCTAssertTrue(audio.mediaPlays.isEmpty, status ?? "no status")
            XCTAssertEqual(audio.textPlays, ["item-post"], status ?? "no status")
        }
    }

    func testAnArticleWithoutAPublisherRecordPlaysAsBefore() throws {
        let repository = InMemorySessionRepository(items: ["item-post": article()])
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        let started = try engine.startSession(itemId: "item-post")
        XCTAssertEqual(started.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(audio.textPlays, ["item-post"])
    }

    /// #2508: the app's play-start check asks the engine, which holds the plan, instead of re-reading the record.
    func testTheEngineSaysWhetherTheStartingItemPlaysItsRecording() throws {
        let withMap = SessionEngine(profile: profile(), repository: repository(map: map()), audio: FakePublisherAudioClient())
        XCTAssertFalse(withMap.playsPublisherAudio(itemId: "item-post"), "nothing started yet")
        _ = try withMap.startSession(itemId: "item-post")
        XCTAssertTrue(withMap.playsPublisherAudio(itemId: "item-post"))
        XCTAssertFalse(withMap.playsPublisherAudio(itemId: "another-item"), "only the current session's item")

        let plain = SessionEngine(profile: profile(), repository: InMemorySessionRepository(items: ["item-post": article()]),
                                  audio: FakePublisherAudioClient())
        _ = try plain.startSession(itemId: "item-post")
        XCTAssertFalse(plain.playsPublisherAudio(itemId: "item-post"), "no record: on-device speech")

        let audio = FakePublisherAudioClient()
        audio.startStatusByTarget[recordingURL] = .failed("HTTP 404")
        let failing = SessionEngine(profile: profile(), repository: repository(map: map()), audio: audio)
        _ = try failing.startSession(itemId: "item-post")
        XCTAssertFalse(failing.playsPublisherAudio(itemId: "item-post"), "a recording that failed gave way to speech")
    }

    // MARK: When the recording can't play

    private func halfwayThroughThirdSentence() -> Session {
        let start = sentences[0].count + sentences[1].count + 2
        return Session(id: "session-saved", itemId: "item-post", status: "in_progress", phase: .itemPlayback,
                       currentTargetType: .itemTextTTS, currentTargetId: "item-post",
                       position: Position(charOffset: start + 12), completionPercent: 70, playbackRate: 1)
    }

    func testARecordingThatFailsToPlayIsReadAloudFromTheSamePlace() throws {
        for failure in ["HTTP 404", "The Internet connection appears to be offline.", "The operation could not be completed"] {
            let repository = repository(map: map())
            let saved = halfwayThroughThirdSentence()
            try repository.saveSession(saved)
            let audio = FakePublisherAudioClient()
            audio.startStatusByTarget[recordingURL] = .failed(failure)
            let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)

            _ = try engine.inspectSession(sessionId: saved.id)
            XCTAssertTrue(audio.mediaPlays.isEmpty && audio.textPlays.isEmpty, "inspecting plays nothing yet")
            let resumed = try engine.resumePlayback()

            XCTAssertEqual(audio.mediaPlays.map(\.targetId), [recordingURL], "the recording is tried first: \(failure)")
            XCTAssertEqual(resumed.status, .playing, failure)
            XCTAssertEqual(resumed.targetType, TargetType.itemTextTTS.rawValue, failure)
            XCTAssertEqual(audio.textPlays.last, "item-post", failure)
            assertClose(engine.currentSession?.position.charOffset, saved.position.charOffset, within: 2, failure)
            XCTAssertEqual(resumed.lastFailure, "publisher_audio_unavailable:\(failure)")
            let stored = try XCTUnwrap(try repository.loadSession(id: saved.id))
            XCTAssertEqual(stored.currentTargetType, .itemTextTTS)
            XCTAssertNil(try repository.loadItem(id: "item-post").media)
            XCTAssertNotNil(try repository.loadPublisherAudio(itemId: "item-post")?.textMap, "the record is kept for next time")
        }
    }

    func testARecordingThatNeverStartsGivesWayWithinTheStartTimeout() throws {
        let repository = repository(map: map())
        let saved = halfwayThroughThirdSentence()
        try repository.saveSession(saved)
        let audio = FakePublisherAudioClient()
        audio.startStatusByTarget[recordingURL] = .pending
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio,
                                   playbackStartTimeout: 10, now: { clock })

        _ = try engine.inspectSession(sessionId: saved.id)
        XCTAssertEqual(try engine.resumePlayback().status, .starting)
        clock = clock.addingTimeInterval(9)
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .starting, "still within the 10 s")
        clock = clock.addingTimeInterval(2)
        let after = try engine.syncPlaybackProgress()

        XCTAssertEqual(after.status, .playing, "never left in starting")
        XCTAssertEqual(after.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(after.lastFailure, "publisher_audio_unavailable:playback_start_timeout")
        assertClose(engine.currentSession?.position.charOffset, saved.position.charOffset, within: 2)
    }

    func testAStartThatFailsOpeningTheArticleReadsItFromTheMappedBeginning() throws {
        let repository = repository(map: map())
        let audio = FakePublisherAudioClient()
        audio.startStatusByTarget[recordingURL] = .failed("HTTP 404")
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)

        let started = try engine.startSession(itemId: "item-post")

        XCTAssertEqual(started.status, .playing)
        XCTAssertEqual(started.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(engine.currentSession?.position.charOffset, 0)
        XCTAssertEqual(audio.textPlays, ["item-post"])

        // The same failure isn't waited out again while the app stays open.
        audio.mediaPlays.removeAll()
        audio.textPlays.removeAll()
        let again = try engine.startSession(itemId: "item-post")
        XCTAssertEqual(again.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertTrue(audio.mediaPlays.isEmpty)
    }

    func testAFallbackLeavesAnArticleWithItsOwnNarrationPlayableAndUnchanged() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("narration-\(UUID().uuidString).caf")
        try Data("audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let narration = ItemMedia(sourceType: .generatedTTSPrerendered, url: file.absoluteString, nativeMediaId: file.absoluteString)
        let repository = repository(map: map(), item: article(media: narration))
        let audio = FakePublisherAudioClient()
        audio.startStatusByTarget[recordingURL] = .failed("HTTP 404")
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        XCTAssertEqual(try repository.loadItem(id: "item-post").media, narration, "a failed recording is not a reason to touch the narration")
    }

    // MARK: Chapters, places the map doesn't cover, and retries

    func testAChapterJumpFindsItsTimeInTheRecording() throws {
        let repository = repository(map: map())
        let second = sentences[0].count + 1
        let third = second + sentences[1].count + 1
        try repository.saveListeningMap(ListeningMap(id: "map", itemId: "item-post", overview: "", chapters: [
            Chapter(id: "c1", title: "Harbour", startChar: 0, endChar: second, percent: 0),
            Chapter(id: "c2", title: "Fog", startChar: third, endChar: text.count, percent: 66)
        ]))
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")

        let jumped = try engine.jumpToChapter(chapterId: "c2")

        XCTAssertEqual(jumped.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 9_000, "the start of the third sentence in the recording")
        XCTAssertEqual(engine.currentSession?.position.chapterId, "c2")
        XCTAssertNil(try repository.loadItem(id: "item-post").media)
    }

    /// The map keeps only 80% of the article, so its last sentence can be missing.
    private func mapWithoutTheLastSentence() -> TranscriptTimeline {
        let full = map()
        return TranscriptTimeline(segments: Array(full.segments.dropLast()), chapters: [], durationMs: full.durationMs)
    }

    func testAMarginInAPlaceTheRecordingDoesntReachIsHeardWithOnDeviceSpeech() throws {
        let repository = repository(map: mapWithoutTheLastSentence())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        let third = sentences[0].count + sentences[1].count + 2
        let margin = Interjection(
            id: "ij-001", itemId: "item-post", sessionId: try XCTUnwrap(engine.currentSession?.id), targetType: .item, targetId: "item-post",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 70,
            anchor: Anchor(anchorType: .text, startChar: third + 3, endChar: third + 8, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A note", status: "active")
        try repository.saveInterjection(margin)

        let played = try engine.playInterjectionAnchor(margin)

        XCTAssertEqual(played.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(engine.currentSession?.position.charOffset, third + 3)
    }

    func testASeekToAPlaceTheRecordingDoesntReachReadsOnWithOnDeviceSpeech() throws {
        let repository = repository(map: mapWithoutTheLastSentence())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        let third = sentences[0].count + sentences[1].count + 2

        let seeked = try engine.seekText(toCharOffset: third + 5)

        XCTAssertEqual(seeked.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(engine.currentSession?.position.charOffset, third + 5)
        XCTAssertEqual(audio.textPlays.last, "item-post")
        XCTAssertNil(try repository.loadItem(id: "item-post").media)
    }

    /// The map keeps 80% of the article, so a sentence in the middle can be missing. The recording still
    /// speaks it, between the end of the sentence before and the start of the sentence after.
    private func mapWithoutTheMiddleSentence() -> TranscriptTimeline {
        let full = map()
        return TranscriptTimeline(segments: [full.segments[0], full.segments[2]], chapters: [], durationMs: full.durationMs)
    }

    func testAMarginInAMissingMiddleSentenceHearsThatSentenceInTheRecording() throws {
        let repository = repository(map: mapWithoutTheMiddleSentence())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        let second = sentences[0].count + 1
        let margin = Interjection(
            id: "ij-001", itemId: "item-post", sessionId: try XCTUnwrap(engine.currentSession?.id), targetType: .item, targetId: "item-post",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: second + 5, endChar: second + 10, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A note", status: "active")
        try repository.saveInterjection(margin)

        let played = try engine.playInterjectionAnchor(margin)

        XCTAssertEqual(played.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 4_000,
                       "where the first sentence ends, not the third sentence's start (9 s)")
    }

    func testASeekIntoAMissingMiddleSentenceHearsThatSentenceInTheRecording() throws {
        let repository = repository(map: mapWithoutTheMiddleSentence())
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        let second = sentences[0].count + 1

        let seeked = try engine.seekText(toCharOffset: second + 5)

        XCTAssertEqual(seeked.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(engine.currentSession?.position.mediaTimeMs, 4_000)
    }

    func testAMissingMiddleSentenceResumesFromTheEndOfTheSentenceBefore() throws {
        let playback = try XCTUnwrap(PublisherAudioPlayback.plan(for: article(), record: record(map: mapWithoutTheMiddleSentence())))
        let second = sentences[0].count + 1

        XCTAssertEqual(playback.mediaTimeMs(textOffset: second + 5), 4_000)
        XCTAssertEqual(playback.mediaTimeMs(textOffset: second - 1), 4_000, "the space after the first sentence")
        XCTAssertEqual(playback.mediaTimeMs(textOffset: 0), 1_000)
        XCTAssertEqual(playback.mediaTimeMs(textOffset: sentences[0].count + sentences[1].count + 2), 9_000)
        XCTAssertNil(playback.mediaTimeMs(textOffset: text.count + 5), "past the last placed sentence")
    }

    func testAMarginHearsTheRecordingEvenWhenOldNarrationOfADifferentLengthIsStored() throws {
        let repository = repository(map: map())
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "old-narration", itemId: "item-post", createdAt: Date(timeIntervalSince1970: 1),
            timeline: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "n1", startMs: 0, endMs: 5_000, startChar: 0, endChar: text.count, text: text)
            ], chapters: [], durationMs: 5_000)))
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        audio.mediaTimeMs = 10_500
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "On the fog")
        let margin = try XCTUnwrap(try repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)

        let played = try engine.playInterjectionAnchor(margin)

        XCTAssertEqual(played.targetType, TargetType.transcriptBackedMedia.rawValue)
        assertClose(audio.mediaPlays.last?.timeMs, 10_500, within: 400)
    }

    func testAFailedRecordingIsTriedAgainLaterOrWhenTheRecordChanges() throws {
        let repository = repository(map: map())
        let audio = FakePublisherAudioClient()
        audio.startStatusByTarget[recordingURL] = .failed("offline")
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio, now: { clock })
        _ = try engine.startSession(itemId: "item-post")
        XCTAssertEqual(engine.snapshot.targetType, TargetType.itemTextTTS.rawValue)

        audio.startStatusByTarget[recordingURL] = nil // back online
        clock = clock.addingTimeInterval(60)
        XCTAssertEqual(try engine.startSession(itemId: "item-post").targetType, TargetType.itemTextTTS.rawValue, "not straight away")

        clock = clock.addingTimeInterval(11 * 60)
        XCTAssertEqual(try engine.startSession(itemId: "item-post").targetType, TargetType.transcriptBackedMedia.rawValue, "later")

        audio.startStatusByTarget[recordingURL] = .failed("offline")
        _ = try engine.startSession(itemId: "item-post")
        XCTAssertEqual(engine.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        audio.startStatusByTarget["https://publisher.example/post/new-voiceover.mp3"] = nil
        repository.publisherAudio["item-post"] = record(map: map(), url: "https://publisher.example/post/new-voiceover.mp3")
        XCTAssertEqual(try engine.startSession(itemId: "item-post").targetType, TargetType.transcriptBackedMedia.rawValue, "another recording")
    }

    // MARK: What is stored

    func testAFreshAppResumesTheStoredArticleOnTheRecordingAtTheSamePlace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path)
        try store.saveItem(article())
        try store.savePublisherAudio(record(map: map()))
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: store, audio: audio)
        _ = try engine.startSession(itemId: "item-post")
        audio.mediaTimeMs = 6_500
        let capture = try engine.beginWrittenInterjection()
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "On the gulls")
        audio.mediaTimeMs = 10_500 // in the third sentence
        _ = try engine.syncPlaybackProgress()
        _ = try engine.pause()
        let sessionId = try XCTUnwrap(engine.currentSession?.id)

        // What Build 29 would see: a plain article, its session reading the article, a Margin on its text.
        let reopened = try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path)
        let item = try reopened.loadItem(id: "item-post")
        XCTAssertNil(item.media)
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertNil(try reopened.loadTranscriptTimeline(itemId: "item-post"))
        let stored = try XCTUnwrap(try reopened.loadSession(id: sessionId))
        XCTAssertEqual(stored.currentTargetType, .itemTextTTS)
        XCTAssertEqual(stored.currentTargetId, "item-post")
        XCTAssertNil(stored.position.mediaTimeMs)
        XCTAssertGreaterThan(stored.position.charOffset, sentences[0].count + sentences[1].count + 2)
        let margin = try XCTUnwrap(try reopened.loadInterjections(sessionId: sessionId).first)
        XCTAssertEqual(margin.anchor.anchorType, .text)
        XCTAssertLessThanOrEqual(margin.anchor.endChar, text.count)
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: directory.appendingPathComponent("library.sqlite").path), 5)

        // The current build, opened fresh, carries on with the recording where it was left.
        let freshAudio = FakePublisherAudioClient()
        let fresh = SessionEngine(profile: profile(), repository: reopened, audio: freshAudio)
        let inspected = try fresh.inspectSession(sessionId: sessionId)
        XCTAssertEqual(inspected.targetType, TargetType.transcriptBackedMedia.rawValue)
        _ = try fresh.resumePlayback()
        XCTAssertEqual(freshAudio.mediaPlays.last?.targetId, recordingURL)
        assertClose(freshAudio.mediaPlays.last?.timeMs, 10_500, within: 400)
        XCTAssertTrue(freshAudio.textPlays.isEmpty)
        XCTAssertNil(try reopened.loadItem(id: "item-post").media)
    }

    func testAnArticleSessionStaysOnDeviceSpeechWhenItsRecordingHasNoMapYet() throws {
        let repository = repository(map: nil, status: nil)
        let saved = halfwayThroughThirdSentence()
        try repository.saveSession(saved)
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        let inspected = try engine.inspectSession(sessionId: saved.id)
        XCTAssertNotEqual(inspected.targetType, TargetType.transcriptBackedMedia.rawValue)
        _ = try engine.resumePlayback()
        XCTAssertTrue(audio.mediaPlays.isEmpty)
        XCTAssertEqual(audio.textPlays, ["item-post"])
    }

    // MARK: The map arrives while the article is read aloud (#2789)

    /// An article started before its recording's map was ready: on-device speech is reading, in the third sentence.
    private func readingAloud(map: TranscriptTimeline?) throws -> (SessionEngine, InMemorySessionRepository, FakePublisherAudioClient, Session) {
        let repository = repository(map: map, status: map == nil ? nil : "aligned(3 of 3 sentences)")
        let saved = halfwayThroughThirdSentence()
        try repository.saveSession(saved)
        let audio = FakePublisherAudioClient()
        let engine = SessionEngine(profile: profile(), repository: repository, audio: audio)
        _ = try engine.inspectSession(sessionId: saved.id)
        _ = try engine.resumePlayback()
        return (engine, repository, audio, saved)
    }

    func testAMapThatArrivesWhileTheArticleIsReadAloudHandsOverToTheRecordingAtTheSamePlace() throws {
        let (engine, repository, audio, saved) = try readingAloud(map: nil)
        XCTAssertEqual(audio.textPlays, ["item-post"])
        XCTAssertNil(try engine.adoptPublisherAudioIfReady(), "no map yet: nothing changes")
        XCTAssertTrue(audio.mediaPlays.isEmpty)

        repository.publisherAudio["item-post"] = record(map: map())
        let switched = try XCTUnwrap(try engine.adoptPublisherAudioIfReady())

        XCTAssertEqual(switched.status, .playing)
        XCTAssertEqual(switched.targetType, TargetType.transcriptBackedMedia.rawValue)
        XCTAssertEqual(audio.mediaPlays.map(\.targetId), [recordingURL])
        assertClose(audio.mediaPlays.last?.timeMs, 9_000 + 3_000 * (saved.position.charOffset - (sentences[0].count + sentences[1].count + 2)) / sentences[2].count, within: 1_500,
                    "the third sentence of the recording")
        XCTAssertGreaterThanOrEqual(audio.mediaPlays.last?.timeMs ?? 0, 9_000)
    }

    func testAfterTheHandOverTheArticleIsStillAnArticleInTheLibrary() throws {
        let (engine, repository, _, saved) = try readingAloud(map: nil)
        repository.publisherAudio["item-post"] = record(map: map())
        _ = try engine.adoptPublisherAudioIfReady()

        let item = try repository.loadItem(id: "item-post")
        XCTAssertNil(item.media, "the recording is never stored on the article")
        let stored = try XCTUnwrap(try repository.loadSession(id: saved.id))
        XCTAssertEqual(stored.currentTargetType, .itemTextTTS, "Build 29 resumes it as an article")
        XCTAssertEqual(stored.currentTargetId, "item-post")
        XCTAssertGreaterThanOrEqual(stored.position.charOffset, saved.position.charOffset - 2)
    }

    func testAnArticleAlreadyOnTheRecordingIsNotSwitchedAgain() throws {
        let (engine, repository, audio, _) = try readingAloud(map: nil)
        repository.publisherAudio["item-post"] = record(map: map())
        XCTAssertNotNil(try engine.adoptPublisherAudioIfReady())
        XCTAssertNil(try engine.adoptPublisherAudioIfReady())
        XCTAssertEqual(audio.mediaPlays.count, 1)
    }

    func testAPausedArticleIsNotSwitchedItResumesOnTheRecordingInstead() throws {
        let (engine, repository, audio, _) = try readingAloud(map: nil)
        _ = try engine.pause()
        repository.publisherAudio["item-post"] = record(map: map())

        XCTAssertNil(try engine.adoptPublisherAudioIfReady())
        XCTAssertTrue(audio.mediaPlays.isEmpty)
    }

    func testAMapThatDoesNotReachThePlaceKeepsOnDeviceSpeech() throws {
        let (engine, repository, audio, _) = try readingAloud(map: nil)
        let firstSentenceOnly = TranscriptTimeline(segments: Array(map().segments.prefix(1)), chapters: [], durationMs: 13_000)
        repository.publisherAudio["item-post"] = record(map: firstSentenceOnly)

        XCTAssertNil(try engine.adoptPublisherAudioIfReady())
        XCTAssertTrue(audio.mediaPlays.isEmpty)
        XCTAssertEqual(engine.snapshot.targetType, TargetType.itemTextTTS.rawValue)
    }

    func testARecordingThatCannotStartLeavesTheArticleReadingAloud() throws {
        struct NoPlayer: Error {}
        let (engine, repository, audio, saved) = try readingAloud(map: nil)
        audio.mediaPlayError = NoPlayer()
        repository.publisherAudio["item-post"] = record(map: map())

        XCTAssertThrowsError(try engine.adoptPublisherAudioIfReady())

        XCTAssertEqual(engine.snapshot.targetType, TargetType.itemTextTTS.rawValue)
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertEqual(audio.textPlays.last, "item-post", "reading aloud went on")
        assertClose(engine.currentSession?.position.charOffset, saved.position.charOffset, within: 2)
    }
}

private func assertClose(_ value: Int?, _ expected: Int, within tolerance: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let value else { return XCTFail("nil, expected \(expected) within \(tolerance). \(message)", file: file, line: line) }
    XCTAssertTrue(abs(value - expected) <= tolerance, "\(value) is not within \(tolerance) of \(expected). \(message)", file: file, line: line)
}

/// Records what the engine hands the player, and lets a test choose how each target's start goes.
private final class FakePublisherAudioClient: AudioPlaybackClient {
    var mediaTimeMs: Int?
    var mediaPlays: [(targetId: String, timeMs: Int)] = []
    var textPlays: [String] = []
    var startStatusByTarget: [String: PlaybackStartStatus] = [:]
    var mediaPlayError: Error?
    private var target: String?

    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws { target = targetId; textPlays.append(targetId) }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        if let mediaPlayError { throw mediaPlayError }
        target = targetId
        self.mediaTimeMs = mediaTimeMs
        mediaPlays.append((targetId, mediaTimeMs))
    }
    func pause() throws {}
    func stop() throws { target = nil }
    func currentCharOffset() -> Int? { nil }
    func currentRecoveryCharOffset() -> Int? { nil }
    func currentMediaTimeMs() -> Int? { target.flatMap { startStatusByTarget[$0] } == nil || mediaTimeMs != nil ? mediaTimeMs : nil }
    func currentPlaybackDurationMs() -> Int? { 13_000 }
    func currentPlaybackPosition() -> PlaybackPosition? {
        guard let mediaTimeMs, target?.hasPrefix("http") == true else { return nil }
        return PlaybackPosition(targetId: target, mediaTimeMs: mediaTimeMs, durationMs: 13_000, playbackRate: 1, anchorConfidence: .mediaTime)
    }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatusByTarget[targetId] ?? .confirmed }
    func isAwaitingRenderedAudio(targetId: String) -> Bool { false }
    func playbackTransportState(targetId: String) -> PlaybackTransportState? { nil }
    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {}
}
