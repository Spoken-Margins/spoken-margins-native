@testable import SessionKit
import XCTest

/// Which table and figure text on a PDF page becomes a clip, and which stays text (#3895).
final class PDFClipLocatorTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PDFNormalizedRect {
        PDFNormalizedRect(x: x, y: y, width: w, height: h)
    }

    private func line(segment: String = "s1", kind: StructuredDocument.Float.Kind = .table, page: Int = 0,
                      _ bounds: PDFNormalizedRect) -> PDFClipLocator.Line {
        .init(segmentId: segment, kind: kind, pageIndex: page, bounds: bounds)
    }

    func testTwoStackedTableRowsMakeOnePaddedClipOnThePage() throws {
        let floats = PDFClipLocator.floats(from: [
            line(rect(0.20, 0.60, 0.50, 0.02)),
            line(rect(0.20, 0.57, 0.50, 0.02)),
        ])

        let float = try XCTUnwrap(floats.first)
        XCTAssertEqual(floats.count, 1)
        XCTAssertEqual(float.kind, .table)
        XCTAssertEqual(float.textSegmentId, "s1")
        XCTAssertEqual(float.pageIndex, 0)
        XCTAssertEqual(float.id, "float-p1-1")
        XCTAssertEqual(float.bounds.x, 0.20 - PDFClipLocator.padding, accuracy: 1e-9)
        XCTAssertEqual(float.bounds.y, 0.57 - PDFClipLocator.padding, accuracy: 1e-9)
        XCTAssertEqual(float.bounds.width, 0.50 + 2 * PDFClipLocator.padding, accuracy: 1e-9)
        XCTAssertEqual(float.bounds.height, 0.05 + 2 * PDFClipLocator.padding, accuracy: 1e-9)
    }

    func testFigureTextBecomesAFigure() {
        let floats = PDFClipLocator.floats(from: [
            line(segment: "f", kind: .figure, rect(0.10, 0.50, 0.08, 0.02)),
            line(segment: "f", kind: .figure, rect(0.45, 0.40, 0.10, 0.02)),
            line(segment: "f", kind: .figure, rect(0.80, 0.30, 0.08, 0.02)),
        ])
        // The labels are 0.2 apart: three separate one-line clusters, so none is a reliable region.
        XCTAssertTrue(floats.isEmpty)

        let panel = PDFClipLocator.floats(from: [
            line(segment: "f", kind: .figure, rect(0.10, 0.50, 0.08, 0.02)),
            line(segment: "f", kind: .figure, rect(0.20, 0.48, 0.10, 0.02)),
            line(segment: "f", kind: .figure, rect(0.14, 0.44, 0.08, 0.02)),
        ])
        XCTAssertEqual(panel.map(\.kind), [.figure])
    }

    func testOneLineIsNotAClip() {
        XCTAssertTrue(PDFClipLocator.floats(from: [line(rect(0.2, 0.6, 0.5, 0.05))]).isEmpty)
    }

    func testFarApartClustersInOneSegmentAreTwoClips() {
        let floats = PDFClipLocator.floats(from: [
            line(rect(0.20, 0.80, 0.50, 0.02)), line(rect(0.20, 0.77, 0.50, 0.02)),
            line(rect(0.20, 0.30, 0.50, 0.02)), line(rect(0.20, 0.27, 0.50, 0.02)),
        ])

        XCTAssertEqual(floats.map(\.id), ["float-p1-1", "float-p1-2"])
        XCTAssertEqual(floats.map(\.textSegmentId), ["s1", "s1"])
    }

    func testChainedLinesAreOneClipEvenWhenTheEndsAreFarApart() {
        // Each is within the join distance of the next, so a tall table is one clip, not three.
        let floats = PDFClipLocator.floats(from: (0..<8).map { line(rect(0.2, 0.9 - Double($0) * 0.04, 0.5, 0.02)) })
        XCTAssertEqual(floats.count, 1)
    }

    func testNumbersRestartOnEachPage() {
        let floats = PDFClipLocator.floats(from: [
            line(page: 0, rect(0.2, 0.6, 0.5, 0.02)), line(page: 0, rect(0.2, 0.57, 0.5, 0.02)),
            line(page: 2, rect(0.2, 0.6, 0.5, 0.02)), line(page: 2, rect(0.2, 0.57, 0.5, 0.02)),
        ])

        XCTAssertEqual(floats.map(\.id), ["float-p1-1", "float-p3-1"])
        XCTAssertEqual(floats.map(\.pageIndex), [0, 2])
    }

    func testRegionsTooSmallOrWholePageGetNoClip() {
        XCTAssertTrue(PDFClipLocator.floats(from: [
            line(rect(0.2, 0.6, 0.03, 0.01)), line(rect(0.2, 0.59, 0.03, 0.01)),
        ]).isEmpty, "narrower than about 40 pt")
        XCTAssertTrue(PDFClipLocator.floats(from: [
            line(rect(0.2, 0.6, 0.5, 0.005)), line(rect(0.2, 0.595, 0.5, 0.005)),
        ]).isEmpty, "shorter than about 40 pt")
        XCTAssertTrue(PDFClipLocator.floats(from: [
            line(rect(0.02, 0.02, 0.96, 0.45)), line(rect(0.02, 0.49, 0.96, 0.49)),
        ]).isEmpty, "the whole page is not a table")
    }

    func testBadRectanglesAreIgnored() {
        let floats = PDFClipLocator.floats(from: [
            line(rect(.nan, 0.6, 0.5, 0.02)),
            line(rect(0.2, 0.6, 0, 0.02)),
            line(rect(1.4, 0.6, 0.5, 0.02)),
            line(rect(0.2, -0.5, 0.5, 0.02)),
            line(rect(0.2, 0.6, 0.5, 0.02)),
        ])
        XCTAssertTrue(floats.isEmpty, "only one usable line is left, and one line is not a clip")
    }

    func testARegionAtThePageEdgeStaysOnThePage() throws {
        let floats = PDFClipLocator.floats(from: [
            line(rect(0.0, 0.0, 0.40, 0.02)), line(rect(0.0, 0.03, 0.40, 0.02)),
        ])

        let float = try XCTUnwrap(floats.first)
        XCTAssertEqual(float.bounds.x, 0)
        XCTAssertEqual(float.bounds.y, 0)
        XCTAssertLessThanOrEqual(float.bounds.x + float.bounds.width, 1)
    }

    func testAtMostFortyClipsPerDocument() {
        var lines: [PDFClipLocator.Line] = []
        for page in 0..<50 {
            lines.append(line(page: page, rect(0.2, 0.6, 0.5, 0.02)))
            lines.append(line(page: page, rect(0.2, 0.57, 0.5, 0.02)))
        }
        let floats = PDFClipLocator.floats(from: lines)

        XCTAssertEqual(floats.count, PDFClipLocator.maximumFloatsPerDocument)
        XCTAssertEqual(floats.last?.pageIndex, 39, "the first forty in reading order")
    }

    func testOnlyTableAndFigureTextRolesGetAKind() {
        XCTAssertEqual(PDFClipLocator.kind(of: .table), .table)
        XCTAssertEqual(PDFClipLocator.kind(of: .figureText), .figure)
        for role in StructuredDocument.Role.allCases where role != .table && role != .figureText {
            XCTAssertNil(PDFClipLocator.kind(of: role), "\(role)")
        }
    }

    // MARK: The document builder

    func testBuilderFillsFloatsAndLinksTheirSegmentsOnlyForLinesThatHaveBounds() throws {
        let lines: [StructuredDocumentLine] = [
            .init(text: "Intro paragraph.", role: .body, pageIndex: 0),
            .init(text: "Cell A | Cell B", role: .table, pageIndex: 0, bounds: rect(0.2, 0.60, 0.5, 0.02)),
            .init(text: "1 | 2", role: .table, pageIndex: 0, bounds: rect(0.2, 0.57, 0.5, 0.02)),
            .init(text: "Closing.", role: .body, pageIndex: 0),
            .init(text: "unplaced | row", role: .table, pageIndex: 1),
        ]
        let document = StructuredDocumentBuilder.build(lines: lines, engine: "test", version: 1, pageCount: 2)

        XCTAssertEqual(document.floats.count, 1)
        let float = try XCTUnwrap(document.floats.first)
        let table = try XCTUnwrap(document.segments.first { $0.id == float.textSegmentId })
        XCTAssertEqual(table.role, .table)
        XCTAssertEqual(table.floatId, float.id)
        XCTAssertEqual(table.pageIndex, 0)
        let last = try XCTUnwrap(document.segments.last)
        XCTAssertEqual(last.role, .table)
        XCTAssertNil(last.floatId, "a table the extractor couldn't place has no clip")
    }

    func testBuilderWithNoBoundsAtAllMakesTheSameDocumentAsBefore() {
        let lines: [StructuredDocumentLine] = [
            .init(text: "Cell A | Cell B", role: .table, pageIndex: 0),
            .init(text: "1 | 2", role: .table, pageIndex: 0),
        ]
        let document = StructuredDocumentBuilder.build(lines: lines, engine: "test", version: 1, pageCount: 1)

        XCTAssertEqual(document.floats, [])
        XCTAssertNil(document.segments.first?.floatId)
    }

    func testATableOverAPageBreakKeepsOneClipPerPageUnderOneSegment() throws {
        let lines: [StructuredDocumentLine] = [
            .init(text: "r1", role: .table, pageIndex: 0, bounds: rect(0.2, 0.20, 0.5, 0.02)),
            .init(text: "r2", role: .table, pageIndex: 0, bounds: rect(0.2, 0.17, 0.5, 0.02)),
            .init(text: "r3", role: .table, pageIndex: 1, bounds: rect(0.2, 0.85, 0.5, 0.02)),
            .init(text: "r4", role: .table, pageIndex: 1, bounds: rect(0.2, 0.82, 0.5, 0.02)),
        ]
        let document = StructuredDocumentBuilder.build(lines: lines, engine: "test", version: 1, pageCount: 2)

        XCTAssertEqual(document.floats.map(\.pageIndex), [0, 1])
        XCTAssertEqual(Set(document.floats.compactMap(\.textSegmentId)).count, 1)
        XCTAssertEqual(document.segments.count, 1)
        XCTAssertEqual(document.segments.first?.floatId, document.floats.first?.id)
    }

    /// #4338: PDFs added before the original was kept have no source hash; the same words re-imported now carry one.
    func testReimportThatOnlyAddsASourceHashKeepsOneItemEvenWhileItIsOpenAndPlaying() throws {
        func document(sourceSHA256: String?) -> StructuredDocument {
            StructuredDocumentBuilder.build(lines: [
                .init(text: "Paper", role: .title, pageIndex: 0),
                .init(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            ], engine: "test", version: 2, pageCount: 1, sourceSHA256: sourceSHA256)
        }
        let legacy = document(sourceSHA256: nil), hashed = document(sourceSHA256: String(repeating: "ab", count: 32))
        XCTAssertEqual(legacy.text, hashed.text)
        XCTAssertNotEqual(legacy, hashed)
        XCTAssertEqual(legacy.comparedOnReimport, hashed.comparedOnReimport)
        // Another paper with the same hash field filled is still another paper.
        let other = StructuredDocumentBuilder.build(lines: [
            .init(text: "Paper", role: .title, pageIndex: 0),
            .init(text: "We measured sleep in children.", role: .body, pageIndex: 0),
        ], engine: "test", version: 2, pageCount: 1, sourceSHA256: String(repeating: "ab", count: 32))
        XCTAssertNotEqual(hashed.comparedOnReimport, other.comparedOnReimport)

        let repository = InMemorySessionRepository()
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile, source: .init(url: "shared-file://share-sheet/Paper.pdf", title: "Paper"),
            text: legacy.text, contentFormat: .plainText)
        let first = BrowserTextImporter(repository: repository, openItemIds: [], isPlaybackActive: false, publisherPlayback: [:])
        guard case .records(let item, _, _, _) = try first.outcomeAndPersist(handoff, structuredDocument: legacy, upgrade: .skip) else {
            return XCTFail("expected records")
        }
        let held = BrowserTextImporter(repository: repository, openItemIds: [item.id], isPlaybackActive: true, publisherPlayback: [:])
        guard case .records(let again, _, _, _) = try held.outcomeAndPersist(handoff, structuredDocument: hashed, upgrade: .skip) else {
            return XCTFail("expected records")
        }
        XCTAssertEqual(again.id, item.id, "no -edition- copy for the same words")
        XCTAssertEqual(try repository.listItems().count, 1)
        XCTAssertEqual(try repository.loadStructuredDocument(itemId: item.id), hashed, "the hash is saved")
    }

    func testReimportThatOnlyAddsClipRegionsKeepsOneItemEvenWhileItIsOpenAndPlaying() throws {
        func document(withBounds: Bool) -> StructuredDocument {
            StructuredDocumentBuilder.build(lines: [
                .init(text: "Paper", role: .title, pageIndex: 0),
                .init(text: "Cell A | Cell B", role: .table, pageIndex: 0, bounds: withBounds ? rect(0.2, 0.60, 0.5, 0.02) : nil),
                .init(text: "1 | 2", role: .table, pageIndex: 0, bounds: withBounds ? rect(0.2, 0.57, 0.5, 0.02) : nil),
                .init(text: "We measured sleep in adults.", role: .body, pageIndex: 0),
            ], engine: "test", version: 2, pageCount: 1)
        }
        let old = document(withBounds: false), placed = document(withBounds: true)
        XCTAssertEqual(old.text, placed.text)
        XCTAssertEqual(old.floats, [])
        XCTAssertFalse(placed.floats.isEmpty)
        XCTAssertEqual(old.withoutClipGeometry, placed.withoutClipGeometry)

        let repository = InMemorySessionRepository()
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile, source: .init(url: "shared-file://share-sheet/Paper.pdf", title: "Paper"),
            text: old.text, contentFormat: .plainText)
        let first = BrowserTextImporter(repository: repository, openItemIds: [], isPlaybackActive: false, publisherPlayback: [:])
        guard case .records(let item, _, _, _) = try first.outcomeAndPersist(handoff, structuredDocument: old, upgrade: .skip) else {
            return XCTFail("expected records")
        }

        // The listener has the paper open and playing when they add it again: it must stay the one item.
        let held = BrowserTextImporter(repository: repository, openItemIds: [item.id], isPlaybackActive: true, publisherPlayback: [:])
        guard case .records(let again, _, _, _) = try held.outcomeAndPersist(handoff, structuredDocument: placed, upgrade: .skip) else {
            return XCTFail("expected records")
        }

        XCTAssertEqual(again.id, item.id, "no -edition- copy for the same words")
        XCTAssertEqual(try repository.listItems().count, 1)
        XCTAssertEqual(try repository.loadStructuredDocument(itemId: item.id), placed, "the regions are saved")
    }

    func testADocumentSavedBeforeTextSegmentIdExistedStillDecodes() throws {
        let old = """
        {"id":"f1","kind":"figure","label":"Figure 1","pageIndex":2,"bounds":{"x":0.1,"y":0.2,"width":0.3,"height":0.4},"captionSegmentId":"s4"}
        """
        let float = try JSONDecoder().decode(StructuredDocument.Float.self, from: Data(old.utf8))

        XCTAssertNil(float.textSegmentId)
        XCTAssertEqual(float.captionSegmentId, "s4")
        let again = try JSONDecoder().decode(StructuredDocument.Float.self, from: JSONEncoder().encode(float))
        XCTAssertEqual(again, float)
    }
}
