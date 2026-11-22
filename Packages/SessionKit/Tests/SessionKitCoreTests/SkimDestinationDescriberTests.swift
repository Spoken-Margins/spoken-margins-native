import XCTest
@testable import SessionKit

/// #3986: the chapter row's arrows say where they go. The words are `SkimDestinationSpeechTests`; these check the
/// lookup that turns a Skim stop into a chapter, the listener's Margin or a friend's.
final class SkimDestinationDescriberTests: XCTestCase {
    private let textChapters: [(id: String, title: String, position: Int)] = [
        ("c1", "Intro", 0), ("c2", "Alignment", 4_000), ("c3", "", 8_000),
    ]
    private let mediaChapters: [(id: String, title: String, position: Int)] = [
        ("m1", "Welcome", 0), ("m2", "Deep dive", 1_800_000), ("m3", "Wrap up", 4_050_000),
    ]

    private func describer(
        text: Bool, playhead: Int?, friends: [String: String?] = [:], own: Set<String> = []
    ) -> SkimDestinationDescriber {
        SkimDestinationDescriber(
            isText: text, textLength: 10_000, chapters: text ? textChapters : mediaChapters,
            ownMarginIds: own, friendLabels: friends, playhead: playhead)
    }

    private func choice(_ describer: SkimDestinationDescriber, _ direction: SkimDirection, margins: [SkimStop] = [],
                        playhead: Int, text: Bool) -> SkimStopRouting.Choice {
        let chapters = (text ? textChapters : mediaChapters).map { SkimStop(kind: .chapter, id: $0.id, position: $0.position) }
        let stops = SkimStops(chapters: chapters, margins: margins, unit: text ? .characters(perSecond: 15) : .milliseconds)
        let target = direction == .forward ? stops.next(playhead: playhead) : stops.previous(playhead: playhead)
        return SkimStopRouting.choose(direction: direction, stop: target, summaryDestination: nil)
    }

    func testTextChapterSaysItsTitleAndPercent() {
        let d = describer(text: true, playhead: 1_000)
        let speech = d.speech(direction: .forward, choice: choice(d, .forward, playhead: 1_000, text: true), summaryDestination: nil)
        XCTAssertEqual(speech, .init(label: "Skim forward", value: "Alignment, 40 percent"))
    }

    func testBackFromInsideAChapterSaysStartOfThisChapter() {
        let d = describer(text: true, playhead: 5_000)
        let speech = d.speech(direction: .backward, choice: choice(d, .backward, playhead: 5_000, text: true), summaryDestination: nil)
        XCTAssertEqual(speech, .init(label: "Skim back", value: "Start of this chapter, 40 percent"))
    }

    func testBackFromTheStartOfAChapterNamesTheEarlierChapter() {
        let d = describer(text: true, playhead: 4_000)
        let speech = d.speech(direction: .backward, choice: choice(d, .backward, playhead: 4_000, text: true), summaryDestination: nil)
        XCTAssertEqual(speech.value, "Intro, 0 percent")
    }

    func testUntitledChapterIsNumbered() {
        let d = describer(text: true, playhead: 5_000)
        let speech = d.speech(direction: .forward, choice: choice(d, .forward, playhead: 5_000, text: true), summaryDestination: nil)
        XCTAssertEqual(speech.value, "Chapter 3, 80 percent")
    }

    func testMediaChapterSaysTheSpokenTime() {
        let d = describer(text: false, playhead: 2_000_000)
        let speech = d.speech(direction: .forward, choice: choice(d, .forward, playhead: 2_000_000, text: false), summaryDestination: nil)
        XCTAssertEqual(speech.value, "Wrap up, 1 hour, 7 minutes, 30 seconds")
    }

    func testOwnAndFriendMargins() {
        let margins = [SkimStop(kind: .margin, id: "own", position: 1_500_000), SkimStop(kind: .margin, id: "sam", position: 1_700_000)]
        let d = describer(text: false, playhead: 100_000, friends: ["sam": "Sam"], own: ["own"])
        let first = d.speech(direction: .forward, choice: choice(d, .forward, margins: margins, playhead: 100_000, text: false), summaryDestination: nil)
        XCTAssertEqual(first.value, "Your Margin, 25 minutes")
        let second = d.speech(direction: .forward, choice: choice(d, .forward, margins: margins, playhead: 1_600_000, text: false), summaryDestination: nil)
        XCTAssertEqual(second.value, "Sam's Margin, 28 minutes, 20 seconds")
    }

    func testFriendWithAStandInNameOrNoneIsAFriend() {
        let margins = [SkimStop(kind: .margin, id: "f1", position: 1_500_000)]
        for label in [nil, "Someone", "  "] as [String?] {
            let d = describer(text: false, playhead: 100_000, friends: ["f1": label])
            let speech = d.speech(direction: .forward, choice: choice(d, .forward, margins: margins, playhead: 100_000, text: false), summaryDestination: nil)
            XCTAssertEqual(speech.value, "A friend's Margin, 25 minutes", "label \(String(describing: label))")
        }
    }

    func testSummaryFirstNamesTheSceneItLandsIn() {
        let d = describer(text: false, playhead: 100_000)
        let speech = d.speech(direction: .forward, choice: .summary, summaryDestination: 1_800_000)
        XCTAssertEqual(speech.value, "Deep dive, summary first, 30 minutes")
    }

    /// A summary lands at a Listening Map scene start, which is usually inside one of the item's own chapters: the title
    /// is the chapter it falls in, not only one that starts exactly there (review of #3986 PR 2).
    func testSummaryFirstNamesTheChapterASceneStartsInside() {
        let d = describer(text: false, playhead: 100_000)
        XCTAssertEqual(d.speech(direction: .forward, choice: .summary, summaryDestination: 2_400_000).value,
                       "Deep dive, summary first, 40 minutes")
        XCTAssertEqual(d.landingSpeech(direction: .forward, at: 4_100_000).value, "Wrap up, 1 hour, 8 minutes, 20 seconds")
    }

    func testNoChapterIsMadeUpWhenNoneHasStarted() {
        let d = SkimDestinationDescriber(
            isText: false, textLength: 0, chapters: [("late", "Late start", 5_000)], ownMarginIds: [], friendLabels: [:], playhead: 0)
        XCTAssertEqual(d.speech(direction: .forward, choice: .summary, summaryDestination: 1_234).value,
                       "summary first, 1 second", "nothing has started by then: no title is made up")
        let none = describer(text: false, playhead: 0)
        let empty = SkimDestinationDescriber(
            isText: false, textLength: 0, chapters: [], ownMarginIds: [], friendLabels: [:], playhead: 0)
        XCTAssertNil(empty.chapterTitle(containing: 1_000))
        XCTAssertNil(empty.chapterTitle(id: "m1"))
        XCTAssertEqual(none.chapterTitle(containing: 0), "Welcome")
    }

    func testBackwardToAMarginAndFriendMarginOnText() {
        let margins = [SkimStop(kind: .margin, id: "own", position: 2_000), SkimStop(kind: .margin, id: "sam", position: 3_000)]
        let d = describer(text: true, playhead: 3_500, friends: ["sam": "Sam"], own: ["own"])
        let back = d.speech(direction: .backward, choice: choice(d, .backward, margins: margins, playhead: 3_500, text: true), summaryDestination: nil)
        XCTAssertEqual(back, .init(label: "Skim back", value: "Sam's Margin, 30 percent"))
    }

    func testNothingAheadAndAPlayingSummary() {
        let d = describer(text: false, playhead: 4_100_000)
        XCTAssertEqual(d.speech(direction: .forward, choice: .unavailable, summaryDestination: nil).value, "Nothing ahead to skim to")
        XCTAssertEqual(d.speech(direction: .backward, choice: nil, summaryDestination: nil).value, "Nothing behind to skim to")
        XCTAssertEqual(d.landingSpeech(direction: .forward, at: 4_050_000).value, "Wrap up, 1 hour, 7 minutes, 30 seconds")
    }

    /// Audit of #4275: while a Margin's voice plays, forward only ends the voice (`.skipVoice`) and the source carries
    /// on from where it paused. The arrow says that place, not the stop after the playhead, which the press never reaches.
    func testDuringAMarginsVoiceForwardSaysWhereTheSourceCarriesOn() {
        let d = describer(text: false, playhead: 1_500_000)
        let stored = choice(d, .forward, playhead: 1_500_000, text: false)
        XCTAssertEqual(d.speech(direction: .forward, choice: stored, summaryDestination: nil).value,
                       "Deep dive, 30 minutes", "the stored choice is the next stop")
        let voice = d.arrowSpeech(direction: .forward, summaryLanding: nil, momentPress: .skipVoice, choice: stored, summaryDestination: nil)
        XCTAssertEqual(voice, .init(label: "Skim forward", value: "Welcome, 25 minutes"))
        // A playing summary is answered first, as a press is.
        XCTAssertEqual(d.arrowSpeech(direction: .forward, summaryLanding: 4_050_000, momentPress: .skipVoice,
                                     choice: stored, summaryDestination: nil).value, "Wrap up, 1 hour, 7 minutes, 30 seconds")
        // The lead-in plays the Margin now, which is the stop the routing chose; back ends the moment and then goes to
        // the stop the routing chose. Both say the stored choice.
        for press in [.navigate, .playMarginNow, .endMomentThenNavigate] as [SkimStopRouting.MomentPress] {
            XCTAssertEqual(d.arrowSpeech(direction: .forward, summaryLanding: nil, momentPress: press, choice: stored,
                                         summaryDestination: nil).value, "Deep dive, 30 minutes", "\(press)")
        }
    }

    /// Audit of #4275: just after the playback screen opens, the item on screen can still be the one opened before. Its
    /// chapters and length are not the playing item's, so the describer names none rather than the wrong item's.
    func testAnotherItemsDetailGivesNoChaptersAndNoLength() {
        var other = ItemDetailState()
        other.id = "other"
        other.text = String(repeating: "x", count: 500)
        other.chapters = [Chapter(id: "o1", title: "Other item's chapter", startChar: 0, endChar: 500, percent: 0)]
        other.mediaChapters = [MediaTimelineChapter(id: "o2", title: "Other episode's chapter", startMs: 0, transcriptSegmentId: "s")]
        for isText in [true, false] {
            let d = SkimDestinationDescriber(
                playing: "playing", detail: other, isText: isText, ownMarginIds: [], friendLabels: [:], playhead: 100)
            XCTAssertTrue(d.chapters.isEmpty, "isText \(isText)")
            XCTAssertEqual(d.textLength, 0, "isText \(isText)")
            XCTAssertEqual(d.speech(direction: .forward, choice: .summary, summaryDestination: 370).value,
                           isText ? "summary first" : "summary first, 0 seconds", "isText \(isText)")
        }
        var playing = other
        playing.id = "playing"
        let text = SkimDestinationDescriber(
            playing: "playing", detail: playing, isText: true, ownMarginIds: [], friendLabels: [:], playhead: 100)
        XCTAssertEqual(text.speech(direction: .forward, choice: .summary, summaryDestination: 250).value,
                       "Other item's chapter, summary first, 50 percent")
        let media = SkimDestinationDescriber(
            playing: "playing", detail: playing, isText: false, ownMarginIds: [], friendLabels: [:], playhead: 100)
        XCTAssertEqual(media.chapterTitle(id: "o2"), "Other episode's chapter")
    }

    func testTextWithUnknownLengthLeavesTheNumberOut() {
        var d = describer(text: true, playhead: 1_000)
        d.textLength = 0
        let speech = d.speech(direction: .forward, choice: choice(d, .forward, playhead: 1_000, text: true), summaryDestination: nil)
        XCTAssertEqual(speech.value, "Alignment")
    }

    func testNextChapterWithAndWithoutAReason() {
        let d = describer(text: true, playhead: 1_000)
        XCTAssertEqual(d.nextChapterSpeech(standingInFor: nil, chapterId: "c2", start: 4_000, inSkimSlot: true),
                       .init(label: "Next chapter", value: "Alignment, 40 percent"))
        XCTAssertEqual(d.nextChapterSpeech(standingInFor: .movedOn, chapterId: "c2", start: 4_000, inSkimSlot: true).value,
                       SkimUnavailableReason.movedOn.message)
        XCTAssertEqual(d.nextChapterSpeech(standingInFor: nil, chapterId: "c2", start: 4_000, inSkimSlot: false).value,
                       "Alignment, 40 percent")
    }
}
