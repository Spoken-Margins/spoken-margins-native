import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #3392: when a friend's episode can't play, the voice reads each Margin's quote (or its place), then the Margin.
final class CantPlayListeningTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_700_000_000)

    private func layer(_ id: String, label: String? = "Cole") -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "d-\(id)", packageId: "p-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 7_200_000),
            displayLabel: label, importedAt: created, sourceResolutionStatus: .resolved
        )
    }

    private func entry(
        _ id: String, layerId: String = "cole", label: String? = "Cole", at ms: Int = 720_000,
        exact: String? = nil, prefix: String? = nil, voice: Bool = true, words: String = "A thought"
    ) -> SharedMarginReview.Entry {
        let margin = ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: id, createdAt: created,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, exactText: exact, prefix: prefix, mediaTimeMs: ms),
            approvedTranscript: words,
            audioPath: voice ? "ImportedCommentary/\(id).m4a" : nil, audioDurationMs: voice ? 4_000 : nil,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 1)
        )
        return SharedMarginReview.Entry(layer: layer(layerId, label: label), interjection: margin, mediaTimeMs: ms, isApproximate: false)
    }

    private func plan(_ entries: [SharedMarginReview.Entry], title: String? = "Big Show", voiceFor: (String) -> String? = { $0 }) -> [CantPlayListening.Beat] {
        CantPlayListening.plan(entries: entries, episodeTitle: title, voiceFor: voiceFor)
    }

    // MARK: Order

    func testEachMarginIsPrecededByItsWordsAndTheOrderOfTheEntriesIsKept() {
        let beats = plan([entry("a", at: 60_000, prefix: "First quote."), entry("b", at: 120_000, prefix: "Second quote.")])
        let anchors = CantPlayListening.anchors(for: beats, placeMs: 5_000)
        XCTAssertEqual(anchors.map(\.marginId), ["cant-play::shared::cole::a", "shared::cole::a", "cant-play::shared::cole::b", "shared::cole::b"])
        XCTAssertTrue(anchors.allSatisfy { $0.mediaTimeMs == 5_000 }, "one place: the machine plays the next at once and never seeks")
    }

    func testTheWordsNeverShareAMarginsIdSoTheyAreNeverMarkedHeard() {
        let beat = plan([entry("a", prefix: "Words.")])[0]
        XCTAssertNotEqual(beat.contextId, beat.marginId)
        XCTAssertTrue(CantPlayListening.isContextId(beat.contextId))
        XCTAssertFalse(CantPlayListening.isContextId(beat.marginId))
    }

    func testTheCardCountsMarginsNotWordsAndKnowsTheWordsStep() throws {
        let beats = plan([entry("a", prefix: "One."), entry("b", prefix: "Two.")])
        var sequence = try XCTUnwrap(CantPlayListening.sequence(for: beats, itemId: "item", placeMs: 0))
        XCTAssertTrue(CantPlayListening.isCantPlayListening(sequence))
        _ = sequence.jumpToTarget()
        XCTAssertTrue(CantPlayListening.isWordsStep(sequence))
        XCTAssertEqual(CantPlayListening.position(in: sequence), "1 of 2")
        sequence.marginFinished()
        XCTAssertFalse(CantPlayListening.isWordsStep(sequence), "the Margin itself")
        XCTAssertEqual(CantPlayListening.position(in: sequence), "1 of 2")
        sequence.marginFinished()
        XCTAssertEqual(CantPlayListening.position(in: sequence), "2 of 2")
        let ordinary = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: CantPlayListening.anchors(for: beats, placeMs: 0)))
        XCTAssertFalse(CantPlayListening.isCantPlayListening(ordinary), "an ordinary review keeps its 20 second lead-in")
        XCTAssertNil(CantPlayListening.position(in: ordinary))
    }

    /// #3597: one Margin is never "1 of 1", in a can't-play listening or an ordinary review, and the can't-play count
    /// never falls back to counting the words steps ("1 of 2" for one Margin).
    func testOneMarginIsNeverCountedOnTheCard() throws {
        let one = plan([entry("a", prefix: "One.")])
        var cantPlay = try XCTUnwrap(CantPlayListening.sequence(for: one, itemId: "item", placeMs: 0))
        _ = cantPlay.jumpToTarget()
        XCTAssertNil(CantPlayListening.cardPosition(in: cantPlay))
        cantPlay.marginFinished()
        XCTAssertNil(CantPlayListening.cardPosition(in: cantPlay))
        let two = plan([entry("a", prefix: "One."), entry("b", prefix: "Two.")])
        var many = try XCTUnwrap(CantPlayListening.sequence(for: two, itemId: "item", placeMs: 0))
        _ = many.jumpToTarget()
        XCTAssertEqual(CantPlayListening.cardPosition(in: many), "1 of 2")
        let anchors = [MarginMomentAnchor(marginId: "m1", mediaTimeMs: 60_000)]
        let review = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: anchors))
        XCTAssertNil(CantPlayListening.cardPosition(in: review), "an ordinary review of one Margin")
        let reviewOfTwo = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: anchors + [MarginMomentAnchor(marginId: "m2", mediaTimeMs: 90_000)]))
        XCTAssertEqual(CantPlayListening.cardPosition(in: reviewOfTwo), "1 of 2")
    }

    func testTheMachinePlaysWordsThenMarginThenNextWordsWithoutAHop() throws {
        let beats = plan([entry("a", at: 60_000, prefix: "One."), entry("b", at: 900_000, prefix: "Two.")])
        let anchors = CantPlayListening.anchors(for: beats, placeMs: 0)
        var sequence = try XCTUnwrap(CantPlayListening.sequence(for: beats, itemId: "item", placeMs: 0))
        var played = [try XCTUnwrap(sequence.jumpToTarget()).marginId]
        for _ in 0..<3 {
            guard case .playNow(let next) = sequence.marginFinished() else { return XCTFail("expected the next to play at once, never a seek") }
            played.append(next.marginId)
        }
        XCTAssertEqual(played, anchors.map(\.marginId))
        XCTAssertEqual(sequence.marginFinished(), .reviewDone(returnToMediaTimeMs: nil, resumes: false))
    }

    /// The conductor with a recording source: no episode to move through, so it never seeks, and a missing file (words
    /// not rendered, a recording gone) is passed over to the next step rather than left as silence.
    @MainActor
    func testTheConductorPlaysTheWordsThenTheMarginAtOnePlaceAndNeverSeeksTheDeadSource() throws {
        let beats = plan([entry("a", at: 60_000, prefix: "One."), entry("b", at: 900_000, prefix: "Two.")])
        var seeks: [Int] = []
        var resumes = 0
        let conductor = MarginMomentConductor(
            sequence: try XCTUnwrap(CantPlayListening.sequence(for: beats, itemId: "item", placeMs: 0)),
            source: .init(pause: {}, resume: { resumes += 1 }, seek: { seeks.append($0) }),
            voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/voice.m4a") }
        )
        var asked: [String] = []
        conductor.onVoiceUnavailable = { id, _ in asked.append(id) }
        conductor.start() // the app's start: no player to seek (the failed player throws and the app shows a banner)
        conductor.playTargetNow()
        XCTAssertEqual(asked, CantPlayListening.anchors(for: beats, placeMs: 0).map(\.marginId), "words, Margin, words, Margin: in that order, none skipped")
        XCTAssertEqual(seeks, [], "there is no episode to seek")
        XCTAssertTrue(CantPlayListening.isCantPlayListening(conductor.sequence))
    }

    #if os(macOS)
    /// The conductor tests that name `/nonexistent/voice.m4a` only ever take the
    /// "voice unavailable" branch. The two tests below use a real file for every beat, so the real `AVAudioPlayer`
    /// path runs for a can't-play sequence (#3712). The voice is muted; the source closures record any touch.
    @MainActor
    private struct RealVoices {
        let directory: URL
        let urls: [String: URL]

        init(beats: [CantPlayListening.Beat]) throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "cant-play-voices-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var urls: [String: URL] = [:]
            for (index, id) in CantPlayListening.anchors(for: beats, placeMs: 0).map(\.marginId).enumerated() {
                urls[id] = try RealPlayerMarginMomentTests.writeTone(
                    to: directory.appending(path: "voice-\(index).caf"), seconds: 0.3, hz: 440
                )
            }
            self.urls = urls
        }
    }

    @MainActor
    private final class RealListening {
        private final class Log {
            var started: [String] = []
            var unavailable: [String] = []
            var touched: [String] = []
        }

        private let log = Log()
        let conductor: MarginMomentConductor
        var startedIDs: [String] { log.started }
        var unavailableVoices: [String] { log.unavailable }
        var sourceTouches: [String] { log.touched }

        init(beats: [CantPlayListening.Beat], voices: RealVoices) throws {
            let log = self.log
            conductor = MarginMomentConductor(
                sequence: try XCTUnwrap(CantPlayListening.sequence(for: beats, itemId: "item", placeMs: 5_000)),
                source: .init(
                    pause: { log.touched.append("pause") },
                    resume: { log.touched.append("resume") },
                    seek: { log.touched.append("seek \($0)") }
                ),
                voiceURL: { voices.urls[$0] }
            )
            conductor.voiceVolume = 0
            conductor.onVoiceStarted = { log.started.append($0) }
            conductor.onVoiceUnavailable = { id, reason in log.unavailable.append("\(id):\(reason)") }
        }

        func pump(until condition: () -> Bool, _ what: String, timeout: TimeInterval = 10) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
    }

    /// Every beat's real voice starts, in order, and plays to its end. The words never share a Margin's id, so the
    /// app's heard-marking (it looks the started id up among the Margins) marks the Margins and never the words.
    @MainActor
    func testARealVoicePlaysEachWordsAndMarginInOrderAndOnlyTheMarginsAreMarkedHeard() throws {
        let beats = plan([entry("a", prefix: "One."), entry("b", prefix: "Two.")])
        let voices = try RealVoices(beats: beats)
        defer { try? FileManager.default.removeItem(at: voices.directory) }
        let listening = try RealListening(beats: beats, voices: voices)
        defer { listening.conductor.cancel() }
        let conductor = listening.conductor
        let everyVoice = CantPlayListening.anchors(for: beats, placeMs: 0).map(\.marginId)

        conductor.start()
        conductor.playTargetNow()
        XCTAssertTrue(conductor.isPlayingVoice, "the words' real recording is sounding")
        listening.pump(until: { listening.startedIDs.count == everyVoice.count }, "all four voices have started")
        XCTAssertEqual(listening.startedIDs, everyVoice, "words, Margin, words, Margin, each started by the real player")
        XCTAssertEqual(listening.unavailableVoices, [])

        let marginIds = Set(beats.map(\.marginId))
        XCTAssertEqual(listening.startedIDs.filter(marginIds.contains), beats.map(\.marginId), "the Margins the app marks heard")
        XCTAssertTrue(listening.startedIDs.filter { !marginIds.contains($0) }.allSatisfy(CantPlayListening.isContextId),
                      "everything else that sounded is words")

        // The last voice plays out by itself; the sequence then ends without ever resuming the dead episode.
        listening.pump(until: { !conductor.isPlayingVoice }, "the last voice has ended")
        XCTAssertEqual(listening.sourceTouches, [], "no seek, pause or resume reached the episode")
    }

    /// Skipping each real voice moves on to the next at once, and the last skip ends the listening, never touching the episode.
    @MainActor
    func testSkippingEachRealVoiceMovesOnAndNeverTouchesTheEpisode() throws {
        let beats = plan([entry("a", prefix: "One."), entry("b", prefix: "Two.")])
        let voices = try RealVoices(beats: beats)
        defer { try? FileManager.default.removeItem(at: voices.directory) }
        let listening = try RealListening(beats: beats, voices: voices)
        defer { listening.conductor.cancel() }
        let conductor = listening.conductor
        let everyVoice = CantPlayListening.anchors(for: beats, placeMs: 0).map(\.marginId)

        conductor.start()
        conductor.playTargetNow()
        for step in everyVoice.indices {
            XCTAssertTrue(conductor.isPlayingVoice, "voice \(step + 1) is sounding")
            XCTAssertEqual(listening.startedIDs.last, everyVoice[step])
            conductor.skipVoice()
        }
        XCTAssertFalse(conductor.isPlayingVoice, "the last skip ends the listening")
        XCTAssertEqual(listening.startedIDs, everyVoice)
        XCTAssertEqual(listening.unavailableVoices, [])
        XCTAssertEqual(listening.sourceTouches, [], "skipping never resumes, pauses or seeks the dead episode")
    }
    #endif

    func testSeveralFriendsKeepTheOrderTheyArePlacedIn() {
        let beats = plan([
            entry("x", layerId: "ana", label: "Ana", at: 60_000, prefix: "Early."),
            entry("y", layerId: "cole", label: "Cole", at: 60_000, prefix: "Early."),
            entry("z", layerId: "ana", label: "Ana", at: 300_000, prefix: "Late.")
        ])
        XCTAssertEqual(beats.map(\.marginId), ["shared::ana::x", "shared::cole::y", "shared::ana::z"])
        XCTAssertEqual(CantPlayListening.anchors(for: beats, placeMs: 0).compactMap(\.label), ["Ana", "Ana", "Cole", "Cole", "Ana", "Ana"])
    }

    func testAWrittenMarginFollowsItsQuoteAndIsMarkedReadAloud() {
        let beat = plan([entry("w", prefix: "Words before.", voice: false, words: "I disagree here")])[0]
        let anchors = CantPlayListening.anchors(for: [beat], placeMs: 0)
        XCTAssertEqual(beat.context, .quote("Words before."))
        XCTAssertFalse(anchors[0].isReadAloud)
        XCTAssertTrue(anchors[1].isReadAloud)
    }

    func testAMarginWithNeitherAudioNorReadableTextIsLeftOutWithItsWords() {
        let none = entry("n", prefix: "Words.", voice: false, words: "   ")
        let emojiOnly = entry("e", prefix: "Words.", voice: false, words: "👍🔥")
        let ok = entry("ok", prefix: "Words.")
        XCTAssertEqual(plan([none, emojiOnly, ok]).map(\.marginId), ["shared::cole::ok"])
        XCTAssertTrue(plan([none]).isEmpty)
    }

    // MARK: The words, a table of neighbouring inputs

    func testWhichWordsAreReadBeforeAMargin() {
        struct Row { let name: String; let exact: String?; let prefix: String?; let expected: CantPlayListening.Context }
        let place = CantPlayListening.Context.place(timeWords: "At 12 minutes", title: "Big Show")
        let rows = [
            Row(name: "no quote", exact: nil, prefix: nil, expected: place),
            Row(name: "empty quote", exact: "", prefix: "", expected: place),
            Row(name: "whitespace only", exact: "  \n\t ", prefix: "   ", expected: place),
            Row(name: "emoji only", exact: "🎉🎉", prefix: "👏", expected: place),
            Row(name: "link only", exact: "https://example.com/a?b=c", prefix: "www.example.com", expected: place),
            Row(name: "punctuation only", exact: "…!?", prefix: "—", expected: place),
            Row(name: "plain quote", exact: nil, prefix: "We went to the market.", expected: .quote("We went to the market.")),
            Row(name: "article quote beats the words before", exact: "The quoted sentence.", prefix: "Before it.", expected: .quote("The quoted sentence.")),
            Row(name: "unreadable quote falls to the words before", exact: "😀", prefix: "Before it.", expected: .quote("Before it.")),
            Row(name: "links and emoji are removed, words kept", exact: nil, prefix: "See https://x.io now 🎉 please", expected: .quote("See now please")),
            Row(name: "whitespace collapses", exact: nil, prefix: "  two   words\n here ", expected: .quote("two words here")),
            Row(name: "digits are readable", exact: nil, prefix: "1984", expected: .quote("1984"))
        ]
        for row in rows {
            let beat = plan([entry("m", at: 725_000, exact: row.exact, prefix: row.prefix)])
            XCTAssertEqual(beat.first?.context, row.expected, row.name)
        }
    }

    func testAVeryLongQuoteIsCutAtAWordAndKeepsTheWordsNearestTheMargin() {
        let words = (1...200).map { "word\($0)" }.joined(separator: " ")
        guard case .quote(let before)? = plan([entry("m", prefix: words)]).first?.context,
              case .quote(let article)? = plan([entry("m", exact: words)]).first?.context else { return XCTFail("expected quotes") }
        XCTAssertLessThanOrEqual(before.count, CantPlayListening.longestQuoteCharacters)
        XCTAssertTrue(before.hasSuffix("word200"), "the words just before the moment")
        XCTAssertTrue(before.hasPrefix("word"), "cut on a word, never mid-word")
        XCTAssertLessThanOrEqual(article.count, CantPlayListening.longestQuoteCharacters)
        XCTAssertTrue(article.hasPrefix("word1 "), "an article's quote keeps its start")
        XCTAssertFalse(article.hasSuffix(" word"), "no half word at the cut")
    }

    func testAQuoteWithNoSpacesIsCutAtTheCharacterLimit() {
        let run = String(repeating: "あ", count: 500) + "い"
        guard case .quote(let before)? = plan([entry("m", prefix: run)]).first?.context,
              case .quote(let article)? = plan([entry("m", exact: run)]).first?.context else { return XCTFail("expected quotes") }
        XCTAssertEqual(before.count, CantPlayListening.longestQuoteCharacters)
        XCTAssertTrue(before.hasSuffix("い"), "the end, nearest the moment")
        XCTAssertEqual(article.count, CantPlayListening.longestQuoteCharacters)
        XCTAssertTrue(article.hasPrefix("あ") && !article.contains("い"), "an article's quote keeps its start")
    }

    func testAQuoteInALanguageWithNoVoiceBecomesThePlace() {
        let japanese = "これは日本語の文章です。"
        let noJapaneseVoice: (String) -> String? = { $0.hasPrefix("ja") ? nil : $0 }
        let beat = plan([entry("m", prefix: japanese)], voiceFor: noJapaneseVoice)[0]
        XCTAssertEqual(beat.context, .place(timeWords: "At 12 minutes", title: "Big Show"))
        XCTAssertEqual(plan([entry("m", prefix: japanese)])[0].context, .quote(japanese), "with a voice for it, it is read")
    }

    func testTheSpokenWordsOfAQuoteAndAPlace() {
        XCTAssertEqual(plan([entry("m", prefix: "We went to the market.")])[0].spokenContext, "The episode says: We went to the market.")
        XCTAssertEqual(plan([entry("m")])[0].spokenContext, "At 12 minutes, in Big Show")
    }

    func testThePlaceNamesTheEpisodeOrSaysThisEpisode() {
        XCTAssertEqual(plan([entry("m")], title: nil)[0].spokenContext, "At 12 minutes, in this episode")
        XCTAssertEqual(plan([entry("m")], title: "   ")[0].spokenContext, "At 12 minutes, in this episode")
        XCTAssertEqual(plan([entry("m")], title: "🎧")[0].spokenContext, "At 12 minutes, in this episode")
        XCTAssertEqual(plan([entry("m")], title: "Ep. 5: “Why?” https://x.io")[0].spokenContext, "At 12 minutes, in Ep. 5: “Why?”")
    }

    func testTimeWordsUnderAMinuteOverAnHourAndBetween() {
        let table: [(Int, String)] = [
            (-5, "At the start"), (0, "At the start"), (999, "At the start"), (1_000, "At 1 second"), (40_000, "At 40 seconds"),
            (59_999, "At 59 seconds"), (60_000, "At 1 minute"), (119_999, "At 1 minute"), (720_000, "At 12 minutes"),
            (3_540_000, "At 59 minutes"), (3_600_000, "At 1 hour"), (3_660_000, "At 1 hour 1 minute"),
            (3_900_000, "At 1 hour 5 minutes"), (7_200_000, "At 2 hours"), (7_320_000, "At 2 hours 2 minutes")
        ]
        for (ms, words) in table { XCTAssertEqual(CantPlayListening.timeWords(forMediaTimeMs: ms), words, "\(ms) ms") }
    }

    // MARK: Whether to take this path

    private func start(_ status: PlaybackStatus, item: String? = "item", failure: String? = nil) -> CantPlayListening.Start {
        .init(itemId: item, status: status, lastFailure: failure)
    }

    private func decide(
        from old: CantPlayListening.Start = CantPlayListening.Start(itemId: "item", status: .starting, lastFailure: nil),
        to new: CantPlayListening.Start = CantPlayListening.Start(itemId: "item", status: .failed, lastFailure: "playback_start_failed:timed out"),
        selected: String = "item", podcast: Bool = true, file: Bool = false, margins: Int = 2, active: Bool = true, onScreen: Bool = true
    ) -> Bool {
        CantPlayListening.startFailed(from: old, to: new, around: .init(
            selectedItemId: selected, isPodcastEpisode: podcast, hasPlayableFile: file, friendMargins: margins,
            appIsActive: active, onPlaybackScreen: onScreen
        ))
    }

    func testOnlyThisAttemptToStartAnEpisodeWithNoFileFailingTakesThisPath() {
        XCTAssertTrue(decide(), "the first tap on a dead episode")
        XCTAssertFalse(decide(from: start(.failed, failure: "playback_start_failed:x")), "an old failure is not a change")
        XCTAssertFalse(decide(from: start(.playing)), "a failure after playing is not a start")
        XCTAssertFalse(decide(from: start(.idle)))
        XCTAssertFalse(decide(to: start(.failed, failure: "playback_failed:x")), "a mid-playback failure keeps its own message")
        XCTAssertFalse(decide(to: start(.failed, failure: nil)))
        XCTAssertFalse(decide(to: start(.starting, failure: "playback_start_failed:x")), "still recovering: Review keeps its retry")
        XCTAssertFalse(decide(podcast: false), "an article's start timeout is not a dead episode")
        XCTAssertFalse(decide(file: true), "a saved or brought file that won't start keeps its own message")
        XCTAssertFalse(decide(margins: 0), "no friend Margins: the ordinary message")
        XCTAssertFalse(decide(selected: "other"), "not the open item")
        XCTAssertFalse(decide(from: start(.starting, item: "other")), "the item changed under the attempt")
        XCTAssertFalse(decide(active: false), "a Play from the Lock Screen or CarPlay, or after leaving the app: nobody is watching")
        XCTAssertFalse(decide(onScreen: false), "the listener is not on the playback screen: a voice never starts on its own elsewhere")
    }

    func testAReviewTapOnADeadEpisodeNeedsTheFailureNotTheTransition() {
        let around = CantPlayListening.Surroundings(
            selectedItemId: "item", isPodcastEpisode: true, hasPlayableFile: false, friendMargins: 0, appIsActive: false, onPlaybackScreen: false
        )
        XCTAssertTrue(CantPlayListening.isDeadEpisode(start(.failed, failure: "playback_start_failed:x"), around), "dead, however long ago")
        XCTAssertFalse(CantPlayListening.isDeadEpisode(start(.failed, failure: "playback_failed:x"), around))
        XCTAssertFalse(CantPlayListening.isDeadEpisode(start(.starting, failure: "playback_start_failed:x"), around), "still trying: the ordinary Review")
        XCTAssertFalse(CantPlayListening.isDeadEpisode(start(.failed, item: "other", failure: "playback_start_failed:x"), around))
    }

    /// A real engine whose start failed for good, the way a dead stream does: silent, recreated once, then given up on.
    private func deadEpisodeEngine(_ audio: RecordingAudioClient) throws -> SessionEngine {
        audio.startStatus = .pending
        var clock = Date(timeIntervalSince1970: 100)
        let item = Item(
            id: "item", title: "Dead", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/gone.mp3")
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
            ),
            repository: InMemorySessionRepository(items: [item.id: item]), audio: audio, playbackStartTimeout: 10, now: { clock }
        )
        _ = try engine.startSession(itemId: item.id)
        for _ in 0..<2 {
            clock = clock.addingTimeInterval(11)
            _ = try engine.syncPlaybackProgress()
        }
        XCTAssertEqual(engine.snapshot.status, .failed)
        return engine
    }

    private func isDead(_ engine: SessionEngine) -> Bool {
        CantPlayListening.isDeadEpisode(
            start(engine.snapshot.status, failure: engine.snapshot.lastFailure),
            .init(selectedItemId: "item", isPodcastEpisode: true, hasPlayableFile: false, friendMargins: 0, appIsActive: true, onPlaybackScreen: true)
        )
    }

    /// PR #3606's audit: the listening's own pause turned the real engine's `.failed` into `.paused`, so the episode no
    /// longer read as dead and the next Review tap found no Margins. Every way the machine reaches the source, on the real
    /// engine: playing through (`playTargetNow`, then each step's end), a progress tick (`observe`), and Stop (`stopReview`).
    @MainActor
    func testACantPlayListeningNeverTouchesTheSourceSoTheEpisodeStillReadsAsDeadAfterIt() throws {
        let audio = RecordingAudioClient()
        let engine = try deadEpisodeEngine(audio)
        let beats = plan([entry("a", prefix: "One."), entry("b", prefix: "Two.")])
        var touched: [String] = []
        var played: [String] = []
        func listening(placeMs: Int) throws -> MarginMomentConductor {
            let conductor = MarginMomentConductor(
                sequence: try XCTUnwrap(CantPlayListening.sequence(for: beats, itemId: "item", placeMs: placeMs)),
                source: .init(
                    pause: { touched.append("pause"); _ = try? engine.pause() },
                    resume: { touched.append("resume"); _ = try? engine.resumePlayback() },
                    seek: { touched.append("seek \($0)"); _ = try? engine.seekMedia(toMediaTimeMs: $0) }
                ),
                voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/voice.m4a") }
            )
            conductor.onVoiceUnavailable = { id, _ in played.append(id) }
            return conductor
        }

        let throughToTheEnd = try listening(placeMs: 5_000)
        throughToTheEnd.start()
        throughToTheEnd.playTargetNow()
        XCTAssertEqual(played.count, 4, "words, Margin, words, Margin")
        XCTAssertEqual(touched, [], "played through")
        XCTAssertEqual(engine.snapshot.status, .failed, "played through")
        XCTAssertTrue(isDead(engine), "the next Review tap still finds the Margins")

        played = []
        let onATick = try listening(placeMs: 5_000)
        onATick.startListening(atMediaTimeMs: 4_900)
        onATick.observe(mediaTimeMs: 5_100)
        XCTAssertEqual(played.first, beats[0].contextId, "a progress tick that crosses the place")
        XCTAssertEqual(touched, [], "a progress tick")

        let stopped = try listening(placeMs: 5_000)
        stopped.stopReview()
        XCTAssertEqual(touched, [], "Stop on the card")
        XCTAssertEqual(engine.snapshot.status, .failed, "Stop on the card")
        XCTAssertTrue(isDead(engine), "after Stop")
    }

    /// The class behind that audit: being dead read a live status that any pause overwrites. An ordinary review that was
    /// running when the start failed gives its place back through a pause first, so does a recording, and they must not
    /// make the episode forget it can't play. A start that confirms does.
    func testAnEpisodeStaysDeadWhenSomethingPausesItUntilAStartConfirms() throws {
        let around = CantPlayListening.Surroundings(
            selectedItemId: "item", isPodcastEpisode: true, hasPlayableFile: false, friendMargins: 1, appIsActive: true, onPlaybackScreen: true
        )
        let failure = "playback_start_failed:x"
        XCTAssertTrue(CantPlayListening.isDeadEpisode(start(.paused, failure: failure), around), "paused after the failure")
        XCTAssertFalse(CantPlayListening.isDeadEpisode(start(.paused), around), "an ordinary pause")
        XCTAssertFalse(CantPlayListening.isDeadEpisode(start(.paused, failure: "playback_failed:x"), around), "it played, then failed")
        XCTAssertFalse(CantPlayListening.isDeadEpisode(start(.playing, failure: failure), around))
        XCTAssertFalse(
            CantPlayListening.startFailed(from: start(.starting, failure: failure), to: start(.paused, failure: failure), around: around),
            "a listener's pause on a retry is no new failure: nothing starts by itself"
        )

        let audio = RecordingAudioClient()
        let engine = try deadEpisodeEngine(audio)
        XCTAssertTrue(isDead(engine))
        _ = try engine.pause()
        XCTAssertEqual(engine.snapshot.status, .paused, "the engine's own pause, as the review's give-back reaches it")
        XCTAssertTrue(isDead(engine), "paused, and still dead")

        audio.startStatus = .confirmed
        _ = try engine.resumePlayback()
        XCTAssertEqual(engine.snapshot.status, .playing)
        _ = try engine.pause()
        XCTAssertFalse(isDead(engine), "it played: a pause now is only a pause")
    }

    /// The first tap on a dead episode, on the real engine's clock: the start is silent, the player recreates it once at
    /// 10 seconds (the status stays `.starting`, so Review keeps its retry), and fails it for good at about 20. That one
    /// change is the trigger; nothing before it and no later reading of the same failure is.
    func testTheFirstTapOnADeadEpisodeFiresOnceWhenTheEngineGivesUpAtAboutTwentySeconds() throws {
        let audio = RecordingAudioClient()
        audio.startStatus = .pending
        var clock = Date(timeIntervalSince1970: 100)
        let item = Item(
            id: "item", title: "Dead", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/gone.mp3")
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]
            ),
            repository: InMemorySessionRepository(items: [item.id: item]), audio: audio, playbackStartTimeout: 10, now: { clock }
        )
        func read(_ snapshot: SessionSnapshot) -> CantPlayListening.Start {
            .init(itemId: snapshot.itemId, status: snapshot.status, lastFailure: snapshot.lastFailure)
        }
        func fires(_ old: SessionSnapshot, _ new: SessionSnapshot) -> Bool {
            CantPlayListening.startFailed(
                from: read(old), to: read(new), around: .init(
                    selectedItemId: "item", isPodcastEpisode: true, hasPlayableFile: false, friendMargins: 1,
                    appIsActive: true, onPlaybackScreen: true
                )
            )
        }
        let tapped = try engine.startSession(itemId: item.id)
        XCTAssertEqual(tapped.status, .starting)
        clock = clock.addingTimeInterval(11)
        let recovering = try engine.syncPlaybackProgress()
        XCTAssertEqual(recovering.status, .starting, "recreated once; the engine hasn't given up")
        XCTAssertFalse(fires(tapped, recovering), "while it can still recover Review keeps its retry")
        clock = clock.addingTimeInterval(11)
        let failed = try engine.syncPlaybackProgress()
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.lastFailure?.hasPrefix("playback_start_failed:") == true)
        XCTAssertTrue(fires(recovering, failed), "the first tap: quote then voice, with no second tap, at about 20 seconds")
        XCTAssertFalse(fires(failed, try engine.syncPlaybackProgress()), "a later reading of the same failure is not a new attempt")
    }

    // MARK: Whether the listener still wants it after the wait

    private func scene(
        item: String? = "item", selected: String = "item", _ status: PlaybackStatus = .starting, recording: Bool = false,
        screen: String = "playback", moment: Bool = false
    ) -> CantPlayListening.Scene {
        .init(playerItemId: item, selectedItemId: selected, status: status, isRecording: recording, screen: screen, hasMarginMoment: moment)
    }

    func testTheListeningStartsWhenNothingChangedDuringTheWait() {
        XCTAssertTrue(CantPlayListening.stillWanted(itemId: "item", began: scene(), now: scene()))
        XCTAssertTrue(CantPlayListening.stillWanted(itemId: "item", began: scene(.failed), now: scene(.failed)))
        XCTAssertTrue(CantPlayListening.stillWanted(itemId: "item", began: scene(moment: true), now: scene(moment: true)), "an earlier moment is the one it replaces")
    }

    func testTheListeningDropsWhenTheListenerMovedOnDuringTheWait() {
        let began = scene()
        let moved: [(String, CantPlayListening.Scene)] = [
            ("another item opened", scene(item: "other", selected: "other")),
            ("the item was left but the player kept it", scene(selected: "other")),
            ("the player lost the item", scene(item: nil)),
            ("a recording started", scene(recording: true)),
            ("they paused", scene(.paused)),
            ("they pressed Play and it began", scene(.playing)),
            ("playback was stopped", scene(.idle)),
            ("they left the playback screen", scene(screen: "item")),
            ("they went Home", scene(screen: "home")),
            ("another Margin moment started", scene(moment: true))
        ]
        for (what, now) in moved { XCTAssertFalse(CantPlayListening.stillWanted(itemId: "item", began: began, now: now), what) }
        XCTAssertFalse(CantPlayListening.stillWanted(itemId: "item", began: scene(.failed), now: scene(.starting)), "they pressed Play after it failed")
        XCTAssertFalse(CantPlayListening.stillWanted(itemId: "item", began: scene(screen: "home"), now: scene(screen: "playback")), "they came back to the screen")
    }

    // MARK: A listening that stops early gives back what it didn't reach

    func testAnEarlyStopGivesBackEveryUnplayedMarginAndNeverTheirWords() throws {
        let beats = plan([entry("a", at: 0, prefix: "One."), entry("b", at: 0, prefix: "Two."), entry("c", at: 0, prefix: "Three.")])
        var sequence = try XCTUnwrap(CantPlayListening.sequence(for: beats, itemId: "item", placeMs: 0))
        _ = sequence.jumpToTarget()
        sequence.marginFinished() // a's words done; a plays next
        XCTAssertEqual(CantPlayListening.unreachedMarginIds(in: sequence), ["shared::cole::a", "shared::cole::b", "shared::cole::c"],
                       "at place zero, where the ordinary rule (ahead of the place) gives nothing back")
        sequence.marginFinished()
        sequence.marginFinished()
        XCTAssertEqual(CantPlayListening.unreachedMarginIds(in: sequence), ["shared::cole::b", "shared::cole::c"])
    }

    func testOnlyAMarginsOwnIdCanBeMarkedHeardWhenItsVoiceStarts() {
        let beats = plan([entry("a", prefix: "One."), entry("w", prefix: "Two.", voice: false, words: "I disagree")])
        let markable = Set(beats.map(\.marginId))
        let started = CantPlayListening.anchors(for: beats, placeMs: 0).map(\.marginId)
        XCTAssertEqual(started.filter(markable.contains), beats.map(\.marginId), "the words' ids are never in the heard lookup")
        XCTAssertEqual(started.filter { !markable.contains($0) }, beats.map(\.contextId))
    }
}
