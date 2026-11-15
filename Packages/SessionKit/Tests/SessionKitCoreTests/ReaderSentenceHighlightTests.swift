import Foundation
@testable import SessionKit
import XCTest

/// What the Source Text reader marks for the sentence being read (#3736), and that the marks hold up on the page.
final class ReaderSentenceHighlightTests: XCTestCase {
    func testNoSentenceMarksNothing() {
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 100, sentence: nil))
    }

    func testAnEmptySentenceMarksNothing() {
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 100, sentence: NSRange(location: 10, length: 0)))
    }

    func testAnEmptyTextMarksNothing() {
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 0, sentence: NSRange(location: 0, length: 5)))
    }

    func testASentenceInsideTheTextIsMarkedWithAThickOchreUnderlineOverExactlyIt() throws {
        let span = try XCTUnwrap(ReaderSentenceHighlight.span(textLength: 100, sentence: NSRange(location: 20, length: 30)))
        XCTAssertEqual(span.range, NSRange(location: 20, length: 30))
        XCTAssertTrue(span.underlineIsThick, "The underline is the cue that does not depend on hue")
        XCTAssertEqual(span.underline, AppSemanticColorRGB.ochreText)
        XCTAssertEqual(span.fill, AppSemanticColorRGB.ochre)
        XCTAssertEqual(span.fillAlpha, 0.22)
    }

    func testASentenceRunningPastTheEndIsCutToTheText() throws {
        let span = try XCTUnwrap(ReaderSentenceHighlight.span(textLength: 50, sentence: NSRange(location: 40, length: 30)))
        XCTAssertEqual(span.range, NSRange(location: 40, length: 10))
    }

    func testASentenceStartingAtOrPastTheEndMarksNothing() {
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 50, sentence: NSRange(location: 50, length: 5)))
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 50, sentence: NSRange(location: 80, length: 5)))
    }

    func testAMissingOrNegativeLocationMarksNothing() {
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 50, sentence: NSRange(location: NSNotFound, length: 5)))
        XCTAssertNil(ReaderSentenceHighlight.span(textLength: 50, sentence: NSRange(location: -1, length: 5)))
    }

    func testTheLastCharacterIsMarked() throws {
        let span = try XCTUnwrap(ReaderSentenceHighlight.span(textLength: 50, sentence: NSRange(location: 49, length: 1)))
        XCTAssertEqual(span.range, NSRange(location: 49, length: 1))
    }

    /// The reader draws on `inputBackground`. The fill is decorative and the underline is the cue, so the underline
    /// is held to the non-text 3:1 against the page and against the fill, and the words to 4.5:1 on the fill.
    func testTheReaderMarksMeetTheirRatiosInBothAppearances() {
        XCTAssertEqual(AppColorContrastAudit.failures(for: AppColorContrastAudit.readerHighlightPairs), [])
        let names = Set(AppColorContrastAudit.readerHighlightPairs.map(\.name))
        XCTAssertEqual(names, [
            "reader text on current sentence fill",
            "reader sentence underline on reader surface",
            "reader sentence underline on its fill"
        ])
        XCTAssertTrue(AppColorContrastAudit.allPairs.contains { $0.name == "reader sentence underline on reader surface" },
                      "The reader's pairs must be part of the whole audit")
    }

    /// The old cue, system yellow at 0.22 over the page, was 1.09:1 in light mode: the underline must not be that weak.
    func testTheUnderlineIsFarStrongerThanTheOldFillAlone() {
        let page = AppSemanticColorRGB.inputBackground
        let oldFill = AppSystemColorRGB.yellow.composited(over: page, alpha: 0.22)
        for (underline, fill, appearance) in [
            (ReaderSentenceHighlight.underline.light, oldFill.light, "light"),
            (ReaderSentenceHighlight.underline.dark, oldFill.dark, "dark")
        ] {
            let pageColor = appearance == "light" ? page.light : page.dark
            let oldRatio = AppColorContrastAudit.contrastRatio(foreground: fill, background: pageColor)
            let newRatio = AppColorContrastAudit.contrastRatio(foreground: underline, background: pageColor)
            XCTAssertLessThan(oldRatio, 2, "the old fill alone, \(appearance)")
            XCTAssertGreaterThanOrEqual(newRatio, 3, "the underline on the page, \(appearance)")
        }
    }
}
