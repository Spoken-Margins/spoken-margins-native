import Foundation
import XCTest
@testable import SessionKit

/// #4233, PR 2b: a Margin moved from a live session with no stored position never exports a place it does not have.
/// Markdown says "no place saved", the file name carries the capture time, the export's own fields are empty (not
/// zeros that read as 0% or 0:00), and it sorts after every Margin that has a place.
final class UnplacedMarginExportTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    // MARK: The export

    func testAnUnplacedMarginExportsNoPositionNoPassageAndTheNoPlaceMark() throws {
        let item = item()
        let margin = unplaced("u1", item: item, media: true)
        let export = try buildExport(engine(item: item, margins: [margin]), margin)
        let note = try XCTUnwrap(export.interjections.first)

        XCTAssertEqual(note.noPlace, true)
        XCTAssertFalse(note.hasPlace)
        XCTAssertNil(note.mediaTimeMs)
        XCTAssertNil(note.page)
        XCTAssertNil(note.sourceCharOffset)
        XCTAssertEqual(note.anchorBefore, "")
        XCTAssertEqual(note.anchorAfter, "")
    }

    func testAPlacedMarginIsExportedAsBefore() throws {
        let item = item()
        let margin = placed("p1", item: item, media: true, ms: 754_000, percent: 21)
        let note = try XCTUnwrap(try buildExport(engine(item: item, margins: [margin]), margin).interjections.first)

        XCTAssertNil(note.noPlace)
        XCTAssertTrue(note.hasPlace)
        XCTAssertEqual(note.mediaTimeMs, 754_000)
        XCTAssertEqual(note.roughPercent, 21)
    }

    func testTheSessionTimelineHasNoPercentForAnUnplacedMargin() throws {
        let item = item()
        let margins = [placed("p1", item: item, media: false, percent: 40), unplaced("u1", item: item, media: false)]
        let export = try engine(item: item, margins: margins).buildExport(options: ExportOptions(
            sessionId: "session-1", includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false, scope: "session"
        ))
        let entries = export.timeline.filter { $0.type == "interjection" }
        XCTAssertEqual(entries.first(where: { $0.interjectionId == "p1" })?.percent, 40)
        XCTAssertNil(entries.first(where: { $0.interjectionId == "u1" })?.percent)
    }

    // MARK: Markdown

    func testTheMarkdownNoteSaysNoPlaceSavedNeverZero() throws {
        for media in [true, false] {
            let item = item()
            let margin = unplaced("u1", item: item, media: media)
            let export = try buildExport(engine(item: item, margins: [margin]), margin)
            let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.createdAt)

            XCTAssertTrue(markdown.contains(SessionExportMarkdownRenderer.noPlaceSaved), markdown)
            XCTAssertFalse(markdown.contains("0%"), markdown)
            XCTAssertFalse(markdown.contains("0:00"), markdown)
            XCTAssertFalse(markdown.contains("00:00"), markdown)
            XCTAssertTrue(markdown.contains("Thought u1."), markdown)
        }
    }

    func testAPlacedMarginsNoteStillSaysItsClock() throws {
        let item = item()
        let margin = placed("p1", item: item, media: true, ms: 754_000, percent: 21)
        let export = try buildExport(engine(item: item, margins: [margin]), margin)
        let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.createdAt)

        XCTAssertFalse(markdown.contains(SessionExportMarkdownRenderer.noPlaceSaved), markdown)
        XCTAssertTrue(markdown.contains("12:34"), markdown)
    }

    func testAFullSessionExportListsAnUnplacedMarginLastAndSaysNoPlace() throws {
        let item = item()
        let margins = [
            unplaced("u1", item: item, media: false),
            placed("late", item: item, media: false, percent: 80, startChar: 8_000),
            placed("early", item: item, media: false, percent: 10, startChar: 1_000),
        ]
        let export = try engine(item: item, margins: margins).buildExport(options: ExportOptions(
            sessionId: "session-1", includeFullText: true, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false, scope: "session"
        ))
        let markdown = SessionExportMarkdownRenderer.render(export)

        let early = try XCTUnwrap(markdown.range(of: "Thought early."))
        let late = try XCTUnwrap(markdown.range(of: "Thought late."))
        let none = try XCTUnwrap(markdown.range(of: "Thought u1."))
        XCTAssertLessThan(early.lowerBound, late.lowerBound)
        XCTAssertLessThan(late.lowerBound, none.lowerBound, markdown)
        XCTAssertTrue(markdown.contains("No place saved"), markdown)
    }

    // MARK: File names

    func testAnUnplacedMarginsFileNameCarriesItsCaptureTime() throws {
        let item = item()
        let margin = unplaced("u1", item: item, media: true)
        let file = try XCTUnwrap(try MarginMarkdownShare.file(for: margin, engine: engine(item: item, margins: [margin])))

        let expected = MarginMarkdownShare.noPlaceName(createdAt: margin.createdAt)
        XCTAssertTrue(expected.hasPrefix("no place - "), expected)
        XCTAssertEqual(file.fileName, "Margin - An essay - \(expected).md")
        XCTAssertFalse(file.fileName.contains("0m00s"))
        XCTAssertFalse(file.fileName.contains(":"))
    }

    func testTwoUnplacedMarginsOnOneItemNeverShareAFileName() {
        let first = MarginMarkdownShare.noPlaceName(createdAt: createdAt)
        let second = MarginMarkdownShare.noPlaceName(createdAt: createdAt.addingTimeInterval(1))
        XCTAssertNotEqual(first, second)
    }

    func testTheNoPlaceNameFollowsTheGivenCalendarAndZone() throws {
        let utc = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        // 1_777_000_000 is 2026-04-24 03:06:40 UTC.
        XCTAssertEqual(MarginMarkdownShare.noPlaceName(createdAt: createdAt, calendar: calendar, timeZone: utc),
                       "no place - 2026-04-24 030640")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(MarginMarkdownShare.noPlaceName(createdAt: createdAt, calendar: calendar, timeZone: tokyo),
                       "no place - 2026-04-24 120640")
    }

    func testTheItemsMarginsFileJoinsUnplacedMarginsAfterPlacedOnes() throws {
        let item = item()
        let margins = [
            unplaced("u1", item: item, media: false, createdAt: createdAt),
            placed("late", item: item, media: false, percent: 80, startChar: 8_000),
            placed("early", item: item, media: false, percent: 10, startChar: 1_000),
            unplaced("u2", item: item, media: false, createdAt: createdAt.addingTimeInterval(30)),
        ]
        let file = try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine(item: item, margins: margins)))
        let notes = file.markdown.components(separatedBy: MarginMarkdownShare.separator)

        XCTAssertEqual(notes.count, 4)
        XCTAssertTrue(notes[0].contains("Thought early."), file.markdown)
        XCTAssertTrue(notes[1].contains("Thought late."), file.markdown)
        XCTAssertTrue(notes[2].contains("Thought u1."), file.markdown)
        XCTAssertTrue(notes[3].contains("Thought u2."), file.markdown)
        XCTAssertTrue(notes[2].contains(SessionExportMarkdownRenderer.noPlaceSaved), notes[2])
    }

    // MARK: Audio file name

    func testAnUnplacedMarginsAudioFileNameHasNoClock() throws {
        let item = item()
        let margin = unplaced("u1", item: item, media: true)
        let export = try buildExport(engine(item: item, margins: [margin]), margin)
        XCTAssertEqual(export.interjections.count, 1)
        let name = MarginExport.audioBaseName(itemTitle: item.title, margin: margin)
        XCTAssertTrue(name.contains("no place"), name)
        XCTAssertFalse(name.contains("0m00s"), name)
    }

    // MARK: Helpers

    private func buildExport(_ engine: SessionEngine, _ margin: Interjection) throws -> SessionExport {
        try engine.buildExport(options: ExportOptions(
            sessionId: margin.sessionId,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false,
            scope: "selected_interjections", interjectionIds: [margin.id]
        ))
    }

    private func item() -> Item {
        Item(id: "item-1", title: "An essay", mediaType: "text", text: "Source text.",
             externalReference: "https://example.com/essay", status: "ready")
    }

    private func placed(_ id: String, item: Item, media: Bool, ms: Int = 0, percent: Int, startChar: Int = 0) -> Interjection {
        Interjection(
            id: id, itemId: item.id, sessionId: "session-1", targetType: .item, targetId: item.id,
            createdAt: createdAt, roughPercent: percent,
            anchor: Anchor(anchorType: media ? .media : .text, startChar: startChar, endChar: startChar + 7,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: media ? ms : nil),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: "Thought \(id).", cleanedTranscript: nil, displayText: "Thought \(id).",
            status: "active", captureKind: nil)
    }

    private func unplaced(_ id: String, item: Item, media: Bool, createdAt: Date? = nil) -> Interjection {
        var margin = Interjection(
            id: id, itemId: item.id, sessionId: "session-1", targetType: .item, targetId: item.id,
            createdAt: createdAt ?? self.createdAt, roughPercent: 0,
            anchor: Anchor(anchorType: media ? .media : .text, startChar: 0, endChar: 0,
                           anchorBefore: "", anchorAfter: "", mediaTimeMs: media ? 0 : nil),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: "Thought \(id).", cleanedTranscript: nil, displayText: "Thought \(id).",
            status: "active", captureKind: nil)
        margin.movedOrigin = MovedMarginOrigin(
            marginId: id, itemId: item.id, sessionId: "session-1",
            liveMarginId: "live-\(id)", fromLiveSessionId: "live-quick", fromLiveSessionTitle: "Quick session",
            markedAt: margin.createdAt, movedAt: margin.createdAt.addingTimeInterval(60), placeKnown: false)
        return margin
    }

    private func engine(item: Item, margins: [Interjection]) -> SessionEngine {
        let session = Session(id: "session-1", itemId: item.id, createdAt: nil, status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .itemTextTTS, currentTargetId: item.id,
                              position: Position(), completionPercent: 0, playbackRate: 1)
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: Dictionary(uniqueKeysWithValues: margins.map { ($0.id, $0) })
        )
        return SessionEngine(
            profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
            repository: repository
        )
    }
}
