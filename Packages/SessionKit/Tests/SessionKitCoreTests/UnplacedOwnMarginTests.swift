import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4233, PR 2a: a Margin moved from a live session that has no place on its item (`Interjection.hasPlace == false`)
/// stores zeros for its position. Every SessionKit function that words, orders or upgrades a Margin's place must read
/// `hasPlace` first, or those zeros show as "0%", "0:00", sort first, or stop a PDF upgrade. One table here: an unplaced
/// Margin on a media item and one on a text item, each through the function, next to a placed Margin that must read
/// as it always did.
final class UnplacedOwnMarginTests: XCTestCase {
    private let madeAt = Date(timeIntervalSince1970: 1_780_000_000) // Thu 28 May 2026, UTC
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let posix = Locale(identifier: "en_US_POSIX")

    private func margin(_ id: String, unplaced: Bool, media: Bool, at ms: Int = 90_000, char: Int = 400,
                        target: InterjectionTargetType = .item, created: TimeInterval = 0) -> Interjection {
        var margin = Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: target, targetId: "item",
            createdAt: madeAt.addingTimeInterval(created), roughPercent: unplaced ? 0 : 10,
            anchor: media
                ? Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: unplaced ? nil : ms)
                : Anchor(anchorType: .text, startChar: unplaced ? 0 : char, endChar: unplaced ? 0 : char + 5, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "discarded", transcriptionStatus: "transcribed", transcript: "Words for \(id).",
            cleanedTranscript: nil, displayText: "Words for \(id).", status: "active", captureKind: .written)
        if unplaced { margin.movedOrigin = origin(of: margin) }
        return margin
    }

    private func origin(of margin: Interjection) -> MovedMarginOrigin {
        MovedMarginOrigin(
            marginId: margin.id, itemId: margin.itemId, sessionId: margin.sessionId,
            liveMarginId: "live-\(margin.id)", fromLiveSessionId: "live-quick", fromLiveSessionTitle: "Quick session",
            markedAt: margin.createdAt, movedAt: margin.createdAt.addingTimeInterval(60), placeKnown: false)
    }

    private func entry(_ margin: Interjection) -> MarginCollection.PrivateEntry {
        MarginCollection.PrivateEntry(interjection: margin, itemTitle: "Title", sessionDate: nil)
    }

    // MARK: Wording and order

    func testThePlaceLineSaysNoPlaceAndTheDay() {
        let now = madeAt.addingTimeInterval(3_600)
        let unplaced = MarginRowWording.placeLine(
            placeName: "Ch. 3", mediaTimeMs: nil, paragraph: 4, roughPercent: 0, hasPlace: false,
            createdAt: madeAt, now: now, calendar: utc, locale: posix)
        XCTAssertEqual(unplaced, "No place · Thu", "no chapter, no clock, no paragraph and never \"0%\"")
        // Neighbours that must not change: the same arguments with a place, and with no `hasPlace` argument at all.
        XCTAssertEqual(MarginRowWording.placeLine(
            placeName: "Ch. 3", mediaTimeMs: 90_000, roughPercent: 10, createdAt: madeAt, now: now, calendar: utc, locale: posix),
            "Ch. 3 · 01:30 · Thu")
        XCTAssertEqual(MarginRowWording.placeLine(
            mediaTimeMs: nil, roughPercent: 0, createdAt: madeAt, now: now, calendar: utc, locale: posix),
            "0% · Thu", "a Margin that never said it has no place reads as before")
        XCTAssertEqual(MarginRowWording.placeLine(
            mediaTimeMs: nil, roughPercent: 0, hasPlace: false, createdAt: madeAt.addingTimeInterval(-10 * 86_400), now: now,
            calendar: utc, locale: posix), "No place · Mon 18 May", "an older Margin shows the date too")
    }

    func testAnUnplacedMarginSortsAfterEveryPlacedOneOnMediaAndText() {
        for media in [true, false] {
            let unplacedFirstMade = margin("unplaced-a", unplaced: true, media: media, created: -500)
            let unplacedSecondMade = margin("unplaced-b", unplaced: true, media: media, created: -100)
            let early = margin("early", unplaced: false, media: media, at: 5_000, char: 10, created: 0)
            let late = margin("late", unplaced: false, media: media, at: 900_000, char: 900, created: 0)
            let response = margin("response", unplaced: false, media: media, target: .assistantTurn)

            let ordered = [response, unplacedSecondMade, late, unplacedFirstMade, early]
                .sorted(by: MarginSourceOrder.isOrderedBefore).map(\.id)

            XCTAssertEqual(ordered, ["early", "late", "unplaced-a", "unplaced-b", "response"],
                           "media: \(media). No \"0:00\" first; placed, then unplaced oldest first, then responses")
        }
    }

    // MARK: Chapter and paragraph

    func testAnUnplacedMarginGetsNoChapterOrParagraph() {
        let text = "Intro line.\nSecond line.\nThird line."
        let items = [Item(id: "item", title: "Title", mediaType: "text", text: text, externalReference: nil, status: "ready")]
        let map = ListeningMap(id: "map", itemId: "item", overview: "", chapters: [])
        for media in [true, false] {
            let unplaced = entry(margin("unplaced", unplaced: true, media: media))
            let placed = entry(margin("placed", unplaced: false, media: media, at: 5_000, char: 14))
            let places = MarginPlaces.places(
                for: [unplaced, placed], items: items, loadMap: { _ in map },
                loadMediaChapters: { _ in [MediaTimelineChapter(id: "c0", title: "Cold open", startMs: 0, transcriptSegmentId: "s0")] })
            XCTAssertNil(places[unplaced.id], "media: \(media). Zeros would name the first chapter and paragraph 1")
            XCTAssertNotNil(places[placed.id], "media: \(media). The placed neighbour still gets its place")
        }
    }

    // MARK: Today's Margins digest

    func testTheDigestSaysNothingAboutWhereForAnUnplacedMargin() {
        for media in [true, false] {
            let unplaced = margin("unplaced", unplaced: true, media: media)
            let placed = margin("placed", unplaced: false, media: media, at: 90_000, char: 400)
            XCTAssertEqual(TodaysMarginsDigest.place(of: unplaced), "", "media: \(media)")
            XCTAssertEqual(TodaysMarginsDigest.place(of: placed), media ? "at 01:30" : "about 10% through")

            let entries = TodaysMarginsDigest.entries(
                from: [(unplaced, "Episode", nil), (placed, "Episode", nil)], on: madeAt, calendar: utc)
            let markdown = TodaysMarginsDigest.markdown(entries, day: madeAt, calendar: utc, locale: posix)
            XCTAssertFalse(markdown.contains("about 0%"), markdown)
            XCTAssertFalse(markdown.contains("00:00"), markdown)
            XCTAssertTrue(markdown.contains("> Words for unplaced."), markdown)
            // The heading is followed straight by a blank line: no "where" line under it.
            XCTAssertTrue(markdown.contains("Episode\n\n> Words for unplaced."), markdown)
        }
    }

    // MARK: Playback Margins list

    func testThePlaybackListPutsAnUnplacedMarginLastWithNoPosition() {
        for media in [true, false] {
            let entries = MarginCollection.Entries(
                privateRows: [
                    entry(margin("unplaced", unplaced: true, media: media)),
                    entry(margin("late", unplaced: false, media: media, at: 900_000, char: 900)),
                    entry(margin("early", unplaced: false, media: media, at: 5_000, char: 10)),
                ],
                sharedRows: [])
            let rows = PlaybackMarginsList.rows(itemID: "item", entries: entries, filter: .all)
            XCTAssertEqual(rows.map(\.id), ["session::early", "session::late", "session::unplaced"], "media: \(media)")
            XCTAssertNil(rows.last?.position, "media: \(media). The row has no clock or offset to show or seek to")
            XCTAssertNotNil(rows.first?.position)
        }
    }

    // MARK: Notebook

    func testTheNotebookFilesAnUnplacedMarginUnderNotPlacedYet() {
        let minute = 60_000
        let media = ItemNotebook.build(
            unit: .media, end: 95 * minute,
            ownMargins: [margin("unplaced", unplaced: true, media: true), margin("placed", unplaced: false, media: true, at: 3 * minute)])
        XCTAssertEqual(media.sections.map(\.kind), [.span, .notPlacedYet])
        XCTAssertEqual(media.sections.last?.entries.map(\.marginID), ["unplaced"])
        XCTAssertEqual(media.sections.first?.entries.map(\.marginID), ["placed"], "no \"0–10 min\" entry for zeros")

        let text = ItemNotebook.build(
            unit: .text, end: 900,
            ownMargins: [margin("unplaced", unplaced: true, media: false), margin("placed", unplaced: false, media: false, char: 120)])
        XCTAssertEqual(text.sections.map(\.kind), [.span, .notPlacedYet])
        XCTAssertEqual(text.sections.last?.entries.map(\.marginID), ["unplaced"])
        XCTAssertEqual(text.sections.first?.entries.map(\.marginID), ["placed"])
    }

    // MARK: Notes-folder item note

    func testTheItemNoteListsAnUnplacedMarginAfterThePlacedOnesAndTheExportFlagsIt() throws {
        let item = Item(id: "item", title: "Episode", mediaType: "audio", text: nil, externalReference: nil, status: "ready")
        let session = Session(id: "session", itemId: "item", status: "completed", phase: .itemPlayback,
                              currentTargetType: .transcriptBackedMedia, currentTargetId: "item",
                              position: Position(), completionPercent: 100, playbackRate: 1)
        let margins = [
            margin("a-unplaced", unplaced: true, media: true, created: -900),
            margin("b-late", unplaced: false, media: true, at: 600_000, created: -300),
            margin("c-early", unplaced: false, media: true, at: 60_000, created: -100),
        ]
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: Dictionary(uniqueKeysWithValues: margins.map { ($0.id, $0) }))
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "unplaced", displayName: "Unplaced", capabilities: [:]), repository: repository)
        let export = try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false))

        let flagged = Dictionary(uniqueKeysWithValues: export.interjections.map { ($0.id, $0.hasPlace) })
        XCTAssertEqual(flagged, ["a-unplaced": false, "b-late": true, "c-early": true])
        let placedJSON = try String(decoding: JSONEncoder().encode(try XCTUnwrap(export.interjections.first { $0.id == "c-early" })), as: UTF8.self)
        XCTAssertFalse(placedJSON.contains("noPlace"), "a placed Margin's export is unchanged: \(placedJSON)")

        let ordered = ItemMarginNote.inListeningOrder(export).timeline.compactMap(\.interjectionId)
        XCTAssertEqual(ordered, ["c-early", "b-late", "a-unplaced"])
    }

    // MARK: Other readers of a Margin's place

    func testAnUnplacedMarginIsNotAStartingPlaceForANewMarginOrALiveSessionLineUp() {
        for media in [true, false] {
            let unplaced = margin("unplaced", unplaced: true, media: media)
            let placed = margin("placed", unplaced: false, media: media, at: 90_000, char: 400)
            XCTAssertNil(MarginCaptureHandoff(localMargin: unplaced).place, "media: \(media). A reply would start at zero")
            XCTAssertNotNil(MarginCaptureHandoff(localMargin: placed).place, "media: \(media)")
            XCTAssertNil(LiveSessionRecord.CurrentMargin(unplaced), "media: \(media). \"offsetMs 0\" would be made up")
            XCTAssertNotNil(LiveSessionRecord.CurrentMargin(placed), "media: \(media)")
        }
    }

    // MARK: PDF upgrade (real SQLite)

    func testAPDFUpgradeCarriesAnUnplacedMarginAcrossUnchanged() throws {
        for anchorType in [AnchorType.text, .media] {
            let fixture = try PDFReimportFixture()
            defer { fixture.remove() }
            try fixture.addReadingSession()
            var unplaced = margin("ij-moved", unplaced: true, media: anchorType == .media)
            unplaced.itemId = fixture.v1.id
            unplaced.targetId = fixture.v1.id
            unplaced.sessionId = "session-reading"
            unplaced.movedOrigin = nil
            try fixture.store.saveInterjection(unplaced)
            try fixture.store.saveMovedMarginOrigin(origin(of: unplaced))

            let planned = try fixture.plan()
            guard case .success = planned else {
                return XCTFail("\(anchorType): the upgrade must not stop for a Margin with no place: \(planned)")
            }
            _ = try fixture.reimport()

            let after = Dictionary(uniqueKeysWithValues: try fixture.store.loadInterjections(sessionId: "session-reading").map { ($0.id, $0) })
            let kept = try XCTUnwrap(after["ij-moved"], "\(anchorType): the Margin survived the upgrade")
            XCTAssertFalse(kept.hasPlace, "\(anchorType): its origin is still attached")
            XCTAssertEqual(kept.anchor, unplaced.anchor, "\(anchorType): the zeros are not moved to a range in the new text")
            XCTAssertEqual(kept.roughPercent, 0)
            XCTAssertEqual(kept.displayText, unplaced.displayText)
            XCTAssertNotNil(try fixture.store.loadStructuredDocument(itemId: fixture.v1.id), "\(anchorType): the item did upgrade")
            XCTAssertNotEqual(after["ij-001"]?.anchor.startChar, 0, "\(anchorType): its placed neighbours still move with the text")
        }
    }
}
