import XCTest
@testable import SessionKit

/// A narrated Margin moment plans its lead-in on the text of the item on screen instead of reading the item from
/// the store on the main actor (#2506). That is only safe when the detail is for the same item.
final class ItemDetailStateTextTests: XCTestCase {
    func testTextIsGivenOnlyForTheDetailsOwnItem() {
        let detail = ItemDetailState(id: "article-a", text: "First. Second.")
        XCTAssertEqual(detail.text(forItem: "article-a"), "First. Second.")
        XCTAssertNil(detail.text(forItem: "article-b"))
        XCTAssertNil(detail.text(forItem: ""), "an empty id is not the item")
    }

    func testAnEmptyDetailHasNoTextForAnyRealItem() {
        XCTAssertNil(ItemDetailState().text(forItem: "article-a"))
    }

    func testAnItemWithNoTextGivesAnEmptyStringNotNil() {
        XCTAssertEqual(ItemDetailState(id: "audio-a", text: "").text(forItem: "audio-a"), "")
    }

    // MARK: The Now tab's card source (#4588)

    private func pdfDocument(text: String, floatIds: [String]) -> StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "test", version: 2, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text,
            segments: [.init(id: "s1", role: .table, range: .init(start: 0, length: text.count))],
            markers: [],
            floats: floatIds.map {
                .init(id: $0, kind: .table, label: nil, pageIndex: 0, bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                      captionSegmentId: nil, textSegmentId: "s1")
            })
    }

    func testAPDFWithFloatsGivesTheNowTabItsCardSource() throws {
        let text = "Cell A | Cell B"
        let detail = ItemDetailState(id: "pdf-a", text: text)
            .includingTimelineSource(pdfDocument(text: text, floatIds: ["float-p1-1", "float-p1-2"]))
        let source = try XCTUnwrap(detail.pdfClipSource)
        XCTAssertEqual(source.floats.map(\.id), ["float-p1-1", "float-p1-2"])
        XCTAssertEqual(source.segments.map(\.id), ["s1"])
    }

    func testNothingElseGivesACardSource() {
        let text = "Cell A | Cell B"
        // An article or a podcast has no structured document.
        XCTAssertNil(ItemDetailState(id: "a", text: text).includingTimelineSource(nil).pdfClipSource)
        // A PDF with no tables or figures.
        XCTAssertNil(ItemDetailState(id: "b", text: text)
            .includingTimelineSource(pdfDocument(text: text, floatIds: [])).pdfClipSource)
        // A document whose text is not the item's: its offsets would land in the wrong place.
        XCTAssertNil(ItemDetailState(id: "c", text: text + " edited")
            .includingTimelineSource(pdfDocument(text: text, floatIds: ["float-p1-1"])).pdfClipSource)
        // Recorded audio keeps no timeline source at all.
        XCTAssertNil(ItemDetailState(id: "d", text: text, isNativeAudio: true)
            .includingTimelineSource(pdfDocument(text: text, floatIds: ["float-p1-1"])).pdfClipSource)
        // And a detail nobody prepared has none.
        XCTAssertNil(ItemDetailState().pdfClipSource)
    }

    func testReplacingTheDocumentReplacesTheSource() throws {
        let text = "Cell A | Cell B"
        let first = ItemDetailState(id: "pdf-a", text: text).includingTimelineSource(pdfDocument(text: text, floatIds: ["f1"]))
        XCTAssertNotNil(first.pdfClipSource)
        XCTAssertNil(first.includingTimelineSource(nil).pdfClipSource, "a detail prepared again without a document drops the cards")
    }
}
