import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// The Footnote card on Now (#3777, Design PR 5) keeps its height inside a budget that leaves room for the title, the
/// transport and the Auto-play row below it, whatever the note's length and the text size. A note of any length shows
/// at most six lines of its words (four at the accessibility sizes), so the card's height is bounded by that cap, not by
/// the note.
///
/// The card is drawn with no model at the phone's 393 pt width, as `PinnedMarginCardLayoutTests` draws the Margin card,
/// and gets the same budgets: it sits in the same slot. The test runs in a simulator only.
@MainActor
final class FootnoteCardLayoutTests: XCTestCase {
    private static let width: CGFloat = 393
    private static let budgets: [(size: DynamicTypeSize, label: String, maxHeight: CGFloat)] = [
        (.large, "large", 200),
        (.accessibility3, "accessibility3", 430),
    ]

    private static func height(of card: FootnoteCard, reading: Bool, size: DynamicTypeSize) -> CGFloat {
        UIHostingController(rootView: FootnoteCardBody(card: card, reading: reading).environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: CGSize(width: width, height: 4_000)).height
    }

    func testALongNoteStaysInsideTheBudgetAndAShortOneIsShorter() {
        let long = FootnoteCard(
            label: "note-1", body: String(repeating: "A long note about where the figure came from and who counted it. ", count: 40))
        let short = FootnoteCard(label: "3", body: "See the appendix.")
        for (size, label, maxHeight) in Self.budgets {
            for reading in [true, false] {
                let tall = Self.height(of: long, reading: reading, size: size)
                XCTAssertLessThanOrEqual(tall, maxHeight, "a long note at \(label), reading \(reading): \(tall) pt tall, budget \(maxHeight) pt")
                let small = Self.height(of: short, reading: reading, size: size)
                XCTAssertLessThan(small, tall, "a short note at \(label), reading \(reading) is no shorter than a six-line one")
                XCTAssertGreaterThan(small, 0, "a short note at \(label) drew nothing")
            }
        }
    }

    func testTheAccessibilitySizesCapTheNoteAtFourLines() {
        XCTAssertEqual(FootnoteCardBody.bodyLineLimit(for: .large), 6)
        XCTAssertEqual(FootnoteCardBody.bodyLineLimit(for: .xxxLarge), 6)
        XCTAssertEqual(FootnoteCardBody.bodyLineLimit(for: .accessibility1), 4)
        XCTAssertEqual(FootnoteCardBody.bodyLineLimit(for: .accessibility5), 4)
    }

    func testNotesPastSixLinesDrawTheSameCard() {
        // Both notes run well past six lines at 393 pt (about 55 characters a line): the cap is on lines, not on characters.
        let manyLines = FootnoteCard(label: "1", body: String(repeating: "word ", count: 400))
        let someLines = FootnoteCard(label: "1", body: String(repeating: "word ", count: 120))
        let a = Self.height(of: manyLines, reading: true, size: .large)
        let b = Self.height(of: someLines, reading: true, size: .large)
        XCTAssertEqual(a, b, accuracy: 1, "two notes past six lines should draw the same card")
    }
}
