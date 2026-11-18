import Foundation
import XCTest
@testable import SessionKit

/// #2708 PR 4: a page number read from a photo is offered as a checkpoint, never kept on its own. The matcher is a table
/// over lines written by hand (the recogniser is Vision, in the app); the offer is tested on real sessions.
final class LiveSessionPagePhotoTests: XCTestCase {
    typealias Line = LiveSessionPagePhoto.TextLine

    /// A page number's usual line: small, centred in the bottom edge.
    private func footer(_ text: String, x: Double = 0.45, y: Double = 0.03, width: Double = 0.1, confidence: Double = 1) -> Line {
        Line(text: text, minX: x, minY: y, width: width, height: 0.03, confidence: confidence)
    }

    private func header(_ text: String, x: Double = 0.45, width: Double = 0.1) -> Line {
        Line(text: text, minX: x, minY: 0.94, width: width, height: 0.03)
    }

    private func body(_ text: String) -> Line {
        Line(text: text, minX: 0.1, minY: 0.5, width: 0.1, height: 0.03)
    }

    // MARK: What counts as a page number

    func testALineOfItsOwnAtTheEdgeIsAPageNumber() {
        let table: [(String, Int?)] = [
            ("118", 118), ("1", 1), ("999", 999),
            (" 118\n", 118), ("- 118 -", 118), ("\u{2014} 118 \u{2014}", 118), ("[118]", 118), ("(118)", 118), ("\u{00B7} 118 \u{00B7}", 118), ("118.", 118),
            ("p. 118", 118), ("p.118", 118), ("p118", 118), ("pp. 118", 118), ("pg 118", 118), ("Page 118", 118), ("PAGE 118", 118),
            ("page # 118", 118), ("Seite 118", 118), ("Pagina 118", 118), ("Page 118 of 320", 118), ("page 1999", 1999),
            // Not a page number.
            ("", nil), ("   ", nil), ("0", nil), ("007", nil), ("0118", nil), ("1,180", nil), ("11.8", nil), ("117-118", nil), ("117 118", nil),
            ("1000", nil), ("2019", nil), ("1984", nil), ("12:30", nil), ("118%", nil), ("118 THE ECONOMICS OF TRUST", nil),
            ("1 See Smith, 2019", nil), ("Chapter 7", nil), ("page", nil), ("p", nil), ("paragraph 4", nil), ("pages 4 5", nil),
            ("Page 400 of 320", nil), ("Page 118 of 99999", nil), ("page 100000", nil), ("page -5", nil),
            // Digits of other scripts are left alone, never converted.
            ("\u{0661}\u{0661}\u{0668}", nil), ("\u{0967}\u{0967}\u{096E}", nil), ("\u{FF11}\u{FF11}\u{FF18}", nil), ("118\u{0663}", nil),
            ("page \u{0661}\u{0661}\u{0668}", nil), ("118\u{00B2}", nil)
        ]
        for (text, expected) in table {
            XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [footer(text)]), expected, "bottom: \(text.debugDescription)")
            XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [header(text)]), expected, "top: \(text.debugDescription)")
        }
    }

    func testANumberInTheMiddleOfThePageIsNotAPageNumber() {
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [body("118")]))
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [Line(text: "118", minX: 0.45, minY: 0.2, width: 0.1, height: 0.03)]), "outside both bands")
        // Just inside each band.
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [Line(text: "118", minX: 0.45, minY: 0.1, width: 0.1, height: 0.03)]), 118)
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [Line(text: "118", minX: 0.45, minY: 0.87, width: 0.1, height: 0.03)]), 118)
    }

    func testAPageOfWordsWithOneFooterGivesTheFooter() {
        let page = [body("The trust we place in strangers"), body("is a loan, not a gift."), footer("118")]
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: page), 118)
        XCTAssertEqual(LiveSessionPagePhoto.place(in: page), LiveSessionPlace(unit: .page, value: 118))
    }

    func testNothingRecognisedGivesNothing() {
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: []))
        XCTAssertNil(LiveSessionPagePhoto.place(in: [body("just words")]))
    }

    func testAnUncertainOrWideLineIsIgnored() {
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [footer("118", confidence: 0.3)]))
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [footer("118", confidence: 0.5)]), 118)
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [footer("118", x: 0.1, width: 0.5)]), "a number is a narrow box")
    }

    // MARK: Footnotes and neighbours

    func testAFootnoteMarkerBesideItsTextIsNotAPageNumber() {
        // "1" then, right beside it on the same row, the footnote's words.
        let note = [footer("1", x: 0.08, width: 0.02), Line(text: "See Smith, 2019, p. 4.", minX: 0.11, minY: 0.03, width: 0.5, height: 0.03)]
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: note))
        // The same marker with a real page number in the middle of the row below it: the page number alone.
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: note + [Line(text: "118", minX: 0.45, minY: 0.005, width: 0.1, height: 0.02)]), 118)
    }

    func testARunningHeadFarFromTheNumberDoesNotHideIt() {
        let head = [Line(text: "THE ECONOMICS OF TRUST", minX: 0.1, minY: 0.94, width: 0.5, height: 0.03), header("118", x: 0.88, width: 0.07)]
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: head), 118)
    }

    func testARunningHeadRightBesideTheNumberHidesIt() {
        let crowded = [header("118", x: 0.1, width: 0.05), Line(text: "THE ECONOMICS", minX: 0.16, minY: 0.94, width: 0.3, height: 0.03)]
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: crowded), "text starting right beside a number may be its sentence")
    }

    // MARK: Two numbers

    func testTwoDifferentNumbersGiveNothing() {
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [footer("118", x: 0.1, width: 0.07), footer("119", x: 0.85, width: 0.07)]), "a spread")
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [footer("118"), header("42")]))
    }

    func testTheSameNumberTwiceIsOneNumber() {
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [footer("118"), header("118")]), 118)
    }

    func testANumberWithItsWordOutranksABareOne() {
        XCTAssertEqual(LiveSessionPagePhoto.pageNumber(in: [footer("3", x: 0.05, width: 0.03), footer("Page 118")]), 118)
        XCTAssertNil(LiveSessionPagePhoto.pageNumber(in: [footer("Page 118", x: 0.1), footer("p. 119", x: 0.7)]), "two with words still disagree")
    }

    // MARK: A Margin's offer

    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!
    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
    private let photo = LiveSessionPhoto(path: "SpokenMargins/live-photos/p/a.jpg", widthPx: 1_200, heightPx: 1_600, byteCount: 400_000)!

    private func page(_ value: Double) -> LiveSessionPlace { LiveSessionPlace(unit: .page, value: value)! }

    /// A paper book with a photo Margin ("a"), a plain Margin after it ("b"), and no checkpoints yet.
    private func sessionWithPhoto(kind: ElsewhereKind = .paper, text: String = "this paragraph") -> LiveSession {
        var live = LiveSession(id: "p", kind: kind, title: "The book", startedAt: start, endedAt: at(40))
        var margin = live.margin(id: "a", text: text, markedAt: at(10))
        margin.photo = photo
        live.margins = [margin, live.margin(id: "b", text: "later", markedAt: at(20))]
        return live
    }

    func testAPhotoMarginIsReadOnceAndOffersWhatWasRead() {
        var live = sessionWithPhoto()
        XCTAssertTrue(live.needsPageRead(forMarginId: "a"))
        XCTAssertFalse(live.needsPageRead(forMarginId: "b"), "no photo")
        XCTAssertFalse(live.needsPageRead(forMarginId: "missing"))
        XCTAssertNil(live.photoPageOffer(forMarginId: "a"), "nothing read yet")

        XCTAssertTrue(live.recordPageRead(page(118), forMarginId: "a"))
        XCTAssertEqual(live.photoPageOffer(forMarginId: "a"), page(118))
        XCTAssertNil(live.margins[0].place, "an offer is not a place until it is kept")
        XCTAssertFalse(live.needsPageRead(forMarginId: "a"), "read once")
        XCTAssertFalse(live.recordPageRead(page(5), forMarginId: "a"), "a second read does not replace the first")
        XCTAssertEqual(live.photoPageOffer(forMarginId: "a"), page(118))
    }

    func testAPhotoWithNoPageNumberIsStillMarkedRead() {
        var live = sessionWithPhoto()
        XCTAssertTrue(live.recordPageRead(nil, forMarginId: "a"))
        XCTAssertNil(live.photoPageOffer(forMarginId: "a"))
        XCTAssertFalse(live.needsPageRead(forMarginId: "a"), "no number is an answer too: it is not read again")
        XCTAssertFalse(live.keepHeardPlace(forMarginId: "a"))
        XCTAssertFalse(live.declineHeardPlace(forMarginId: "a"))
    }

    func testKeepingTheOfferMakesItTheMarginsCheckpoint() {
        var live = sessionWithPhoto()
        live.startPlace = page(100)
        live.endPlace = page(140)
        live.recordPageRead(page(118), forMarginId: "a")
        XCTAssertTrue(live.keepHeardPlace(forMarginId: "a"))
        XCTAssertEqual(live.margins[0].place, page(118))
        XCTAssertNil(live.photoPageOffer(forMarginId: "a"), "kept, so not offered again")
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[0], in: live), "page 118")
        // It is a checkpoint for the Margins around it: "b" is between page 118 (10:10) and the end, page 140 (10:40).
        XCTAssertEqual(LiveSessionPlaceMap.label(for: live.margins[1], in: live), "about page 125")
    }

    func testTurningDownTheOfferKeepsItOut() {
        var live = sessionWithPhoto()
        live.recordPageRead(page(118), forMarginId: "a")
        XCTAssertTrue(live.declineHeardPlace(forMarginId: "a"))
        XCTAssertNil(live.photoPageOffer(forMarginId: "a"))
        XCTAssertNil(live.margins[0].place)
        XCTAssertFalse(live.needsPageRead(forMarginId: "a"))
    }

    func testAPlaceTypedOrSaidComesBeforeThePhotosPage() {
        // A place typed with the Margin is already the listener's own.
        var typed = sessionWithPhoto()
        typed.margins[0].place = page(90)
        typed.recordPageRead(page(118), forMarginId: "a")
        XCTAssertNil(typed.photoPageOffer(forMarginId: "a"))
        XCTAssertFalse(typed.needsPageRead(forMarginId: "a"), "it already has a place of its own")

        // A page said in the words is offered first, and keeping it does not take the photo's.
        var said = sessionWithPhoto(text: "I'm on page 90")
        said.recordPageRead(page(118), forMarginId: "a")
        XCTAssertEqual(said.margins[0].heardPlace, page(90))
        XCTAssertNil(said.photoPageOffer(forMarginId: "a"))
        XCTAssertTrue(said.keepHeardPlace(forMarginId: "a"))
        XCTAssertEqual(said.margins[0].place, page(90))
    }

    func testOnlyASessionThatCanUseAPageGetsTheOffer() {
        // Placed by percent: a page would be ignored, so there is nothing to read for.
        var percent = sessionWithPhoto(kind: .other)
        percent.startPlace = LiveSessionPlace(unit: .percent, value: 10)
        XCTAssertFalse(percent.needsPageRead(forMarginId: "a"))
        percent.margins[0].photoPlace = page(118)
        XCTAssertNil(percent.photoPageOffer(forMarginId: "a"))

        // Placed by a clock.
        var clock = LiveSession(id: "c", kind: .other, startedAt: start, endedAt: at(40), startPositionMs: 60_000)
        var margin = clock.margin(id: "a", text: "x", markedAt: at(5))
        margin.photo = photo
        clock.margins = [margin]
        XCTAssertFalse(clock.needsPageRead(forMarginId: "a"))

        // Not placed yet, or placed by pages: both can.
        XCTAssertTrue(sessionWithPhoto(kind: .other).needsPageRead(forMarginId: "a"))
        var paged = sessionWithPhoto()
        paged.startPlace = page(100)
        XCTAssertTrue(paged.needsPageRead(forMarginId: "a"))
    }

    func testAPhotoThatBreaksTheRulesIsNotReadOrOffered() {
        var live = sessionWithPhoto()
        live.recordPageRead(page(118), forMarginId: "a")
        let broken = Data(#"{"path":"../etc/passwd","widthPx":10,"heightPx":10,"byteCount":10}"#.utf8)
        live.margins[0].photo = try? JSONDecoder().decode(LiveSessionPhoto.self, from: broken)
        XCTAssertNotNil(live.margins[0].photo)
        XCTAssertNil(live.margins[0].validPhoto)
        XCTAssertNil(live.photoPageOffer(forMarginId: "a"))
        XCTAssertFalse(live.needsPageRead(forMarginId: "a"))
    }

    func testOnlyAPageIsKeptFromAPhoto() {
        var live = sessionWithPhoto()
        XCTAssertTrue(live.recordPageRead(LiveSessionPlace(unit: .percent, value: 40), forMarginId: "a"))
        XCTAssertNil(live.margins[0].photoPlace, "a photo gives a page and never another unit")
    }

    // MARK: Saved sessions

    func testASessionSavedBeforeThisReadsAsNotYetRead() throws {
        let live = sessionWithPhoto()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(live)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains("photoPlace"), "absent until a page is read")
        XCTAssertFalse(text.contains("photoRead"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LiveSession.self, from: json)
        XCTAssertNil(decoded.margins[0].photoRead)
        XCTAssertTrue(decoded.needsPageRead(forMarginId: "a"))
    }

    func testTheOfferSurvivesSavingAndReopening() throws {
        var live = sessionWithPhoto()
        live.recordPageRead(page(118), forMarginId: "a")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LiveSession.self, from: try encoder.encode(live))
        XCTAssertEqual(decoded.photoPageOffer(forMarginId: "a"), page(118))
        XCTAssertFalse(decoded.needsPageRead(forMarginId: "a"))
    }
}
