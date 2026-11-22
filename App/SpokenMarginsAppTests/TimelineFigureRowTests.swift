import XCTest
import UIKit
import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

/// The Timeline row of a picture-only PDF figure (#4587, PR 2): present only when its picture was cut for this item.
@MainActor
final class TimelineFigureRowTests: XCTestCase {
    private lazy var base: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "timeline-figures-\(UUID().uuidString)", directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }()

    private let itemId = "item-1"
    private let floatId = "float-p1-c1"

    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
    }

    /// A PDF whose body segment holds a "Figure 3" caption and whose float has no text of its own.
    private func document() -> StructuredDocument {
        let text = "Opening paragraph of the paper.\nFigure 3. Micrographs of treated cells. Scale bars, 10 µm.\nThe results follow."
        return StructuredDocument(
            extraction: .init(engine: "test", version: 2, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: text, segments: [.init(id: "b", role: .body, range: .init(start: 0, length: text.count), pageIndex: 0)],
            markers: [],
            floats: [.init(id: floatId, kind: .figure, label: "Figure 3", pageIndex: 1,
                           bounds: PDFNormalizedRect(x: 0.1, y: 0.4, width: 0.5, height: 0.2),
                           captionSegmentId: "b", textSegmentId: nil)])
    }

    private func item() -> ItemDetailState {
        let document = document()
        return ItemDetailState(id: itemId, title: "Paper", text: document.text).includingTimelineSource(document)
    }

    /// A listing read from a real store, as the Timeline reads it.
    private func clips(saving floatIds: [String], forItem id: String? = nil) throws -> TimelineClipSource {
        let id = id ?? itemId
        let store = PDFClipStore(directory: base.appending(path: "PDFClips", directoryHint: .isDirectory))
        try store.replaceClips(Dictionary(uniqueKeysWithValues: floatIds.map { ($0, jpeg()) }), forItem: id, document: document())
        return TimelineClipSource(store: store, itemId: id, available: store.available(forItem: id))
    }

    private func figureRows(_ clips: TimelineClipSource, item: ItemDetailState? = nil) -> [TimelineRailEntry] {
        ExperienceTimelineRailScreen.makeEntries(from: item ?? self.item(), sessionID: nil, clips: clips)
            .filter { $0.id.hasPrefix("source.figure.") }
    }

    func testAFigureWithAPictureGetsARowAtItsCaptionWithTheLabelAndTheFirstSentence() throws {
        let item = item()
        let row = try XCTUnwrap(figureRows(try clips(saving: [floatId]), item: item).first)
        XCTAssertEqual(row.id, "source.figure.\(floatId)")
        XCTAssertEqual(row.title, "Figure 3")
        XCTAssertEqual(row.detail, "Figure 3. Micrographs of treated cells.")
        XCTAssertEqual(row.provenance, .source)
        guard case .sourceText(let entry) = row.action else { return XCTFail("a source text row") }
        XCTAssertEqual(entry.floatId, floatId)
        XCTAssertEqual(entry.floatKind, .figure)
        let expected = Double(entry.start) / Double(item.timelineSource.characterCount) * 100
        XCTAssertEqual(row.precisePosition ?? -1, expected, accuracy: 0.001, "at the caption line's place")
    }

    func testTheFiguresRowHasThePictureTheViewerAndTheSpokenWordsEveryClipRowHas() throws {
        let source = try clips(saving: [floatId])
        let row = try XCTUnwrap(figureRows(source).first)
        let clip = try XCTUnwrap(TimelineRowClip(entry: row, in: source))
        XCTAssertEqual(clip.spokenLabel, "Figure 3, clip of the figure, page 2")
        guard case .sourceText(let entry) = row.action else { return XCTFail("a source text row") }
        let selection = try XCTUnwrap(TimelineClipSelection(entry: entry, source: source))
        XCTAssertEqual(selection.title, "Figure 3")
        XCTAssertEqual(TimelineClipPresentation.viewActionTitle(kind: entry.floatKind), "View figure")
    }

    func testAListingWithoutTheFloatNoListingAndAnotherItemsListingGiveNoRow() throws {
        XCTAssertEqual(figureRows(try clips(saving: [])).count, 0, "located, but no picture was cut")
        XCTAssertEqual(figureRows(.none).count, 0, "no listing yet")
        // Ids like float-p1-c1 repeat across PDFs: this listing holds the same id, for another item.
        XCTAssertEqual(figureRows(try clips(saving: [floatId], forItem: "another-item")).count, 0)
    }

    func testRowsOfAnItemWithNoPictureOnlyFiguresAreWhatTheyWereBefore() throws {
        let plain = ItemDetailState(id: itemId, title: "Essay", text: "One paragraph.\n\nAnother paragraph.")
        let source = try clips(saving: [floatId])
        XCTAssertEqual(ExperienceTimelineRailScreen.makeEntries(from: plain, sessionID: nil, clips: source).map(\.id),
                       ExperienceTimelineRailScreen.makeEntries(from: plain, sessionID: nil).map(\.id))
        let withPicture = ExperienceTimelineRailScreen.makeEntries(from: item(), sessionID: nil, clips: source).map(\.id)
        let without = ExperienceTimelineRailScreen.makeEntries(from: item(), sessionID: nil, clips: .none).map(\.id)
        XCTAssertEqual(withPicture.filter { !$0.hasPrefix("source.figure.") }, without, "a figure row adds one row and moves no other")
    }

    func testAFigureRowIsNeverTheRowPlaybackFollows() throws {
        let item = item()
        let rows = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil, clips: try clips(saving: [floatId]))
        var snapshot = SessionSnapshot()
        snapshot.itemId = item.id
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        let figureStart = try XCTUnwrap(item.timelineSource.figures.first).start
        for offset in [figureStart, figureStart + 5] {
            snapshot.currentTextStart = offset
            let selection = ExperienceTimelineRailScreen.selectionForPlayback(
                entries: rows, item: item, snapshot: snapshot, isCurrent: { _ in false })
            XCTAssertFalse(selection.currentIDs.contains("source.figure.\(floatId)"), "offset \(offset)")
        }
    }
}
