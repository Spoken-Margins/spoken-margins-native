import Foundation
import XCTest
@testable import SessionKit

/// #777: a Margin row says what the Margin is about and where it was made, in the order it was heard.
final class MarginRowWordingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let locale = Locale(identifier: "en_US_POSIX")
    /// Tuesday 2026-10-06 12:00 UTC.
    private let tuesday = Date(timeIntervalSince1970: 1_791_288_000)

    private func line(placeName: String? = nil, mediaTimeMs: Int? = nil, paragraph: Int? = nil, percent: Int = 42,
                      createdAt: Date, now: Date) -> String {
        MarginRowWording.placeLine(placeName: placeName, mediaTimeMs: mediaTimeMs, paragraph: paragraph, roughPercent: percent,
                                   createdAt: createdAt, now: now, calendar: calendar, locale: locale)
    }

    // MARK: Place line

    func testAChapterClockTimeAndWeekday() {
        let now = tuesday.addingTimeInterval(3_600)
        XCTAssertEqual(line(placeName: "Ch. 3", mediaTimeMs: 1_263_000, createdAt: tuesday, now: now), "Ch. 3 · 21:03 · Tue")
    }

    func testAPodcastWithoutChaptersLeavesTheNameOut() {
        XCTAssertEqual(line(mediaTimeMs: 3_723_000, createdAt: tuesday, now: tuesday), "1:02:03 · Tue")
    }

    func testATextItemReadsParagraphN() {
        XCTAssertEqual(line(paragraph: 12, createdAt: tuesday, now: tuesday), "paragraph 12 · Tue")
    }

    func testWithNoPositionItFallsBackToThePercent() {
        XCTAssertEqual(line(percent: 42, createdAt: tuesday, now: tuesday), "42% · Tue")
        XCTAssertEqual(line(paragraph: 0, percent: 7, createdAt: tuesday, now: tuesday), "7% · Tue")
    }

    func testABlankPlaceNameIsLeftOut() {
        XCTAssertEqual(line(placeName: "  \n", mediaTimeMs: 5_000, createdAt: tuesday, now: tuesday), "00:05 · Tue")
    }

    func testAnOlderDayShowsTheDateToo() {
        let now = tuesday.addingTimeInterval(8 * 86_400)
        XCTAssertEqual(line(mediaTimeMs: 5_000, createdAt: tuesday, now: now), "00:05 · Tue 6 Oct")
        let justInsideTheWeek = tuesday.addingTimeInterval(6.5 * 86_400)
        XCTAssertEqual(line(mediaTimeMs: 5_000, createdAt: tuesday, now: justInsideTheWeek), "00:05 · Tue")
    }

    // MARK: Order

    private func margin(_ id: String, session: String = "s1", mediaTimeMs: Int? = nil, startChar: Int = 0, created: TimeInterval = 0) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: session, targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: created), roughPercent: 0,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: startChar,
                           anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil,
            cleanedTranscript: nil, displayText: nil, status: "active")
    }

    private func order(_ margins: [Interjection]) -> [String] {
        margins.sorted(by: MarginSourceOrder.isOrderedBefore).map(\.id)
    }

    func testMediaMarginsAreListedInTheOrderTheyWereHeardAcrossSessions() {
        let margins = [
            margin("late", session: "s1", mediaTimeMs: 900_000, created: 1),
            margin("early-but-newer-session", session: "s2", mediaTimeMs: 60_000, created: 9),
            margin("middle", session: "s2", mediaTimeMs: 300_000, created: 5),
        ]
        XCTAssertEqual(order(margins), ["early-but-newer-session", "middle", "late"])
    }

    func testTextMarginsFollowTheirPositionInTheSource() {
        let margins = [margin("c", startChar: 900), margin("a", startChar: 10), margin("b", startChar: 400)]
        XCTAssertEqual(order(margins), ["a", "b", "c"])
    }

    func testTheSamePositionFallsBackToWhenItWasMadeThenItsId() {
        let margins = [margin("z", mediaTimeMs: 1_000, created: 2), margin("y", mediaTimeMs: 1_000, created: 1), margin("a", mediaTimeMs: 1_000, created: 2)]
        XCTAssertEqual(order(margins), ["y", "a", "z"])
    }

    func testMixedMediaAndTextMarginsKeepAStableOrder() {
        let margins = [margin("text", startChar: 5), margin("media", mediaTimeMs: 90_000)]
        XCTAssertEqual(order(margins), ["media", "text"])
        XCTAssertEqual(order(Array(margins.reversed())), ["media", "text"])
    }

    // MARK: Gist

    func testAShortMarginShowsItsOwnWords() {
        XCTAssertEqual(MarginGist.gist(from: "  Check this claim\nagainst the footnote. "), "Check this claim against the footnote.")
    }

    func testNoWordsMeansNoGist() {
        XCTAssertNil(MarginGist.gist(from: ""))
        XCTAssertNil(MarginGist.gist(from: " \n\t "))
    }

    func testALongMarginDropsItsWarmUp() {
        let text = "So I think what's interesting here is that housing costs keep outrunning wages. "
            + "And then the author goes on to compare three other cities in a way I did not follow very well."
        XCTAssertEqual(MarginGist.gist(from: text), "Housing costs keep outrunning wages.")
    }

    func testAWarmUpSentenceOnItsOwnIsSkippedForTheNextSentence() {
        let text = "Okay so. Um. The second chart contradicts the first one about rents in the north. I will come back to this later on in the week."
        XCTAssertEqual(MarginGist.gist(from: text), "The second chart contradicts the first one about rents in the north.")
    }

    func testALongSentenceIsCutAtTwelveWords() {
        let text = "This argument depends on one number that the author never explains anywhere in the whole chapter, and I want to know where it comes from."
        XCTAssertEqual(MarginGist.gist(from: text), "This argument depends on one number that the author never explains anywhere…")
    }

    func testFillerMatchingIgnoresCaseCurlyApostrophesAndPunctuation() {
        let text = "Well, I THINK what\u{2019}s interesting here is: rents rose faster than pay across every single region in the data. More to say."
        XCTAssertEqual(MarginGist.gist(from: text), "Rents rose faster than pay across every single region in the data.")
    }

    func testAWordThatOnlyStartsLikeAFillerIsKept() {
        let text = "Sonic booms are the part of this essay I found hardest to believe, given the sources cited in the notes."
        XCTAssertEqual(MarginGist.gist(from: text)?.hasPrefix("Sonic booms"), true)
    }
}
