import XCTest
@testable import SessionKit

final class PlaybackLivePassageSourceTests: XCTestCase {
    func testFragmentsPreserveExactTextWhitespaceAndAuthoredRolesAtCanonicalPositions() {
        let text = "🙂 Title\r\n\r\nFigure e\u{301} caption\n\nCell A | Cell B\n\nFootnote"
        let roles: [(String, StructuredDocument.Role)] = [("🙂 Title", .title), ("Figure e\u{301} caption", .caption), ("Cell A | Cell B", .table), ("Footnote", .footnote)]
        let segments = roles.enumerated().map { index, pair in
            StructuredDocument.Segment(id: "s\(index)", role: pair.1,
                range: .init(start: text.distance(from: text.startIndex, to: text.range(of: pair.0)!.lowerBound), length: pair.0.count), pageIndex: 0)
        }
        var document = StructuredDocument(extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
                                          text: text, segments: segments, markers: [])
        document.floats = [.init(id: "figure", kind: .figure, label: "Fig. 2 — Authored label", pageIndex: 0,
                                bounds: .init(x: 0, y: 0, width: 1, height: 1), captionSegmentId: "s1")]
        let index = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: text, document: document))
        for bounds in [0..<text.count, 3..<(text.count - 2), 9..<25] {
            let original = String(Array(text)[bounds])
            let sentence = PlaybackLivePassage.Sentence(start: bounds.lowerBound, end: bounds.upperBound,
                                                       text: original, isCurrent: true, diamonds: [])
            let fragments = index.fragments(for: sentence)
            XCTAssertEqual(fragments.map(\.text).joined(), original)
            var cursor = bounds.lowerBound
            for fragment in fragments {
                XCTAssertEqual(fragment.start, cursor)
                cursor += fragment.text.count
            }
            XCTAssertEqual(cursor, bounds.upperBound)
            XCTAssertEqual(Set(fragments.map(\.id)).count, fragments.count)
        }
        let all = index.fragments(for: .init(start: 0, end: text.count, text: text, isCurrent: true, diamonds: []))
        XCTAssertEqual(all.filter { $0.role != .body }.map(\.role), [.title, .caption, .table, .footnote])
        XCTAssertEqual(all.first(where: { $0.role == .caption })?.label, "Fig. 2 — Authored label")
        XCTAssertEqual(all.first(where: { $0.role == .caption })?.pageIndex, 0)
    }

    func testMissingOrMalformedOverlappingMetadataNeverDuplicatesOrLosesSourceText() {
        let text = "Original source text."
        let document = StructuredDocument(extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
                                          text: text, segments: [
                                            .init(id: "outer", role: .body, range: .init(start: 0, length: text.count)),
                                            .init(id: "invalid", role: .caption, range: .init(start: 3, length: 4))
                                          ], markers: [])
        let sentence = PlaybackLivePassage.Sentence(start: 0, end: text.count, text: text, isCurrent: true, diamonds: [])
        for source in [TimelineSourceContent(text: ""), TimelineSourceContent(text: text, document: document)] {
            let fragments = PlaybackLivePassage.SourceIndex(source).fragments(for: sentence)
            XCTAssertEqual(fragments.map(\.text).joined(), text)
            XCTAssertEqual(fragments.map(\.role), [.body])
        }
    }
}
