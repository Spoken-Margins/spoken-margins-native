@testable import SessionKit
import XCTest

/// Where a table's or figure's card stands on the Now tab, from the caption line printed near it (#4588).
final class PDFClipAnchorsTests: XCTestCase {
    typealias Part = (id: String, role: StructuredDocument.Role, text: String)

    /// The document a layout makes: segments joined by a blank line, as the builder does.
    private struct Doc {
        let text: String
        let source: PDFClipSource?
        /// In Characters, as anchors are, not UTF-16 units.
        func offset(of phrase: String) -> Int {
            guard let range = text.range(of: phrase) else { return -1 }
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        func anchors() -> [PDFClipAnchor] { source.map { PDFClipAnchors.make(text: text, source: $0) } ?? [] }
    }

    private func float(_ id: String, _ kind: StructuredDocument.Float.Kind, own: String?, page: Int = 0, y: Double = 0.5,
                       caption: String? = nil, label: String? = nil, width: Double = 0.5, height: Double = 0.2) -> StructuredDocument.Float {
        .init(id: id, kind: kind, label: label, pageIndex: page, bounds: .init(x: 0.1, y: y, width: width, height: height),
              captionSegmentId: caption, textSegmentId: own)
    }

    private func doc(_ parts: [Part], floats: [StructuredDocument.Float]) -> Doc {
        var text = ""
        var segments: [StructuredDocument.Segment] = []
        for part in parts {
            if !text.isEmpty { text += "\n\n" }
            segments.append(.init(id: part.id, role: part.role, range: .init(start: text.count, length: part.text.count)))
            text += part.text
        }
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 3, textSHA256: nil),
            text: text, segments: segments, markers: [], floats: floats)
        return Doc(text: text, source: PDFClipSource(document: document, text: text))
    }

    private func only(_ anchors: [PDFClipAnchor], file: StaticString = #filePath, line: UInt = #line) throws -> PDFClipAnchor {
        XCTAssertEqual(anchors.count, 1, file: file, line: line)
        return try XCTUnwrap(anchors.first, file: file, line: line)
    }

    // MARK: Where the caption is

    func testAFigureCaptionAtTheStartOfTheSegmentAfterIsTheAnchor() throws {
        let d = doc([("a", .body, "Intro sentence."), ("fig", .figureText, "axis 0 1 2"),
                     ("b", .body, "Figure 3. Accuracy by model.\nMore body text.")], floats: [float("f1", .figure, own: "fig")])
        let anchor = try only(d.anchors())
        XCTAssertEqual(anchor.anchor, d.offset(of: "Figure 3. Accuracy"))
        XCTAssertEqual(anchor.numberLabel, "Figure 3")
        XCTAssertTrue(anchor.hasCaption)
        XCTAssertEqual(anchor.pageNumber, 1)
    }

    func testACaptionThreeLinesIntoAMergedBodySegmentIsFound() throws {
        let d = doc([("fig", .figureText, "axis"),
                     ("b", .body, "Figure 3 shows the results.\nSome other line.\nFigure 3. The real caption.\nAfter.")],
                    floats: [float("f1", .figure, own: "fig")])
        let anchor = try only(d.anchors())
        XCTAssertEqual(anchor.anchor, d.offset(of: "Figure 3. The real"), "the line that only mentions Figure 3 is not the caption")
    }

    func testACaptionJoinedToAnUnfinishedLineFromTheOtherColumnStartsAtItsOwnLine() throws {
        let d = doc([("fig", .figureText, "axis"), ("b", .body, "and the second column goes on to say\nFigure 2: Mean score per arm.")],
                    floats: [float("f1", .figure, own: "fig")])
        let anchor = try only(d.anchors())
        XCTAssertEqual(anchor.anchor, d.offset(of: "Figure 2: Mean"))
        XCTAssertGreaterThan(anchor.anchor, d.offset(of: "and the second"))
    }

    func testAFigureCaptionBeforeItsTextIsFoundWhenNothingFollows() throws {
        let d = doc([("b", .body, "Earlier text.\nFigure 4. Printed above the picture."), ("fig", .figureText, "axis")],
                    floats: [float("f1", .figure, own: "fig")])
        XCTAssertEqual(try only(d.anchors()).anchor, d.offset(of: "Figure 4. Printed"))
    }

    func testAFigureCaptionAfterWinsOverOneBefore() throws {
        let d = doc([("b", .body, "Figure 1. Belongs to the figure above."), ("fig", .figureText, "axis"),
                     ("c", .body, "Figure 2. Belongs to this one.")], floats: [float("f1", .figure, own: "fig")])
        XCTAssertEqual(try only(d.anchors()).numberLabel, "Figure 2")
    }

    func testATableCaptionIsTheLastLineBeforeTheTableOrTheFirstAfter() throws {
        let before = doc([("b", .body, "A paragraph.\nTable 2. Results by arm."), ("t", .table, "a 1 2\nb 3 4")],
                         floats: [float("t1", .table, own: "t")])
        let anchorBefore = try only(before.anchors())
        XCTAssertEqual(anchorBefore.anchor, before.offset(of: "Table 2. Results"))
        XCTAssertEqual(anchorBefore.numberLabel, "Table 2")

        let after = doc([("t", .table, "a 1 2\nb 3 4"), ("b", .body, "Table 5: Printed under it.\nThen text.")],
                        floats: [float("t1", .table, own: "t")])
        XCTAssertEqual(try only(after.anchors()).anchor, after.offset(of: "Table 5: Printed"))

        let both = doc([("b", .body, "Table 1. Above."), ("t", .table, "a 1"), ("c", .body, "Table 2. Below.")],
                       floats: [float("t1", .table, own: "t")])
        XCTAssertEqual(try only(both.anchors()).numberLabel, "Table 1", "a table looks before it first")
    }

    func testWithoutACaptionTheCardStandsAtTheFloatsOwnText() throws {
        let d = doc([("a", .body, "Just prose."), ("t", .table, "a 1 2\nb 3 4"), ("b", .body, "More prose here.")],
                    floats: [float("t1", .table, own: "t")])
        let anchor = try only(d.anchors())
        XCTAssertEqual(anchor.anchor, d.offset(of: "a 1 2"))
        XCTAssertEqual(anchor.numberLabel, "Table")
        XCTAssertFalse(anchor.hasCaption)
    }

    func testACaptionOfTheOtherKindOrTooFarAwayIsNotTheCaption() throws {
        let other = doc([("fig", .figureText, "axis"), ("b", .body, "Table 2. Not a figure caption.")],
                        floats: [float("f1", .figure, own: "fig")])
        XCTAssertFalse(try only(other.anchors()).hasCaption)

        let far = (1...7).map { "filler line \($0)" }.joined(separator: "\n") + "\nFigure 9. Too far down."
        let tooFar = doc([("fig", .figureText, "axis"), ("b", .body, far)], floats: [float("f1", .figure, own: "fig")])
        XCTAssertFalse(try only(tooFar.anchors()).hasCaption)

        let near = (1...5).map { "filler line \($0)" }.joined(separator: "\n") + "\nFigure 9. Sixth line."
        let sixth = doc([("fig", .figureText, "axis"), ("b", .body, near)], floats: [float("f1", .figure, own: "fig")])
        XCTAssertTrue(try only(sixth.anchors()).hasCaption)
    }

    func testAPageFooterBetweenTheCaptionAndTheFloatIsSteppedOver() throws {
        let d = doc([("fig", .figureText, "axis"), ("foot", .pageFooter, "Journal 2026 · 4"), ("b", .body, "Figure 6. Across a page break.")],
                    floats: [float("f1", .figure, own: "fig")])
        XCTAssertEqual(try only(d.anchors()).numberLabel, "Figure 6")
    }

    func testTwoSegmentsWantingOneCaptionTheNearerKeepsIt() throws {
        let d = doc([("figA", .figureText, "axis a"), ("figB", .figureText, "axis b"), ("b", .body, "Figure 7. One caption.")],
                    floats: [float("a", .figure, own: "figA"), float("b", .figure, own: "figB")])
        let anchors = d.anchors()
        XCTAssertEqual(anchors.count, 2)
        let a = try XCTUnwrap(anchors.first { $0.floatId == "a" }), b = try XCTUnwrap(anchors.first { $0.floatId == "b" })
        XCTAssertTrue(b.hasCaption)
        XCTAssertEqual(b.anchor, d.offset(of: "Figure 7."))
        XCTAssertFalse(a.hasCaption)
        XCTAssertEqual(a.anchor, d.offset(of: "axis a"))
    }

    func testATableSplitOverTwoPagesShowsBothPartsTogetherInPageOrder() {
        let d = doc([("b", .body, "Table 3. Long table."), ("t", .table, "r1\nr2\nr3")],
                    floats: [float("second", .table, own: "t", page: 1, y: 0.6), float("first", .table, own: "t", page: 0, y: 0.3)])
        let anchors = d.anchors()
        XCTAssertEqual(anchors.map(\.floatId), ["first", "second"])
        XCTAssertEqual(Set(anchors.map(\.anchor)), [d.offset(of: "Table 3. Long")])
        XCTAssertEqual(anchors.map(\.pageNumber), [1, 2])
    }

    func testCardsOnOnePageStandHighestFirstThenByFloatId() {
        let d = doc([("b", .body, "Table 1. Both."), ("t", .table, "r1\nr2")],
                    floats: [float("z", .table, own: "t", y: 0.2), float("a", .table, own: "t", y: 0.2), float("m", .table, own: "t", y: 0.7)])
        XCTAssertEqual(d.anchors().map(\.floatId), ["m", "a", "z"])
    }

    func testAPictureOnlyFigureFindsItsCaptionFromTheNumberInItsLabel() throws {
        let d = doc([("b", .body, "Figure 2. Another one.\nFigure 3. The one we want.\nFigure 4. Next.")],
                    floats: [float("f", .figure, own: nil, caption: "b", label: "Figure 3")])
        let anchor = try only(d.anchors())
        XCTAssertEqual(anchor.anchor, d.offset(of: "Figure 3. The one"))
        let missing = doc([("b", .body, "Figure 2. Only this.")], floats: [float("f", .figure, own: nil, caption: "b", label: "Figure 9")])
        XCTAssertTrue(missing.anchors().isEmpty, "no caption line with that number and no text of its own: no card")
        let unlabelled = doc([("b", .body, "Figure 2. Only this.")], floats: [float("f", .figure, own: nil, caption: "b", label: nil)])
        XCTAssertTrue(unlabelled.anchors().isEmpty)
    }

    func testTheLoserOfASharedCaptionTakesTheCaptionOnItsOtherSide() throws {
        let d = doc([("b1", .body, "Table 1. First."), ("t1", .table, "a 1\nb 2"), ("t2", .table, "c 3\nd 4"), ("b2", .body, "Table 2. Second.")],
                    floats: [float("one", .table, own: "t1"), float("two", .table, own: "t2")])
        let anchors = d.anchors()
        XCTAssertEqual(anchors.map(\.numberLabel), ["Table 1", "Table 2"])
        XCTAssertEqual(anchors.map(\.anchor), [d.offset(of: "Table 1."), d.offset(of: "Table 2.")])
        let figures = doc([("fa", .figureText, "axis a"), ("b1", .body, "Figure 1. First."), ("fb", .figureText, "axis b"), ("b2", .body, "Figure 2. Second.")],
                          floats: [float("a", .figure, own: "fa"), float("b", .figure, own: "fb")])
        XCTAssertEqual(figures.anchors().map(\.numberLabel), ["Figure 1", "Figure 2"])
    }

    func testLinesBrokenByCarriageReturnAndLineFeedAreLines() throws {
        let d = doc([("fig", .figureText, "axis"), ("b", .body, "Intro line\r\nFigure 3. Caption here.\r\nMore.")],
                    floats: [float("f1", .figure, own: "fig")])
        let anchor = try only(d.anchors())
        XCTAssertTrue(anchor.hasCaption)
        XCTAssertEqual(anchor.anchor, d.offset(of: "Figure 3. Caption"))
        let table = doc([("b", .body, "Para\r\nTable 2. Results"), ("t", .table, "a 1\nb 2")], floats: [float("t1", .table, own: "t")])
        XCTAssertEqual(try only(table.anchors()).numberLabel, "Table 2")
    }

    func testOffsetsAreCharactersWhateverComesBeforeTheCaption() throws {
        let before = "Café 🇫🇷 👨‍👩‍👧 e\u{301} text."
        let d = doc([("a", .body, before), ("fig", .figureText, "axis"), ("b", .body, "Figure 3. Done.")], floats: [float("f1", .figure, own: "fig")])
        let anchor = try only(d.anchors())
        XCTAssertEqual(anchor.anchor, d.text.distance(from: d.text.startIndex, to: d.text.range(of: "Figure 3.")!.lowerBound))
        XCTAssertNotEqual(anchor.anchor, (d.text as NSString).range(of: "Figure 3.").location, "UTF-16 and Character offsets differ here")
    }

    func testPictureOnlyFiguresInOneHugeSegmentAreFoundWithoutRescanningPerFigure() throws {
        let filler = (1...30_000).map { "Line \($0) of ordinary body text that runs on." }.joined(separator: "\n")
        var captions = ""
        for index in 1...80 { captions += "Figure \(index). Caption \(index).\n" }
        let floats = (1...80).reversed().map { float("f\($0)", .figure, own: nil, caption: "b", label: "Figure \($0)") }
        let d = doc([("b", .body, filler + "\n" + captions)], floats: floats)
        XCTAssertGreaterThan(d.text.count, 1_000_000)
        let start = Date()
        let anchors = d.anchors()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(anchors.count, 80)
        XCTAssertEqual(anchors.first?.numberLabel, "Figure 1")
    }

    func testNoFloatsOrADifferentTextGivesNoSource() {
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: "Hello.", segments: [.init(id: "a", role: .body, range: .init(start: 0, length: 6))], markers: [])
        XCTAssertNil(PDFClipSource(document: document, text: "Hello."))
        var withFloat = document
        withFloat.floats = [float("f", .table, own: "a")]
        XCTAssertNotNil(PDFClipSource(document: withFloat, text: "Hello."))
        XCTAssertNil(PDFClipSource(document: withFloat, text: "Hello!"), "the item's text is not the document's")
    }

    func testTheCardsAspectComesFromTheFloatsBoundsAndAThreeByFourPage() throws {
        let d = doc([("t", .table, "r1\nr2")], floats: [float("t1", .table, own: "t", width: 0.6, height: 0.3)])
        XCTAssertEqual(try only(d.anchors()).aspect, 0.6 * 0.75 / 0.3, accuracy: 1e-9)
    }

    // MARK: Caption wording

    func testCaptionWordingTable() {
        let figures: [(String, String?)] = [
            ("Figure 3. Accuracy", "3"), ("Fig. 3 (a) left", "3"), ("FIGURE 2", "2"), ("Figure S1. Extra", "S1"), ("Fig 4: x", "4"),
            ("Figure 3 shows the results.", nil), ("as in Figure 3.", nil), ("Figures 3 and 4", nil), ("", nil), ("Fig", nil),
        ]
        for (line, number) in figures {
            XCTAssertEqual(PDFCaptionPattern.number(of: line, kind: .figure), number, "figure: \(line)")
            XCTAssertEqual(PDFCaptionPattern.isCaption(line, kind: .figure), number != nil, "figure: \(line)")
        }
        let tables: [(String, String?)] = [
            ("Table 2. Results", "2"), ("TABLE 2", "2"), ("Table IV. Costs", "IV"), ("Table 2.", "2"), ("Table S3: x", "S3"),
            ("Table 2| Outcomes", "2"), ("Table 2 | spaced bar", nil), ("Table 2 shows the results.", nil), ("Tables 2 and 3", nil), ("table 2. lower", nil), ("", nil),
        ]
        for (line, number) in tables {
            XCTAssertEqual(PDFCaptionPattern.number(of: line, kind: .table), number, "table: \(line)")
            XCTAssertEqual(PDFCaptionPattern.isCaption(line, kind: .table), number != nil, "table: \(line)")
        }
        XCTAssertFalse(PDFCaptionPattern.isCaption(String(repeating: "Table ", count: 5_000), kind: .table))
    }

    func testTheLabelAndHintAreTheWordsOnBothTabs() throws {
        let d = doc([("t", .table, "r1\nr2")], floats: [float("t1", .table, own: "t", page: 6)])
        let anchor = try only(d.anchors())
        XCTAssertEqual(PDFClipLabel.accessibilityLabel(anchor), "Table, page 7")
        XCTAssertEqual(PDFClipLabel.hint(for: .table), "Opens the table full screen. Playback doesn't change.")
        XCTAssertEqual(PDFClipLabel.hint(for: .figure), "Opens the figure full screen. Playback doesn't change.")
    }

    // MARK: A long source

    func testFortyFloatsInAMillionCharactersAreAnchoredQuickly() throws {
        var parts: [Part] = []
        var floats: [StructuredDocument.Float] = []
        let paragraph = (1...600).map { "Line \($0) of ordinary body text that runs on." }.joined(separator: "\n")
        for index in 1...40 {
            parts.append(("body\(index)", .body, paragraph + "\nTable \(index). Caption \(index)."))
            parts.append(("table\(index)", .table, "a 1\nb 2"))
            floats.append(float("float\(index)", .table, own: "table\(index)", page: index % 3))
        }
        let d = doc(parts, floats: floats)
        XCTAssertGreaterThan(d.text.count, 1_000_000)
        let start = Date()
        let anchors = d.anchors()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(anchors.count, 40)
        XCTAssertTrue(anchors.allSatisfy(\.hasCaption))
        XCTAssertEqual(anchors.map(\.anchor), anchors.map(\.anchor).sorted())
        XCTAssertEqual(anchors[39].numberLabel, "Table 40")
    }
}
