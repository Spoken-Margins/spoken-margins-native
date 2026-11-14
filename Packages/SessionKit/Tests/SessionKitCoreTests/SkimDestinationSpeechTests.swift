import XCTest
@testable import SessionKit

/// The chapter row's VoiceOver words (#3986): one test per row of the Design's table, in both units.
final class SkimDestinationSpeechTests: XCTestCase {
    private typealias Speech = SkimDestinationSpeech

    private func skim(_ direction: Speech.Direction, _ destination: Speech.Destination, _ position: String? = nil) -> Speech.Speech {
        Speech.skim(direction, to: destination, position: position)
    }

    // MARK: position text

    func testPositionsAreSaidInTheItemsOwnUnit() {
        XCTAssertEqual(PlaybackPositionText.spoken(ms: 4_050_000), "1 hour, 7 minutes, 30 seconds")
        XCTAssertEqual(PlaybackPositionText.visible(ms: 4_050_000), "1:07:30")
        XCTAssertEqual(PlaybackPositionText.spoken(ms: 7_200_000 + 4_050_000), "3 hours, 7 minutes, 30 seconds", "a two-hour stop keeps its plural")
        XCTAssertEqual(PlaybackPositionText.spoken(ms: 450_000), "7 minutes, 30 seconds", "an hour of zero is left out")
        XCTAssertEqual(PlaybackPositionText.visible(ms: 450_000), "7:30")
        XCTAssertEqual(PlaybackPositionText.spoken(ms: 3_600_000), "1 hour", "zero minutes and seconds are left out")
        XCTAssertEqual(PlaybackPositionText.spoken(ms: 61_000), "1 minute, 1 second")
        XCTAssertEqual(PlaybackPositionText.spoken(ms: 400), "0 seconds")
        XCTAssertEqual(PlaybackPositionText.spoken(ms: -5), "0 seconds", "a negative time is the start")
        XCTAssertEqual(PlaybackPositionText.visible(ms: -5), "0:00")
        XCTAssertEqual(PlaybackPositionText.visible(percent: 65), "65%")
        XCTAssertEqual(PlaybackPositionText.spoken(percent: 65), "65 percent")
        XCTAssertEqual(PlaybackPositionText.spoken(percent: 140), "100 percent", "a percent is kept inside 0 to 100")
    }

    func testTextPercentRoundsDownAndNeverInventsALength() {
        XCTAssertEqual(PlaybackPositionText.percent(position: 650, length: 1_000), 65)
        XCTAssertEqual(PlaybackPositionText.percent(position: 659, length: 1_000), 65, "rounded down")
        XCTAssertEqual(PlaybackPositionText.percent(position: 999, length: 1_000), 99)
        XCTAssertEqual(PlaybackPositionText.percent(position: 1_000, length: 1_000), 100)
        XCTAssertEqual(PlaybackPositionText.percent(position: 5_000, length: 1_000), 100, "past the end is the end")
        XCTAssertEqual(PlaybackPositionText.percent(position: -3, length: 1_000), 0)
        XCTAssertNil(PlaybackPositionText.percent(position: 10, length: 0), "no length, no number")
    }

    // MARK: forward rows

    func testForwardToAChapterOnText() {
        let speech = skim(.forward, .chapter(title: "Chapter 4: Alignment"), PlaybackPositionText.spoken(percent: 65))
        XCTAssertEqual(speech, .init(label: "Skim forward", value: "Chapter 4: Alignment, 65 percent"))
    }

    func testForwardToAChapterOnMedia() {
        let speech = skim(.forward, .chapter(title: "Alignment"), PlaybackPositionText.spoken(ms: 4_050_000))
        XCTAssertEqual(speech, .init(label: "Skim forward", value: "Alignment, 1 hour, 7 minutes, 30 seconds"))
        XCTAssertEqual(skim(.forward, .chapter(title: "Q&A"), PlaybackPositionText.spoken(ms: 450_000)).value, "Q&A, 7 minutes, 30 seconds")
    }

    func testForwardWithASummaryFirstSaysSo() {
        let speech = skim(.forward, .summaryFirst(title: "The turn"), "40 percent")
        XCTAssertEqual(speech.value, "The turn, summary first, 40 percent")
    }

    func testForwardToMargins() {
        XCTAssertEqual(skim(.forward, .ownMargin, "51 percent").value, "Your Margin, 51 percent")
        XCTAssertEqual(skim(.forward, .friendMargin(name: "Sam"), "51 percent").value, "Sam's Margin, 51 percent")
    }

    func testAFriendWithNoNameOrAStandInNameIsAFriend() {
        for name in [nil, "", "   ", "Someone", "Your friend", "your  FRIEND", "Unsigned sender", "Imported collection"] as [String?] {
            XCTAssertEqual(skim(.forward, .friendMargin(name: name), "1 minute").value, "A friend's Margin, 1 minute", "name: \(String(describing: name))")
        }
        XCTAssertEqual(skim(.forward, .friendMargin(name: "  Sam  ")).value, "Sam's Margin", "a name is trimmed")
    }

    func testAnUnplacedFriendMarginOnMediaLeavesOutThePositionAndItsComma() {
        XCTAssertEqual(skim(.forward, .friendMargin(name: "Sam"), nil).value, "Sam's Margin")
        XCTAssertEqual(skim(.forward, .chapter(title: "Alignment"), "").value, "Alignment", "an empty position is also left out")
    }

    func testForwardWhileLoadingDoesNotSayNothingAhead() {
        XCTAssertEqual(skim(.forward, .loading), .init(label: "Skim forward", value: "Still loading. Try again in a moment."))
        XCTAssertEqual(skim(.backward, .loading).value, "Still loading. Try again in a moment.")
    }

    func testNothingAheadAndNothingBehind() {
        XCTAssertEqual(skim(.forward, .none), .init(label: "Skim forward", value: "Nothing ahead to skim to"))
        XCTAssertEqual(skim(.backward, .none), .init(label: "Skim back", value: "Nothing behind to skim to"))
    }

    func testRecordingLocksTheArrowsAndKeepsTheirLabels() {
        XCTAssertEqual(skim(.forward, .locked), .init(label: "Skim forward", value: "Unavailable while recording"))
        XCTAssertEqual(skim(.backward, .locked), .init(label: "Skim back", value: "Unavailable while recording"))
    }

    // MARK: backward rows

    func testBackwardRows() {
        XCTAssertEqual(skim(.backward, .chapterStart, "56 percent"), .init(label: "Skim back", value: "Start of this chapter, 56 percent"))
        XCTAssertEqual(skim(.backward, .chapter(title: "Setup"), "12 percent").value, "Setup, 12 percent")
        XCTAssertEqual(skim(.backward, .ownMargin, "51 percent").value, "Your Margin, 51 percent")
        XCTAssertEqual(skim(.backward, .friendMargin(name: "Sam"), "7 minutes").value, "Sam's Margin, 7 minutes")
        XCTAssertEqual(skim(.backward, .chapterStart, PlaybackPositionText.spoken(ms: 450_000)).value, "Start of this chapter, 7 minutes, 30 seconds")
    }

    // MARK: next chapter

    func testNextChapterInSkimsSlotWithAndWithoutAReason() {
        let reason = Speech.nextChapterInSkimSlot(reason: .loading, title: "Alignment", position: "65 percent")
        XCTAssertEqual(reason, .init(label: "Next chapter", value: SkimUnavailableReason.loading.message))
        let none = Speech.nextChapterInSkimSlot(reason: nil, title: "Alignment", position: "65 percent")
        XCTAssertEqual(none, .init(label: "Next chapter", value: "Alignment, 65 percent"), "with no reason the value is the destination, never a stale reason")
        XCTAssertEqual(Speech.nextChapter(title: "Alignment", position: nil), .init(label: "Next chapter", value: "Alignment"))
    }

    func testAnUntitledChapterIsChapterN() {
        XCTAssertEqual(Speech.chapterTitle("Alignment", index: 3), "Alignment")
        XCTAssertEqual(Speech.chapterTitle(nil, index: 3), "Chapter 4")
        XCTAssertEqual(Speech.chapterTitle("  \n ", index: 0), "Chapter 1")
        XCTAssertEqual(Speech.chapterTitle("", index: 11), "Chapter 12")
    }

    // MARK: the stale words

    func testNoSkimWordsMentionASceneSummaryExceptSummaryFirst() {
        let destinations: [Speech.Destination] = [
            .chapter(title: "A"), .chapterStart, .ownMargin, .friendMargin(name: nil), .friendMargin(name: "Sam"),
            .none, .loading, .locked,
        ]
        for direction in [Speech.Direction.forward, .backward] {
            for destination in destinations {
                let speech = skim(direction, destination, "1 minute")
                XCTAssertFalse((speech.label + " " + speech.value).localizedCaseInsensitiveContains("scene summary"), "\(direction) \(destination)")
            }
        }
        XCTAssertTrue(skim(.forward, .summaryFirst(title: "A")).value.contains("summary first"))
    }
}
