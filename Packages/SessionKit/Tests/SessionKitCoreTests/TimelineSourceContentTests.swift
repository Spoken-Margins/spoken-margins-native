import XCTest
@testable import SessionKit

final class TimelineSourceContentTests: XCTestCase {
    func testRetainsAuthoredRolesAndLabelsInSourceOrder() {
        let text = "Title\n\nFigure caption\n\nCell A | Cell B\n\nA footnote"
        let starts = [0, 7, 23, 40]
        let segments = zip(["Title", "Figure caption", "Cell A | Cell B", "A footnote"],
                           zip(starts, [StructuredDocument.Role.title, .caption, .table, .footnote]))
            .enumerated().map { index, value in
                StructuredDocument.Segment(id: "s\(index)", role: value.1.1,
                    range: .init(start: value.1.0, length: value.0.count), pageIndex: index)
            }
        var document = document(text, segments: Array(segments.reversed()))
        document.floats = [.init(id: "figure", kind: .figure, label: "Fig. 1 — Original label",
            pageIndex: 1, bounds: .init(x: 0, y: 0, width: 1, height: 1), captionSegmentId: "s1")]
        let content = TimelineSourceContent(text: text, document: document)
        XCTAssertEqual(content.entries.map(\.start), starts)
        XCTAssertEqual(content.entries.map(\.text), ["Title", "Figure caption", "Cell A | Cell B", "A footnote"])
        XCTAssertEqual(content.entries.map(\.role), [.title, .caption, .table, .footnote])
        XCTAssertEqual(content.entries.dropFirst().first?.label, "Fig. 1 — Original label")
        XCTAssertEqual(content.entries.map(\.pageIndex), [0, 1, 2, 3])
    }

    func testPlainTextKeepsUnicodeAndExactParagraphPositions() {
        for text in ["é🙂\n\nSecond", "e\u{301}🙂\n\nSecond", "First\r\n\r\nSecond", "  First  \n\nSecond", "A\nB\n\nC"] {
            let content = TimelineSourceContent(text: text)
            XCTAssertEqual(content.entries.count, 2, text)
            XCTAssertEqual(content.characterCount, text.count)
            for entry in content.entries {
                let start = text.index(text.startIndex, offsetBy: entry.start)
                XCTAssertTrue(text[start...].hasPrefix(entry.text))
            }
            XCTAssertEqual(Set(content.entries.map(\.id)).count, content.entries.count)
        }
        XCTAssertTrue(TimelineSourceContent(text: " \n\n\t").entries.isEmpty)
        XCTAssertTrue(TimelineSourceContent(text: "").entries.isEmpty)
    }

    func testStaleOrInvalidDocumentFallsBackWithoutLosingTheSource() {
        let text = "Current source"
        let valid = StructuredDocument.Segment(id: "s", role: .caption, range: .init(start: 0, length: text.count))
        for range in [StructuredDocument.TextRange(start: -1, length: 2), .init(start: 0, length: Int.max),
                      .init(start: 100, length: 1), .init(start: 1, length: -1)] {
            var segment = valid; segment.range = range
            let content = TimelineSourceContent(text: text, document: document(text, segments: [segment]))
            XCTAssertEqual(content.entries.map(\.text), [text])
            XCTAssertEqual(content.entries.map(\.role), [.body])
        }
        XCTAssertEqual(TimelineSourceContent(text: text, document: document("Old source", segments: [valid])).entries.map(\.text), [text])
    }

    func testDuplicateSegmentIDsRemainDistinctAndEqualPositionsKeepInputOrder() {
        let text = "A long source"
        let segments: [StructuredDocument.Segment] = [
            .init(id: "same", role: .caption, range: .init(start: 0, length: 1)),
            .init(id: "same", role: .figureText, range: .init(start: 0, length: 1))
        ]
        let entries = TimelineSourceContent(text: text, document: document(text, segments: segments)).entries
        XCTAssertEqual(entries.map(\.role), [.caption, .figureText, .body])
        XCTAssertEqual(entries.last?.text, " long source")
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
    }

    func testSubpercentPositionsSortBeforeRankAndID() {
        let early = TimelineRailSortKey(position: 1, rank: 3, id: "z", precisePosition: 1.1)
        let later = TimelineRailSortKey(position: 1, rank: 0, id: "a", precisePosition: 1.2)
        XCTAssertEqual([later, early].sorted().map(\.id), ["z", "a"])
        XCTAssertEqual(TimelineRailSortKey.percent(position: 11, length: 1_000) ?? .nan, 1.1, accuracy: 1e-9)
        XCTAssertNil(TimelineRailSortKey.percent(position: -1, length: 1_000))
        XCTAssertNil(TimelineRailSortKey.percent(position: 1, length: 0))
        XCTAssertEqual(TimelineRailSortKey.percent(position: 101, length: 100), 100)
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(TimelineRailSortKey(position: 1, rank: 0, id: "a", precisePosition: value),
                           TimelineRailSortKey(position: 1, rank: 0, id: "a"))
        }
    }

    func testCurrentPassageUsesCharactersAndHandlesBoundaries() {
        let content = TimelineSourceContent(text: "🙂é\n\nSecond")
        XCTAssertEqual(content.entry(atCharacter: 0)?.text, "🙂é")
        XCTAssertEqual(content.entry(atCharacter: 3)?.text, "🙂é")
        XCTAssertEqual(content.entry(atCharacter: 4)?.text, "Second")
        XCTAssertEqual(content.entry(atCharacter: content.characterCount)?.text, "Second")
        XCTAssertNil(content.entry(atCharacter: -1))
        XCTAssertNil(content.entry(atCharacter: content.characterCount + 1))
    }

    private func document(_ text: String, segments: [StructuredDocument.Segment]) -> StructuredDocument {
        .init(extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 4, textSHA256: nil),
              text: text, segments: segments, markers: [])
    }
}
