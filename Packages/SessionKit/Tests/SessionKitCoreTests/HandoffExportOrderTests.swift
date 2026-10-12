import Foundation
import XCTest
@testable import SessionKit

/// #1439: the AI Handoff export of the owner's test plan listed the Margin at 35% first and printed
/// the same source passages twice. Layer that should have caught it: a host test on the renderer with
/// a text item's Margins out of order and close together; its only sorting test was for media times.
final class HandoffExportOrderTests: XCTestCase {
    private let windowWords = 40
    private let words = (0..<600).map { String(format: "w%03d", $0) }

    private func margin(
        _ id: String, percent: Int, at start: Int, mediaTimeMs: Int? = nil, text: String? = nil
    ) -> ExportInterjection {
        ExportInterjection(
            id: id, sessionId: "s", targetType: "item", targetId: "item", roughPercent: percent,
            anchorBefore: words[max(0, start - windowWords)..<start].joined(separator: " "),
            anchorAfter: words[(start + 3)..<(start + 3 + windowWords)].joined(separator: " "),
            mediaTimeMs: mediaTimeMs, transcriptionStatus: "transcribed", transcript: text ?? "note-\(id)",
            audioPath: nil, captureKind: .written, sourceCharOffset: start * 5
        )
    }

    private func render(_ margins: [ExportInterjection], timeline order: [String]) -> String {
        let export = SessionExport(
            item: ExportItem(id: "item", title: "Plan", externalReference: nil, sourceURL: nil, mediaSourceType: nil,
                             includedFullText: false, text: nil),
            session: ExportSession(id: "s", status: "in_progress", completionPercent: 40),
            listeningMap: nil, turns: [],
            timeline: order.map {
                ExportTimelineEntry(type: "interjection", interjectionId: $0, turnId: nil, targetType: "item",
                                    targetId: "item", percent: nil, chapterId: nil)
            },
            interjections: margins
        )
        return SessionExportMarkdownRenderer.render(export)
    }

    private func markerOrder(_ markdown: String) -> [String] {
        markdown.split(separator: "\n").compactMap { $0.hasPrefix("note-") ? String($0.dropFirst(5)) : nil }
    }

    func testTextMarginsComeOutInSourceOrderWithNoPassageTwice() {
        let margins = [
            margin("07", percent: 7, at: 42), margin("12", percent: 12, at: 72),
            margin("17a", percent: 17, at: 102), margin("17b", percent: 17, at: 104),
            margin("17c", percent: 17, at: 110), margin("35", percent: 35, at: 210)
        ]
        // The 35% Margin was made first, and the 17% ones out of order.
        let markdown = render(margins, timeline: ["35", "17c", "07", "17a", "12", "17b"])

        XCTAssertEqual(markerOrder(markdown), ["07", "12", "17a", "17b", "17c", "35"])
        let repeated = Dictionary(grouping: markdown.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("w") }, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [], "source words printed more than once")
        XCTAssertTrue(markdown.contains("w002"), "the first Margin keeps its context")
        XCTAssertTrue(markdown.contains("w152"), "the last Margin's context after it is kept")
    }

    func testAMarginWithoutAMediaTimeDoesNotJumpToTheStart() {
        let margins = [
            margin("a", percent: 10, at: 60, mediaTimeMs: 61_000),
            margin("b", percent: 20, at: 200),
            margin("c", percent: 30, at: 340, mediaTimeMs: 341_000)
        ]
        XCTAssertEqual(markerOrder(render(margins, timeline: ["c", "b", "a"])), ["a", "b", "c"])
    }

    func testPodcastMarginsKeepSortingByMediaTime() {
        // Percent is coarse and can disagree with the clock; the clock decides.
        let margins = [
            margin("late", percent: 50, at: 300, mediaTimeMs: 900_000),
            margin("early", percent: 51, at: 100, mediaTimeMs: 100_000),
            margin("middle", percent: 50, at: 200, mediaTimeMs: 500_000)
        ]
        XCTAssertEqual(markerOrder(render(margins, timeline: ["late", "early", "middle"])), ["early", "middle", "late"])
    }

    func testTheFallbackWithoutATimelineAlsoGoesInSourceOrder() {
        let margins = [margin("b", percent: 30, at: 180), margin("a", percent: 10, at: 60)]
        XCTAssertEqual(markerOrder(render(margins, timeline: [])), ["a", "b"])
    }

    func testMarginsFarApartKeepTheirOwnContext() {
        let markdown = render(
            [margin("a", percent: 10, at: 60), margin("b", percent: 60, at: 400)], timeline: ["a", "b"]
        )
        XCTAssertTrue(markdown.contains("Later source context:\nw360"), markdown)
        XCTAssertTrue(markdown.contains("Source continues:\nw063"), markdown)
    }

    // MARK: context passages (review findings)

    private func custom(
        _ id: String, percent: Int, before: String, after: String
    ) -> ExportInterjection {
        ExportInterjection(
            id: id, sessionId: "s", targetType: "item", targetId: "item", roughPercent: percent,
            anchorBefore: before, anchorAfter: after, mediaTimeMs: nil, transcriptionStatus: "transcribed",
            transcript: "note-\(id)", audioPath: nil, captureKind: .written, sourceCharOffset: percent * 100
        )
    }

    func testContextKeepsItsLineBreaks() {
        let before = "- item one\n- item two\n\nA second paragraph of the source."
        let markdown = render([custom("a", percent: 10, before: before, after: "After one.\n\nAfter two.")], timeline: ["a"])
        XCTAssertTrue(markdown.contains(before), markdown)
        XCTAssertTrue(markdown.contains("After one.\n\nAfter two."), markdown)
    }

    func testMarginsFarApartKeepTheirContextWhenAPhraseRepeats() {
        let markdown = render([
            custom("a", percent: 10, before: "Opening words of the early part.", after: "we stopped at the end of the day and went home"),
            custom("b", percent: 60, before: "Quite different words lead into the later part.", after: "at the end of the road the story turns")
        ], timeline: ["a", "b"])
        XCTAssertTrue(markdown.contains("went home"), "the first Margin keeps what comes after it")
        XCTAssertTrue(markdown.contains("Quite different words lead into the later part."), "the second keeps what comes before it")
    }

    func testARefrainThatRepeatsInTheSourceIsPrintedEachTime() {
        let refrain = "Thanks so much for listening everyone."
        let markdown = render([
            custom("a", percent: 10, before: "Start of the show.", after: "Next up is a sponsor. \(refrain)"),
            custom("b", percent: 60, before: "Much later in the show. \(refrain)", after: "End.")
        ], timeline: ["a", "b"])
        XCTAssertEqual(markdown.components(separatedBy: refrain).count - 1, 2, markdown)
    }

    func testTheWordsBetweenTwoCloseMarginsAreKept() {
        let markdown = render(
            [margin("a", percent: 10, at: 10), margin("b", percent: 10, at: 12)], timeline: ["a", "b"]
        )
        XCTAssertTrue(markdown.contains("w013 w014"), markdown)
        let repeated = Dictionary(grouping: markdown.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("w") }, by: { $0 })
            .filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [])
    }
}
