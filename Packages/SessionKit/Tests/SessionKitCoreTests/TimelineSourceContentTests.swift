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

    /// A table's printed text names its float, so the row can show the picture cut from the page (#3895). The caption,
    /// which only labels the float, does not: one picture per table, on the row that is the table.
    func testOnlyTheSegmentThatHoldsAFloatsTextNamesTheFloat() {
        let text = "Intro\n\nTable 1. Recall\n\nGroup | Mean\n\nFigure 2 words\n\nAfter"
        let parts: [(String, StructuredDocument.Role, String?)] = [
            ("Intro", .body, nil), ("Table 1. Recall", .caption, nil), ("Group | Mean", .table, "float-p1-1"),
            ("Figure 2 words", .figureText, "float-p2-1"), ("After", .body, nil),
        ]
        var start = 0
        var segments: [StructuredDocument.Segment] = []
        for (index, part) in parts.enumerated() {
            segments.append(.init(id: "s\(index)", role: part.1, range: .init(start: start, length: part.0.count),
                                  pageIndex: index == 3 ? 1 : 0, floatId: part.2))
            start += part.0.count + 2
        }
        var document = document(text, segments: segments)
        document.floats = [
            .init(id: "float-p1-1", kind: .table, label: "Table 1", pageIndex: 0,
                  bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2), captionSegmentId: "s1", textSegmentId: "s2"),
            .init(id: "float-p2-1", kind: .figure, label: "Figure 2", pageIndex: 1,
                  bounds: .init(x: 0.1, y: 0.4, width: 0.5, height: 0.2), captionSegmentId: nil, textSegmentId: "s3"),
        ]

        let entries = TimelineSourceContent(text: text, document: document).entries

        XCTAssertEqual(entries.map(\.floatId), [nil, nil, "float-p1-1", "float-p2-1", nil])
        XCTAssertEqual(entries.map(\.floatKind), [nil, nil, .table, .figure, nil])
        XCTAssertEqual(entries[1].label, "Table 1", "the caption still carries the label, and no picture")
    }

    func testABodySegmentNamedByAPictureOnlyFiguresCaptionFloatKeepsNoLabel() {
        // A picture-only figure's caption is a line inside a body segment (#4587). The float names that segment, but
        // Now draws an entry's label above its fragments, so the body text around the caption must not read "Figure 3".
        let text = "Intro\n\nFigure 3. Cells.\nMore body text.\n\nFigure 4. A caption segment.\n\nAfter"
        let parts: [(String, StructuredDocument.Role)] = [
            ("Intro", .body), ("Figure 3. Cells.\nMore body text.", .body), ("Figure 4. A caption segment.", .caption), ("After", .body),
        ]
        var start = 0
        var segments: [StructuredDocument.Segment] = []
        for (index, part) in parts.enumerated() {
            segments.append(.init(id: "s\(index)", role: part.1, range: .init(start: start, length: part.0.count), pageIndex: 0))
            start += part.0.count + 2
        }
        var document = document(text, segments: segments)
        document.floats = [
            .init(id: "float-p1-c1", kind: .figure, label: "Figure 3", pageIndex: 0,
                  bounds: .init(x: 0.1, y: 0.4, width: 0.5, height: 0.2), captionSegmentId: "s1", textSegmentId: nil),
            .init(id: "float-p1-c2", kind: .figure, label: "Figure 4", pageIndex: 0,
                  bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2), captionSegmentId: "s2", textSegmentId: nil),
        ]

        let entries = TimelineSourceContent(text: text, document: document).entries

        XCTAssertEqual(entries.map(\.label), [nil, nil, "Figure 4", nil], "a .caption segment still gets its float's label")
        XCTAssertEqual(entries.map(\.floatId), [nil, nil, nil, nil], "neither is the float's own text")
    }

    func testASegmentNamingAFloatTheDocumentLacksHasNoPicture() {
        let text = "Cell A | Cell B"
        let segment = StructuredDocument.Segment(id: "s0", role: .table, range: .init(start: 0, length: text.count), floatId: "gone")
        let entries = TimelineSourceContent(text: text, document: document(text, segments: [segment])).entries
        XCTAssertEqual(entries.map(\.floatId), [nil])
    }

    func testPlainTextHasNoFloats() {
        XCTAssertEqual(TimelineSourceContent(text: "A\n\nB").entries.map(\.floatId), [nil, nil])
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

    func testWhitespaceOnlyBlankLinesSeparatePassagesWithoutChangingSourceCoordinates() {
        let separators = ["\n\n", "\n \n", "\n\t\n", "\n \t\n\t\n", "\r\n \r\n", "\r\n\t\r\n", "\u{2028} \u{2028}"]
        let firstPassages = ["First!", "é🙂", "e\u{301}🙂", "  Authored indentation", String(repeating: "Long text. ", count: 2_000)]
        let second = "  Second passage."
        for first in firstPassages {
            for separator in separators {
                let text = first + separator + second
                let content = TimelineSourceContent(text: text)
                let secondStart = (first + separator).count
                XCTAssertEqual(content.entries.map(\.text), [first, second], separator.debugDescription)
                XCTAssertEqual(content.entries.map(\.start), [0, secondStart], separator.debugDescription)
                XCTAssertEqual(content.characterCount, text.count)
                XCTAssertEqual(content.entry(atCharacter: secondStart)?.text, second)
                XCTAssertEqual(content.entry(atCharacter: secondStart - 1)?.text, first)
            }
        }
        for text in ["First\n  soft wrap", "First\r\n\tsoft wrap", "First\n \t"] {
            XCTAssertEqual(TimelineSourceContent(text: text).entries.map(\.text), [text])
        }
        for text in ["", " \n\t\n  ", "\r\n \r\n\t"] {
            XCTAssertTrue(TimelineSourceContent(text: text).entries.isEmpty)
        }
    }

    func testDuplicateSegmentIDsRemainDistinctAtSeparateSourcePositions() {
        let text = "A long source"
        let segments: [StructuredDocument.Segment] = [
            .init(id: "same", role: .caption, range: .init(start: 0, length: 1)),
            .init(id: "same", role: .figureText, range: .init(start: 2, length: 4))
        ]
        let entries = TimelineSourceContent(text: text, document: document(text, segments: segments)).entries
        XCTAssertEqual(entries.map(\.role), [.caption, .figureText, .body])
        XCTAssertEqual(entries.map(\.text), ["A", "long", " source"])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
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
