import XCTest
import UIKit
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// The table and figure pictures on the Timeline (#3895): which rows get one, what is read for them, and what a row
/// without one is.
@MainActor
final class TimelineClipPictureTests: XCTestCase {
    /// A folder of this test's own, removed when it ends.
    private lazy var base: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "timeline-clips-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()

    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func document(floatIds: [String]) -> StructuredDocument {
        StructuredDocument(
            extraction: .init(engine: "test", version: 2, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: "Group | Mean", segments: [], markers: [],
            floats: floatIds.map {
                .init(id: $0, kind: .table, label: "Table 1", pageIndex: 0,
                      bounds: PDFNormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2),
                      captionSegmentId: nil, textSegmentId: "s1")
            })
    }

    /// A Timeline row of a table whose segment names `floatId`.
    private func tableRow(floatId: String?) throws -> TimelineRailEntry {
        let text = "Group | Mean"
        var document = document(floatIds: floatId.map { [$0] } ?? [])
        document.text = text
        document.segments = [.init(id: "s1", role: .table, range: .init(start: 0, length: text.count), pageIndex: 0, floatId: floatId)]
        let content = TimelineSourceContent(text: text, document: document)
        let entry = try XCTUnwrap(content.entries.first)
        return TimelineRailEntry(id: entry.id, position: 0, rank: 0, provenance: .source, title: "Table 1",
                                 detail: text, action: .sourceText(entry))
    }

    private func source(clips: [String: Data], floatIds: [String], itemId: String = "item-1") throws -> TimelineClipSource {
        let store = PDFClipStore(directory: base.appending(path: "PDFClips", directoryHint: .isDirectory))
        try store.replaceClips(clips, forItem: itemId, document: document(floatIds: floatIds))
        return TimelineClipSource(store: store, itemId: itemId, available: store.available(forItem: itemId))
    }

    func testARowGetsAPictureOnlyWhenItsFloatHasOneSaved() throws {
        let clips = try source(clips: ["float-p1-1": jpeg(width: 300, height: 100)], floatIds: ["float-p1-1", "float-p1-2"])

        let withClip = try XCTUnwrap(TimelineRowClip(entry: tableRow(floatId: "float-p1-1"), in: clips))
        XCTAssertEqual(withClip.floatId, "float-p1-1")
        XCTAssertEqual(withClip.spokenLabel, "Table 1, clip of the table, page 1")

        XCTAssertNil(TimelineRowClip(entry: try tableRow(floatId: "float-p1-2"), in: clips), "located, but no picture was cut")
        XCTAssertNil(TimelineRowClip(entry: try tableRow(floatId: nil), in: clips), "no float: the row is its text, as it was")
        XCTAssertNil(TimelineRowClip(entry: try tableRow(floatId: "float-p1-1"), in: .none), "an item with no clips")
    }

    func testTheRowPictureAndTheViewerReadTheSavedFileAndNeverMoreThanTheirSize() async throws {
        let clips = try source(clips: ["float-p1-1": jpeg(width: 1_400, height: 700)], floatIds: ["float-p1-1"])

        let rowImage = await clips.rowImage(forFloat: "float-p1-1")
        let row = try XCTUnwrap(rowImage)
        XCTAssertLessThanOrEqual(max(row.size.width * row.scale, row.size.height * row.scale), 900, "a row decodes no more than it draws")
        XCTAssertEqual(row.size.width / row.size.height, 2, accuracy: 0.05, "the shape is kept")

        let fullImage = await clips.fullImage(forFloat: "float-p1-1")
        let full = try XCTUnwrap(fullImage)
        XCTAssertGreaterThan(max(full.size.width * full.scale, full.size.height * full.scale), 900, "the viewer has the saved size")
    }

    func testAMissingPictureIsNilNotAnError() async throws {
        let clips = try source(clips: ["float-p1-1": jpeg(width: 100, height: 100)], floatIds: ["float-p1-1"])
        let gone = await clips.rowImage(forFloat: "float-p9-9")
        XCTAssertNil(gone)
        let none = await TimelineClipSource.none.rowImage(forFloat: "float-p1-1")
        XCTAssertNil(none)

        // The file removed after the Timeline listed it (a delete, a re-import): the viewer says so, the row shows text.
        try clips.store?.removeClips(forItem: "item-1")
        let removed = await clips.fullImage(forFloat: "float-p1-1")
        XCTAssertNil(removed)
    }

    func testTheViewerSelectionNamesTheRowsOwnWords() throws {
        let clips = try source(clips: ["float-p1-1": jpeg(width: 100, height: 100)], floatIds: ["float-p1-1"])
        let row = try tableRow(floatId: "float-p1-1")
        guard case .sourceText(let entry) = row.action else { return XCTFail("a source text row") }
        let selection = try XCTUnwrap(TimelineClipSelection(entry: entry, source: clips))
        XCTAssertEqual(selection.id, clips.pictureKey(forFloat: "float-p1-1"))
        XCTAssertEqual(selection.title, "Table 1")
        XCTAssertEqual(selection.spokenLabel, "Table 1, clip of the table, page 1")

        guard case .sourceText(let plain) = try tableRow(floatId: nil).action else { return XCTFail("a source text row") }
        XCTAssertNil(TimelineClipSelection(entry: plain, source: clips), "no float, no picture")
        XCTAssertNil(TimelineClipSelection(entry: entry, source: .none), "a source that has no such picture")
    }

    /// Clip ids come from page and position, so two PDFs both have a `float-p1-1`. A picture is the item's, the
    /// folder's version and the float, never the float alone (the audit of #4599).
    func testTwoItemsWithTheSameFloatIdAreTwoPictures() async throws {
        let a = try source(clips: ["float-p1-1": jpeg(width: 400, height: 100)], floatIds: ["float-p1-1"], itemId: "paper-a")
        let b = try source(clips: ["float-p1-1": jpeg(width: 100, height: 400)], floatIds: ["float-p1-1"], itemId: "paper-b")

        XCTAssertNotEqual(a.pictureKey(forFloat: "float-p1-1"), b.pictureKey(forFloat: "float-p1-1"))
        let row = try tableRow(floatId: "float-p1-1")
        let rowA = try XCTUnwrap(TimelineRowClip(entry: row, in: a))
        let rowB = try XCTUnwrap(TimelineRowClip(entry: row, in: b))
        XCTAssertNotEqual(rowA, rowB, "the same row against another item's source is another row, so it redraws")
        XCTAssertNotEqual(rowA.key, rowB.key, "and its picture reloads")

        let pictureA = await rowA.source.rowImage(forFloat: rowA.floatId)
        let pictureB = await rowB.source.rowImage(forFloat: rowB.floatId)
        XCTAssertGreaterThan(try XCTUnwrap(pictureA).size.width, try XCTUnwrap(pictureA).size.height, "A is wide")
        XCTAssertGreaterThan(try XCTUnwrap(pictureB).size.height, try XCTUnwrap(pictureB).size.width, "B is tall")

        // Opened from A, the viewer stays A's even after the Timeline moves to B.
        guard case .sourceText(let entry) = row.action else { return XCTFail("a source text row") }
        let selection = try XCTUnwrap(TimelineClipSelection(entry: entry, source: a))
        XCTAssertEqual(selection.source.itemId, "paper-a")
        XCTAssertNotEqual(selection, TimelineClipSelection(entry: entry, source: b))
    }
}
