import XCTest
@testable import SessionKit

final class FindInTextPresentationTests: XCTestCase {
    private func match(excerpt: String = "see the cat sat", s: Int = 8, e: Int = 11, before: Bool = false, after: Bool = false,
                       title: String? = "Methods", span: ItemTextSearch.SkippedSpan? = nil) -> ItemTextSearch.Match {
        ItemTextSearch.Match(start: 100, end: 103, excerpt: excerpt, excerptMatchStart: s, excerptMatchEnd: e,
                             excerptTruncatedBefore: before, excerptTruncatedAfter: after,
                             chapterId: nil, chapterTitle: title, notReadAloud: span)
    }

    func testButtonStateTable() {
        XCTAssertEqual(FindInTextPresentation.buttonState(isRecordedAudio: true, text: ""), .hidden)
        XCTAssertEqual(FindInTextPresentation.buttonState(isRecordedAudio: true, text: "transcript"), .hidden)
        XCTAssertEqual(FindInTextPresentation.buttonState(isRecordedAudio: false, text: ""), .preparing)
        XCTAssertEqual(FindInTextPresentation.buttonState(isRecordedAudio: false, text: "x"), .available)
    }

    func testCapTextOnlyWhenMoreThanTheCap() {
        let some = ItemTextSearch.Result(matches: [], hasMore: false)
        let more = ItemTextSearch.Result(matches: [], hasMore: true)
        XCTAssertNil(FindInTextPresentation.capText(for: some))
        XCTAssertEqual(FindInTextPresentation.capText(for: more), "Showing the first 100")
    }

    func testEmptyTextTable() {
        let none = ItemTextSearch.Result(matches: [], hasMore: false)
        let one = ItemTextSearch.Result(matches: [match()], hasMore: false)
        XCTAssertNil(FindInTextPresentation.emptyText(query: "", result: none))
        XCTAssertNil(FindInTextPresentation.emptyText(query: "  \n", result: none))
        XCTAssertEqual(FindInTextPresentation.emptyText(query: "zzz", result: none), "No matches in this text")
        XCTAssertNil(FindInTextPresentation.emptyText(query: "cat", result: one))
    }

    func testExcerptRunsTable() {
        XCTAssertEqual(FindInTextPresentation.excerptRuns(for: match()),
                       .init(before: "see the ", match: "cat", after: " sat"))
        XCTAssertEqual(FindInTextPresentation.excerptRuns(for: match(before: true, after: true)),
                       .init(before: "\u{2026}see the ", match: "cat", after: " sat\u{2026}"))
        XCTAssertEqual(FindInTextPresentation.excerptRuns(for: match(s: -4, e: 999)),
                       .init(before: "", match: "see the cat sat", after: ""))
        XCTAssertEqual(FindInTextPresentation.excerptRuns(for: match(excerpt: "", s: 0, e: 0)),
                       .init(before: "", match: "", after: ""))
        XCTAssertEqual(FindInTextPresentation.excerptRuns(for: match(excerpt: "\u{1F600}e\u{0301}cat", s: 2, e: 5)),
                       .init(before: "\u{1F600}e\u{0301}", match: "cat", after: ""))
    }

    func testHeadingTable() {
        XCTAssertEqual(FindInTextPresentation.heading(for: match(title: " Methods ")), "Methods")
        XCTAssertNil(FindInTextPresentation.heading(for: match(title: nil)))
        XCTAssertNil(FindInTextPresentation.heading(for: match(title: "  ")))
    }

    func testAccessibilityLabelTable() {
        XCTAssertEqual(FindInTextPresentation.accessibilityLabel(for: match()),
                       "Methods, see the cat sat, double-tap to play from here")
        XCTAssertEqual(FindInTextPresentation.accessibilityLabel(for: match(title: nil)),
                       "see the cat sat, double-tap to play from here")
        let table = ItemTextSearch.SkippedSpan(kind: .table, start: 90, end: 120, label: "Table 2")
        XCTAssertEqual(FindInTextPresentation.accessibilityLabel(for: match(span: table)),
                       "Methods, In Table 2 (not read aloud), see the cat sat, double-tap to play from here")
    }
}
