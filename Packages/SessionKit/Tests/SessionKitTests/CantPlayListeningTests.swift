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

    func testOnlyAnEpisodeWithNoFileThatStalledOrFailedInThePlayerTakesThisPath() {
        func decide(saved: Bool = false, stalled: Bool = false, failed: Bool = false, margins: Int = 2) -> Bool {
            CantPlayListening.shouldHearWithoutEpisode(.init(hasSavedAudio: saved, startStalled: stalled, playerFailed: failed), friendMargins: margins)
        }
        XCTAssertTrue(decide(stalled: true))
        XCTAssertTrue(decide(failed: true))
        XCTAssertFalse(decide(), "nothing definite is known: the episode starts the ordinary way and a stall comes here")
        XCTAssertFalse(decide(stalled: true, margins: 0), "no friend Margins: the ordinary message")
        XCTAssertFalse(decide(saved: true, stalled: true), "a saved file that won't start keeps its own message")
        XCTAssertFalse(decide(saved: true, failed: true))
    }

    /// The first review finding: a download that failed (a missing or short saved file, a dropped transfer) says nothing
    /// about streaming. The decision has no download state to be fooled by, so this holds the type to that.
    func testADownloadStateIsNotPartOfTheDecision() {
        let mirror = Mirror(reflecting: CantPlayListening.Episode(hasSavedAudio: false, startStalled: false, playerFailed: false))
        XCTAssertEqual(Set(mirror.children.compactMap(\.label)), ["hasSavedAudio", "startStalled", "playerFailed"])
    }

    // MARK: Whether the listener still wants it after the wait

    private func scene(
        item: String? = "item", selected: String = "item", _ status: PlaybackStatus = .starting, recording: Bool = false,
        screen: Bool = true, moment: Bool = false
    ) -> CantPlayListening.Scene {
        .init(playerItemId: item, selectedItemId: selected, status: status, isRecording: recording, onPlaybackScreen: screen, hasMarginMoment: moment)
    }

    func testTheListeningStartsWhenNothingChangedDuringTheWait() {
        XCTAssertTrue(CantPlayListening.stillWanted(itemId: "item", began: scene(), now: scene()))
        XCTAssertTrue(CantPlayListening.stillWanted(itemId: "item", began: scene(.failed), now: scene(.failed)))
        XCTAssertTrue(CantPlayListening.stillWanted(itemId: "item", began: scene(.starting), now: scene(.failed)), "the stalled start then reported its failure")
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
            ("they left the playback screen", scene(screen: false)),
            ("another Margin moment started", scene(moment: true))
        ]
        for (what, now) in moved { XCTAssertFalse(CantPlayListening.stillWanted(itemId: "item", began: began, now: now), what) }
        XCTAssertFalse(CantPlayListening.stillWanted(itemId: "item", began: scene(.failed), now: scene(.starting)), "they pressed Play after it failed")
        XCTAssertFalse(CantPlayListening.stillWanted(itemId: "item", began: scene(screen: false), now: scene(screen: true)), "they came back to the screen")
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
