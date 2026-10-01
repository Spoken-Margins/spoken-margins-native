import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #295 (found on the phone): long titles on Now Playing took five or more lines at the large
/// serif size. The title now shrinks through three text styles to fit three lines, then clips.
@MainActor
final class PlaybackTitleFitTests: XCTestCase {
    /// Now Playing's text width on a 402 pt iPhone 17 Pro: 22 pt padding on each side.
    private let phoneWidth: CGFloat = 402 - 2 * 22

    // The three titles from the round-two design page's tester.
    private let short = "Middlegarchs are the new Oligarchs"
    private let testDesk = "Are Prediction Markets Gambling? A Lot Rides on the Answer."
    private let madeUpLong = "Why the Middle Class Keeps Shrinking Even When Wages Rise, and What the Housing Market Has to Do With It"

    private func lines(_ title: String, _ style: Font.TextStyle, size: DynamicTypeSize = .large) -> Int {
        PlaybackTitleFit.lineCount(
            of: title,
            font: PlaybackTitleFit.font(for: style, category: PlaybackTitleFit.contentSizeCategory(size)),
            width: phoneWidth
        )
    }

    func testRuleTakesTheFirstSizeThatFitsThreeLinesThenClips() {
        func choice(_ counts: [Font.TextStyle: Int]) -> PlaybackTitleFit.Choice {
            PlaybackTitleFit.choose(isAccessibilitySize: false) { counts[$0] ?? 99 }
        }
        XCTAssertEqual(choice([.largeTitle: 3]), .init(style: .largeTitle, lineLimit: 3))
        XCTAssertEqual(choice([.largeTitle: 4, .title: 3]), .init(style: .title, lineLimit: 3))
        XCTAssertEqual(choice([.largeTitle: 5, .title: 4, .title2: 3]), .init(style: .title2, lineLimit: 3))
        XCTAssertEqual(choice([.largeTitle: 7, .title: 6, .title2: 5]), .init(style: .title2, lineLimit: 3), "clipped at Small")
        XCTAssertEqual(
            PlaybackTitleFit.choose(isAccessibilitySize: true) { _ in 9 },
            .init(style: .largeTitle, lineLimit: 4),
            "accessibility sizes keep Large, allow four lines and clip"
        )
    }

    func testDesignSampleTitlesOnAPhone() {
        // The bug: at the old fixed Large size the long title ran well past three lines.
        XCTAssertGreaterThan(lines(madeUpLong, .largeTitle), 4)

        let shortFit = PlaybackTitleFit.choose(short, width: phoneWidth, dynamicTypeSize: .large)
        XCTAssertEqual(shortFit, .init(style: .largeTitle, lineLimit: 3), "a short title keeps the large size")

        let testDeskFit = PlaybackTitleFit.choose(testDesk, width: phoneWidth, dynamicTypeSize: .large)
        XCTAssertLessThanOrEqual(lines(testDesk, testDeskFit.style), 3, "fits whole at the size chosen")
        for larger in PlaybackTitleFit.steps.prefix(while: { $0 != testDeskFit.style }) {
            XCTAssertGreaterThan(lines(testDesk, larger), 3, "a larger size was skipped only because it didn't fit")
        }
        XCTAssertEqual(testDeskFit.lineLimit, 3)

        let longFit = PlaybackTitleFit.choose(madeUpLong, width: phoneWidth, dynamicTypeSize: .large)
        XCTAssertEqual(longFit, .init(style: .title2, lineLimit: 3), "steps down to Small and clips at three lines")
    }

    func testAccessibilitySizesClipAtFourLinesWithoutShrinking() {
        let fit = PlaybackTitleFit.choose(madeUpLong, width: phoneWidth, dynamicTypeSize: .accessibility3)
        XCTAssertEqual(fit, .init(style: .largeTitle, lineLimit: 4))
        XCTAssertGreaterThan(lines(madeUpLong, .largeTitle, size: .accessibility3), 4, "so it is clipped")
    }

    func testBiggerTextSizesMeasureMoreLines() {
        XCTAssertGreaterThan(lines(testDesk, .title2, size: .xxxLarge), lines(testDesk, .title2, size: .xSmall))
    }

    func testUnknownWidthNeverExceedsTheBudget() {
        XCTAssertEqual(PlaybackTitleFit.choose(madeUpLong, width: 0, dynamicTypeSize: .large).lineLimit, 3)
    }
}
