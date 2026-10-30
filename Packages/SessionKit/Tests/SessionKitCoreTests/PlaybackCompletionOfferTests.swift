import XCTest
@testable import SessionKit

/// #2393: the playback screen offers "Mark complete" once the body has ended.
final class PlaybackCompletionOfferTests: XCTestCase {
    /// A paper-shaped text: `body` characters of body, then a reference list, then `tail` of appendix.
    private func paper(body: Int, references: Int, tail: Int = 0, referenceRole: StructuredDocument.Role = .reference)
        -> (text: String, source: TimelineSourceContent) {
        var text = ""
        var segments: [StructuredDocument.Segment] = []
        func add(_ role: StructuredDocument.Role, _ count: Int) {
            guard count > 0 else { return }
            let start = text.count
            text += String(repeating: role == .body ? "b" : "r", count: count)
            segments.append(.init(id: "s\(segments.count)", role: role, range: .init(start: start, length: count)))
            text += "\n\n"
        }
        add(.body, body)
        add(referenceRole, references)
        add(.body, tail)
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text, segments: segments, markers: [])
        return (text, TimelineSourceContent(text: text, document: document))
    }

    func testAPaperIsOfferedWhereItsReferencesStartNotAtAFixedFraction() {
        // References start at 60% of the text, as in the owner's PDFs.
        let (text, source) = paper(body: 600, references: 400)
        let referencesStart = 602
        XCTAssertEqual(PlaybackCompletionOffer.bodyEnd(in: source), referencesStart)
        let length = text.count
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: referencesStart - 1, textLength: length, source: source))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: referencesStart, textLength: length, source: source))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: length, textLength: length, source: source))
    }

    func testBackMatterEndsTheBodyToo() {
        let (text, source) = paper(body: 700, references: 300, referenceRole: .backMatter)
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: 702, textLength: text.count, source: source))
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: 701, textLength: text.count, source: source))
    }

    func testAnAppendixAfterTheReferencesDoesNotMoveTheEnd() {
        let (text, source) = paper(body: 500, references: 200, tail: 300)
        XCTAssertEqual(PlaybackCompletionOffer.bodyEnd(in: source), 502)
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: 600, textLength: text.count, source: source))
    }

    func testWithoutAReferenceListTheOfferStartsAtThreeQuarters() {
        let text = String(repeating: "word ", count: 200)
        for source in [TimelineSourceContent(text: text), TimelineSourceContent(text: "")] {
            let length = text.count
            XCTAssertNil(PlaybackCompletionOffer.bodyEnd(in: source))
            XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: length * 3 / 4 - 1, textLength: length, source: source))
            XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: length * 3 / 4, textLength: length, source: source))
        }
    }

    func testAReferenceListInTheFirstQuarterIsAMisreadNotTheEnd() {
        let (text, source) = paper(body: 100, references: 50, tail: 850)
        XCTAssertNil(PlaybackCompletionOffer.bodyEnd(in: source))
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: 300, textLength: text.count, source: source))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: 760, textLength: text.count, source: source))
    }

    func testNeverOfferedEarlyOrWithoutText() {
        let (text, source) = paper(body: 600, references: 400)
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: 0, textLength: text.count, source: source))
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: -1, textLength: text.count, source: source))
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: 10, textLength: 0, source: source))
    }

    func testAStructureForAnotherTextFallsBackToTheFraction() {
        // The stored structure no longer matches the item text (a changed length): it is not trusted.
        let (_, source) = paper(body: 600, references: 400)
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: 650, textLength: 2_000, source: source))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: 1_500, textLength: 2_000, source: source))
    }

    func testABodyEndNearTheVeryEndDoesNotHideTheOfferUntilTheItemIsDone() {
        // #2968: a post whose back matter (a footer, a comments link) starts at 99.5% never offered completion
        // while the listener was nearly done. Past 90% it is offered whatever the structure says.
        let (text, source) = paper(body: 1_000, references: 5, referenceRole: .backMatter)
        let length = text.count
        let end = PlaybackCompletionOffer.bodyEnd(in: source) ?? -1
        XCTAssertGreaterThan(Double(end), Double(length) * 0.95)
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(textOffset: length * 89 / 100, textLength: length, source: source))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: length * 91 / 100, textLength: length, source: source))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(textOffset: length * 96 / 100, textLength: length, source: source))
    }

    func testAPodcastIsOfferedFromThreeQuartersOfItsDuration() {
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(mediaTimeMs: 2_699_999, durationMs: 3_600_000))
        XCTAssertTrue(PlaybackCompletionOffer.isOffered(mediaTimeMs: 2_700_000, durationMs: 3_600_000))
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(mediaTimeMs: 100, durationMs: 0))
        XCTAssertFalse(PlaybackCompletionOffer.isOffered(mediaTimeMs: -1, durationMs: 1_000))
    }
}
