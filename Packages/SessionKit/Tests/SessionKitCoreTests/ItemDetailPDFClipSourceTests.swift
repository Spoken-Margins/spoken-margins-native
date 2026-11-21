@testable import SessionKit
import XCTest

/// The Now tab's table and figure cards need the item's floats and segment table with the detail, so a playback tick
/// never reads the store (#4588).
final class ItemDetailPDFClipSourceTests: XCTestCase {
    private func document(text: String, floats: Int) -> StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "test", version: 2, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text,
            segments: [.init(id: "s1", role: .body, range: .init(start: 0, length: text.count))],
            markers: [],
            floats: (0..<floats).map {
                .init(id: "float-p1-\($0)", kind: .table, label: nil, pageIndex: 0,
                      bounds: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2), captionSegmentId: nil, textSegmentId: "s1")
            })
    }

    func testAPDFWithFloatsGetsASourceThatNamesThemAndTheirSegments() throws {
        let text = "Table 1. Baseline"
        let detail = ItemDetailState(id: "pdf-a", text: text).includingTimelineSource(document(text: text, floats: 2))

        let source = try XCTUnwrap(detail.pdfClipSource)
        XCTAssertEqual(source.floats.map(\.id), ["float-p1-0", "float-p1-1"])
        XCTAssertEqual(source.segments.map(\.id), ["s1"])
    }

    func testNoDocumentNoFloatsOrADifferentTextGivesNoSource() {
        let text = "Table 1. Baseline"
        XCTAssertNil(ItemDetailState(id: "article-a", text: text).includingTimelineSource(nil).pdfClipSource, "an article")
        XCTAssertNil(ItemDetailState(id: "pdf-a", text: text).includingTimelineSource(document(text: text, floats: 0)).pdfClipSource,
                     "a PDF with no tables or figures")
        XCTAssertNil(ItemDetailState(id: "pdf-a", text: "Another edition of the text").includingTimelineSource(document(text: text, floats: 1)).pdfClipSource,
                     "a document whose text is not the item's text")
        XCTAssertNil(ItemDetailState().pdfClipSource, "a detail nobody loaded")
    }

    func testANativeAudioItemKeepsNoSource() {
        var detail = ItemDetailState(id: "audio-a", text: "Table 1. Baseline")
        detail.isNativeAudio = true
        XCTAssertNil(detail.includingTimelineSource(document(text: "Table 1. Baseline", floats: 1)).pdfClipSource)
    }

    func testTwoDetailsDifferWhenOnlyTheirFloatsDo() {
        let text = "Table 1. Baseline"
        let one = ItemDetailState(id: "pdf-a", text: text).includingTimelineSource(document(text: text, floats: 1))
        let two = ItemDetailState(id: "pdf-a", text: text).includingTimelineSource(document(text: text, floats: 2))
        XCTAssertNotEqual(one, two, "a view that compares details redraws when the cards could change")
        XCTAssertEqual(one, ItemDetailState(id: "pdf-a", text: text).includingTimelineSource(document(text: text, floats: 1)))
    }
}
