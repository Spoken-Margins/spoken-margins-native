import Foundation
import XCTest
@testable import SessionKit

/// #776: after a saved Margin the source used to resume exactly where it paused, so the listener
/// landed mid-word. A podcast now steps back 3 seconds and an article goes back to the start of the
/// sentence that was playing. The Margin's own anchor, and the podcast anchor evidence built from
/// it, stay at the moment the Margin was made.
final class MarginRejoinTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private let episode = Item(
        id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 3_600_000)
    )

    private let text = "First sentence. Second sentence carries the thought on. Third sentence."
    private var secondSentenceStart: Int { "First sentence. ".count }

    private var article: Item {
        Item(id: "item-article", title: "Article", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    /// Reports the position it was last asked to play from, the way a real player does after a seek.
    private final class RejoinAudio: AudioPlaybackClient {
        var charOffset: Int?
        var mediaTimeMs: Int?
        var plays: [Int] = []
        var events: [String] = []
        var postResumeRequests: [PostResumeAudioSampleRequest] = []

        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
        func play(targetId: String, from charOffset: Int) throws {
            self.charOffset = charOffset
            plays.append(charOffset)
        }
        func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
            self.mediaTimeMs = mediaTimeMs
            plays.append(mediaTimeMs)
            events.append("play")
        }
        func currentPlaybackPosition() -> PlaybackPosition? {
            if let mediaTimeMs {
                return PlaybackPosition(mediaTimeMs: mediaTimeMs, durationMs: 3_600_000, anchorConfidence: .mediaTime)
            }
            if let charOffset {
                return PlaybackPosition(textStart: charOffset, textEnd: charOffset + 1, anchorConfidence: .textRange)
            }
            return nil
        }
        func currentCharOffset() -> Int? { charOffset }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func armPostResumeAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
            postResumeRequests.append(request)
            events.append("arm")
            return true
        }
        func pause() throws {}
    }

    private func engine(for item: Item) throws -> (SessionEngine, RejoinAudio, InMemorySessionRepository) {
        let audio = RejoinAudio()
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        return (engine, audio, repository)
    }

    private func savedSession(_ engine: SessionEngine, _ repository: InMemorySessionRepository) throws -> Session {
        try XCTUnwrap(repository.loadSession(id: try XCTUnwrap(engine.currentSession?.id)))
    }

    // MARK: Podcasts

    func testAPodcastMarginAt21m03sResumesAt21m00s() throws {
        let (engine, audio, repository) = try engine(for: episode)
        audio.mediaTimeMs = 1_263_000

        _ = try engine.beginInterjection()
        let resumed = try engine.finishInterjection(audioRef: "interjections/podcast.m4a")

        XCTAssertEqual(audio.plays.last, 1_260_000)
        XCTAssertEqual(resumed.currentMediaTimeMs, 1_260_000)
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 1_260_000)
        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)
        XCTAssertEqual(margin.anchor.mediaTimeMs, 1_263_000, "the Margin stays where it was made")
    }

    func testAPodcastMarginAt2sResumesAtTheStartNotBeforeIt() throws {
        let (engine, audio, repository) = try engine(for: episode)
        audio.mediaTimeMs = 2_000

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/early.m4a")

        XCTAssertEqual(audio.plays.last, 0)
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 0)
        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)
        XCTAssertEqual(margin.anchor.mediaTimeMs, 2_000)
    }

    /// Done when 2: the post-resume evidence window is labelled with the anchor's own media time,
    /// not the stepped-back resume position, and it is armed before playback restarts.
    func testPodcastAnchorEvidenceStillUsesTheAnchorTime() throws {
        let (engine, audio, _) = try engine(for: episode)
        audio.mediaTimeMs = 321_000
        _ = try engine.beginInterjection()
        audio.events.removeAll()

        _ = try engine.finishInterjection(audioRef: "interjections/evidence.m4a")

        let request = try XCTUnwrap(audio.postResumeRequests.first)
        XCTAssertEqual(request.anchorMediaTimeMs, 321_000)
        XCTAssertEqual(audio.plays.last, 318_000)
        XCTAssertEqual(audio.events, ["arm", "play"])
    }

    func testCancellingAPodcastMarginKeepsTheExactResume() throws {
        let (engine, audio, repository) = try engine(for: episode)
        audio.mediaTimeMs = 1_263_000

        _ = try engine.beginInterjection()
        _ = try engine.cancelInterjection()

        XCTAssertEqual(audio.plays.last, 1_263_000)
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 1_263_000)
    }

    func testAWrittenMarginWhilePlayingStepsBackToo() throws {
        let (engine, audio, repository) = try engine(for: episode)
        audio.mediaTimeMs = 600_000

        let capture = try engine.beginWrittenInterjection()
        XCTAssertTrue(capture.wasPlaying)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A written thought.")

        XCTAssertEqual(audio.plays.last, 597_000)
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 597_000)
        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: capture.sessionId).first)
        XCTAssertEqual(margin.anchor.mediaTimeMs, 600_000)
    }

    func testAWrittenMarginOnAPausedSourceLeavesItWhereItWas() throws {
        let (engine, audio, repository) = try engine(for: episode)
        audio.mediaTimeMs = 600_000
        _ = try engine.pause()
        let playsBefore = audio.plays.count

        let capture = try engine.beginWrittenInterjection()
        XCTAssertFalse(capture.wasPlaying)
        _ = try engine.saveWrittenInterjection(captureId: capture.id, text: "A written thought.")

        XCTAssertEqual(audio.plays.count, playsBefore, "a paused source stays paused")
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 600_000)
    }

    // MARK: Articles

    func testATextMarginResumesAtTheStartOfItsOwnSentence() throws {
        let (engine, audio, repository) = try engine(for: article)
        let pausedAt = "First sentence. Second sentence carries".count
        audio.charOffset = pausedAt

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/text.m4a")

        XCTAssertEqual(audio.plays.last, secondSentenceStart)
        let session = try savedSession(engine, repository)
        XCTAssertEqual(session.position.charOffset, secondSentenceStart)
        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(margin.anchor.startChar, pausedAt, "the Margin stays where it was made")
    }

    /// The drift the old exact-resume comment warned about: going back a sentence from a position
    /// that is already a sentence start would land in the sentence before.
    func testSeveralMarginsInOneSentenceNeverDriftIntoThePreviousSentence() throws {
        let (engine, audio, repository) = try engine(for: article)
        let pauses = [
            "First sentence. Second sentence".count,
            secondSentenceStart,
            "First sentence. Second sentence carries the".count,
            secondSentenceStart,
            secondSentenceStart
        ]

        for (index, pausedAt) in pauses.enumerated() {
            audio.charOffset = pausedAt
            _ = try engine.beginInterjection()
            _ = try engine.finishInterjection(audioRef: "interjections/drift-\(index).m4a")

            XCTAssertEqual(audio.plays.last, secondSentenceStart, "Margin \(index)")
            XCTAssertEqual(engine.currentSession?.position.charOffset, secondSentenceStart, "Margin \(index)")
        }
        let anchors = try repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id))
            .map(\.anchor.startChar)
        XCTAssertEqual(anchors, pauses)
    }

    // MARK: The rule itself

    func testTextResumeOffsetFindsTheSentenceStart() {
        let text = "One. Two? Three!\nFour\n\nFive words here."
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: 0, in: text), 0)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: 2, in: text), 0)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: "One. T".count, in: text), "One. ".count)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: "One. Two? Thr".count, in: text), "One. Two? ".count)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: "One. Two? Three!\nFo".count, in: text), "One. Two? Three!\n".count)
        let fiveStart = "One. Two? Three!\nFour\n\n".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: fiveStart + 6, in: text), fiveStart)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: fiveStart, in: text), fiveStart, "a sentence start stays put")
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: 10_000, in: "No end mark"), 0, "past the end clamps")
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: 3, in: ""), 0)
    }

    /// A "." inside a number or a word is not a sentence end: a Margin during "today" in "The value is 3.14
    /// today." used to resume at "14 today." and speak the wrong number (Codex audit on 34a1cae).
    func testAPointInsideANumberIsNotASentenceEnd() {
        let text = "Before. The value is 3.14 today. See example.com now."
        let valueStart = "Before. ".count
        let todayOffset = "Before. The value is 3.14 to".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: todayOffset, in: text), valueStart)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: valueStart, in: text), valueStart, "a sentence start stays put")
        let seeStart = "Before. The value is 3.14 today. ".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: text.count - 2, in: text), seeStart)
        let quoted = "He said \"stop.\" Then he left."
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: quoted.count - 3, in: quoted), "He said \"stop.\" ".count,
                       "a closing quote after the stop still ends the sentence")
    }

    /// Articles, EPUBs and transcripts carry typographic quotes, so the stop is often followed by a curly
    /// closing quote or a bracket before the space. The straight quote above is only one of the six
    /// closers; without the others a Margin during "Then he left" re-hears the sentence before it.
    func testEveryClosingQuoteAndBracketAfterTheStopStillEndsTheSentence() {
        let cases: [(text: String, second: String)] = [
            ("He said \u{201C}stop.\u{201D} Then he left.", "Then"),
            ("She said \u{2018}stop.\u{2019} Then she left.", "Then"),
            ("He said 'stop.' Then he left.", "Then"),
            ("It works (see note.) Next one.", "Next"),
            ("It works [see note.] Next one.", "Next"),
            ("(He said \u{201C}stop.\u{201D}) Then he left.", "Then"),
            ("He asked \u{201C}really?\u{201D} Then he left.", "Then"),
            ("He yelled \u{201C}stop!\u{201D} Then he left.", "Then"),
        ]
        for (text, second) in cases {
            let start = text.distance(from: text.startIndex, to: text.range(of: second)!.lowerBound)
            XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: start + 2, in: text), start, text)
            XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: start, in: text), start, "\(text) (a sentence start stays put)")
            XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: text.count - 1, in: text), start, "\(text) (a pause late in the sentence)")
        }
    }

    /// "!" and "?" end a sentence like ".", also when a space follows instead of a line break (the
    /// newline case above resumes at the break whatever the mark was).
    func testAnExclamationOrQuestionMarkFollowedByASpaceEndsTheSentence() {
        for text in ["Wow! Next one here.", "Why? Next one here."] {
            let start = text.distance(from: text.startIndex, to: text.range(of: "Next")!.lowerBound)
            XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: start + 2, in: text), start, text)
        }
        // No space after the mark: it is not a sentence end, as with the point in "3.14".
        let joined = "Wow!Next one here."
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: joined.count - 3, in: joined), 0)
    }

    /// A title or short form is not a sentence end: a Margin during "result" in "Intro. Dr. Smith explained
    /// the result." used to resume at "Smith" (Codex audit on dda759c).
    func testAnAbbreviationPeriodIsNotASentenceEnd() {
        let text = "Intro. Dr. Smith explained the result. Mr. Lee met Ms. Ray on St. James St. today, e.g. at noon."
        let drStart = "Intro. ".count
        let resultOffset = "Intro. Dr. Smith explained the res".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: resultOffset, in: text), drStart)
        var offset = resultOffset
        for _ in 0..<5 {
            offset = MarginRejoin.textResumeOffset(pausedAt: offset, in: text)
            XCTAssertEqual(offset, drStart, "repeated Margins stay at the sentence's start")
        }
        let mrStart = "Intro. Dr. Smith explained the result. ".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: text.count - 3, in: text), mrStart)
        let ended = "It was no. Then it was yes."
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: ended.count - 3, in: ended), "It was no. ".count,
                       "a word that only looks like a short form still ends the sentence")
    }

    /// A short form like "Jr." can end a sentence: a Margin during "Then we left." in "I met Bob Jr. Then
    /// we left." used to resume at "I met" (Codex audit on 46c2417).
    func testAShortFormBeforeACapitalEndsTheSentence() {
        let text = "I met Bob Jr. Then we left. See e.g. the map, vs. the list."
        let thenStart = "I met Bob Jr. ".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: thenStart + 6, in: text), thenStart)
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: thenStart, in: text), thenStart, "a sentence start stays put")
        let seeStart = "I met Bob Jr. Then we left. ".count
        XCTAssertEqual(MarginRejoin.textResumeOffset(pausedAt: text.count - 3, in: text), seeStart,
                       "a short form before a lowercase word goes on with the sentence")
    }

    func testMediaResumeTimeStepsBackThreeSecondsAndNeverBeforeZero() {
        XCTAssertEqual(MarginRejoin.mediaStepBackMs, 3_000)
        XCTAssertEqual(MarginRejoin.mediaResumeTimeMs(pausedAtMs: 1_263_000), 1_260_000)
        XCTAssertEqual(MarginRejoin.mediaResumeTimeMs(pausedAtMs: 3_000), 0)
        XCTAssertEqual(MarginRejoin.mediaResumeTimeMs(pausedAtMs: 2_000), 0)
        XCTAssertEqual(MarginRejoin.mediaResumeTimeMs(pausedAtMs: 0), 0)
    }

    // MARK: Articles played as prepared audio (#806)

    private func preparedArticle(file: URL) -> Item {
        Item(
            id: "item-prepared-article", title: "Prepared Article", mediaType: "text", text: text,
            externalReference: nil, status: "ready",
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered, url: file.absoluteString,
                durationMs: 7_100, nativeMediaId: file.absoluteString
            ),
            transcriptId: "generated-transcript-item-prepared-article"
        )
    }

    /// One chunk reading the whole text at 100 ms a character, so the second sentence starts at 1.6 s.
    private func oneChunkTimeline() -> TranscriptTimeline {
        TranscriptTimeline(
            segments: [MediaTimelineSegment(
                id: "seg-1", startMs: 0, endMs: text.count * 100, startChar: 0, endChar: text.count, text: text
            )],
            chapters: [],
            durationMs: text.count * 100
        )
    }

    /// Chunks that carry no text positions, the way a timeline with no map reads.
    private func unmappedTimeline() -> TranscriptTimeline {
        TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 3_000, text: "First sentence."),
                MediaTimelineSegment(id: "seg-2", startMs: 3_000, endMs: 6_000, text: "Second sentence."),
            ],
            chapters: [],
            durationMs: 6_000
        )
    }

    private let preparedProfile = RuntimeCapabilityProfile(
        id: "phone-tablet-online",
        displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["prerendered_audio", "native_media"],
            "timeline": ["transcript_segments", "media_time", "chapter_timing"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private func preparedEngine(timeline: TranscriptTimeline) throws -> (SessionEngine, RejoinAudio, InMemorySessionRepository, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rejoin-\(UUID().uuidString).caf")
        try Data().write(to: file)
        let item = preparedArticle(file: file)
        let repository = InMemorySessionRepository(items: [item.id: item])
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "generated-transcript-item-prepared-article", itemId: item.id, createdAt: Date(), timeline: timeline
        ))
        let audio = RejoinAudio()
        let engine = SessionEngine(profile: preparedProfile, repository: repository, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        XCTAssertEqual(engine.currentSession?.currentTargetType, .transcriptBackedMedia, "plays the prepared file")
        return (engine, audio, repository, file)
    }

    func testAPreparedArticleMarginResumesAtTheStartOfItsSentence() throws {
        let (engine, audio, repository, file) = try preparedEngine(timeline: oneChunkTimeline())
        defer { try? FileManager.default.removeItem(at: file) }
        audio.mediaTimeMs = 3_900  // "First sentence. Second sentence carries" is 39 characters in

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/prepared.m4a")

        XCTAssertEqual(audio.plays.last, 1_600, "the second sentence's start, not 3 s back (2_900)")
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 1_600)
        let margin = try XCTUnwrap(repository.loadInterjections(sessionId: try XCTUnwrap(engine.currentSession?.id)).first)
        XCTAssertEqual(margin.anchor.mediaTimeMs, 3_900, "the Margin stays where it was made")
        XCTAssertEqual(try engine.diagnostics()["lastMarginRejoin"], "sentence_start")
    }

    func testAPreparedArticleMarginOnASentenceStartStaysPut() throws {
        let (engine, audio, repository, file) = try preparedEngine(timeline: oneChunkTimeline())
        defer { try? FileManager.default.removeItem(at: file) }
        audio.mediaTimeMs = 1_600

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/start.m4a")

        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 1_600)
    }

    func testSeveralPreparedArticleMarginsInOneSentenceNeverDriftBack() throws {
        let (engine, audio, repository, file) = try preparedEngine(timeline: oneChunkTimeline())
        defer { try? FileManager.default.removeItem(at: file) }

        for (index, pausedAt) in [3_100, 1_600, 4_800, 1_600, 1_600].enumerated() {
            audio.mediaTimeMs = pausedAt
            _ = try engine.beginInterjection()
            _ = try engine.finishInterjection(audioRef: "interjections/prepared-drift-\(index).m4a")
            XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 1_600, "Margin \(index + 1)")
        }
    }

    func testAPreparedArticleMarginWithoutATextMapResumesAtTheChunkStartNotThreeSecondsBack() throws {
        let (engine, audio, repository, file) = try preparedEngine(timeline: unmappedTimeline())
        defer { try? FileManager.default.removeItem(at: file) }
        audio.mediaTimeMs = 4_500

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/chunk.m4a")

        XCTAssertEqual(audio.plays.last, 3_000)
        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 3_000)
        XCTAssertEqual(try engine.diagnostics()["lastMarginRejoin"], "chunk_start")
    }

    func testPreparedNarrationResumeNeighbouringPauses() {
        let timeline = oneChunkTimeline()
        func resume(_ ms: Int) -> Int { MarginRejoin.preparedNarrationResume(pausedAtMs: ms, text: text, timeline: timeline).timeMs }
        XCTAssertEqual(resume(0), 0)
        XCTAssertEqual(resume(900), 0, "inside the first sentence")
        XCTAssertEqual(resume(1_400), 0, "just before the second sentence")
        XCTAssertEqual(resume(1_500), 1_500, "within the look-ahead of the second sentence's start: stays put, never after the pause")
        XCTAssertEqual(resume(1_600), 1_600)
        XCTAssertEqual(resume(1_650), 1_600)
        let thirdStart = "First sentence. Second sentence carries the thought on. ".count * 100
        XCTAssertEqual(resume(7_050), thirdStart, "the last 100 ms of the last sentence")
        XCTAssertEqual(resume(7_100), thirdStart, "at the very end")
        XCTAssertEqual(resume(90_000), thirdStart, "past the end clamps")
        XCTAssertEqual(MarginRejoin.preparedNarrationResume(pausedAtMs: 500, text: "", timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: nil)).outcome, .unmapped)
    }

    /// Done when 1: recorded audio keeps the 3 s step back. Publisher audio lined up with an article
    /// (#546) is recorded audio until it has a text-to-time map.
    func testPublisherAudioForAnArticleStillStepsBackThreeSeconds() throws {
        var lined = episode
        lined.text = text
        let (engine, audio, repository) = try engine(for: lined)
        audio.mediaTimeMs = 40_000

        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: "interjections/publisher.m4a")

        XCTAssertEqual(try savedSession(engine, repository).position.mediaTimeMs, 37_000)
        XCTAssertEqual(try engine.diagnostics()["lastMarginRejoin"], "media_step_back")
    }

    /// Chunks like the real assembler writes them: sentences grouped, each chunk with its own text range.
    private func threeChunkTimeline() -> TranscriptTimeline {
        TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "seg-1", startMs: 0, endMs: 2_000, startChar: 0, endChar: 15, text: "First sentence."),
                MediaTimelineSegment(id: "seg-2", startMs: 2_000, endMs: 6_000, startChar: 16, endChar: 55,
                                     text: "Second sentence carries the thought on."),
                MediaTimelineSegment(id: "seg-3", startMs: 6_000, endMs: 8_000, startChar: 56, endChar: 71, text: "Third sentence."),
            ],
            chapters: [],
            durationMs: 8_000
        )
    }

    func testAPreparedArticleWithSeveralChunksResumesAtTheChunkThatStartsTheSentence() {
        let timeline = threeChunkTimeline()
        func resume(_ ms: Int) -> (Int, MarginRejoin.PreparedNarrationOutcome) {
            let result = MarginRejoin.preparedNarrationResume(pausedAtMs: ms, text: text, timeline: timeline)
            return (result.timeMs, result.outcome)
        }
        XCTAssertEqual(resume(1_000).0, 0)
        XCTAssertEqual(resume(4_500).0, 2_000)
        XCTAssertEqual(resume(2_000).0, 2_000, "a sentence start stays put")
        XCTAssertEqual(resume(7_000).0, 6_000)
        XCTAssertEqual(resume(7_000).1, .sentenceStart)
    }

    /// A pause inside a chunk with no text positions must not read as text offset 0 (the top of the article).
    func testAChunkWithoutTextPositionsResumesAtItsOwnStartNotAtTheTopOfTheArticle() {
        var timeline = threeChunkTimeline()
        timeline.segments[1].startChar = nil
        timeline.segments[1].endChar = nil
        let result = MarginRejoin.preparedNarrationResume(pausedAtMs: 4_500, text: text, timeline: timeline)
        XCTAssertEqual(result.timeMs, 2_000)
        XCTAssertEqual(result.outcome, .chunkStart)
    }
}
