import Foundation
import XCTest
@testable import SessionKit

/// #1991: the Today's Margins shortcut's text. Pure rules: which Margins count for a day, their order, their words
/// and places, and the Markdown they come out as.
final class TodaysMarginsDigestTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func margin(
        _ id: String, at created: Date, words: String? = "words", cleaned: String? = nil, written: Bool = true,
        status: String = "active", media: Int? = nil, percent: Int = 40, target: InterjectionTargetType = .item
    ) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: target, targetId: "item", createdAt: created,
            roughPercent: percent,
            anchor: Anchor(anchorType: media == nil ? .text : .media, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: "", mediaTimeMs: media),
            audioPath: nil, audioStatus: written ? "discarded" : "available", transcriptionStatus: "transcribed",
            transcript: words, cleanedTranscript: cleaned, displayText: words, status: status,
            captureKind: written ? .written : .audio)
    }

    private func entries(_ margins: [Interjection], on day: Date, in calendar: Calendar, session: Session? = nil) -> [TodaysMarginsDigest.Entry] {
        TodaysMarginsDigest.entries(from: margins.map { ($0, "Title", session) }, on: day, calendar: calendar)
    }

    // MARK: Which Margins count

    /// The day is the listener's local day: the last second before midnight is in, midnight is the next day, in a zone
    /// that is behind UTC and one that is ahead of it.
    func testTheDayRunsFromLocalMidnightToLocalMidnight() {
        for zone in ["UTC", "America/Chicago", "Pacific/Auckland"] {
            let calendar = calendar(zone)
            let start = calendar.startOfDay(for: date("2026-11-12T15:00:00Z"))
            let next = calendar.date(byAdding: .day, value: 1, to: start)!
            let found = entries([
                margin("before", at: start.addingTimeInterval(-1)),
                margin("first", at: start),
                margin("last", at: next.addingTimeInterval(-1)),
                margin("after", at: next),
            ], on: start.addingTimeInterval(3_600), in: calendar)
            XCTAssertEqual(found.map(\.id), ["first", "last"], zone)
        }
    }

    /// A day with 25 hours (the clocks go back) still ends at local midnight.
    func testTheDayWhenTheClocksGoBackHasTwentyFiveHours() {
        let chicago = calendar("America/Chicago")
        let start = chicago.startOfDay(for: date("2026-11-01T12:00:00Z"))
        let late = start.addingTimeInterval(24.5 * 3_600)
        let found = entries([margin("late", at: late), margin("next", at: start.addingTimeInterval(25 * 3_600))], on: start, in: chicago)
        XCTAssertEqual(found.map(\.id), ["late"])
    }

    func testOnlyActiveMarginsCount() {
        let calendar = calendar("UTC")
        let now = date("2026-11-12T10:00:00Z")
        let found = entries([margin("kept", at: now), margin("gone", at: now, status: "deleted"), margin("other", at: now, status: "archived")], on: now, in: calendar)
        XCTAssertEqual(found.map(\.id), ["kept"])
    }

    /// A written Margin with no words has nothing to say; a spoken one still counts before its transcript arrives.
    func testAWrittenMarginWithoutWordsIsLeftOutAndASpokenOneIsKept() {
        let calendar = calendar("UTC")
        let now = date("2026-11-12T10:00:00Z")
        let found = entries([
            margin("blank-written", at: now, words: "  \n "),
            margin("nil-written", at: now, words: nil),
            margin("pending-spoken", at: now.addingTimeInterval(1), words: nil, written: false),
        ], on: now, in: calendar)
        XCTAssertEqual(found.map(\.id), ["pending-spoken"])
        XCTAssertEqual(found.first?.words, "")
        XCTAssertEqual(found.first?.isSpoken, true)
    }

    /// Before #624 a Margin's date was a counter (1 second after 1970); it is read as its session's start, as the notes
    /// folder reads it, so it lands on the session's day and not on 1 January 1970.
    func testAMarginWithAnOldCounterDateIsDatedByItsSession() {
        let calendar = calendar("UTC")
        let sessionStart = date("2026-11-12T08:00:00Z")
        let session = Session(
            id: "session", itemId: "item", createdAt: sessionStart, updatedAt: sessionStart, status: "in_progress",
            phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "item", position: Position(),
            completionPercent: 0, playbackRate: 1)
        let counter = margin("counter", at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(entries([counter], on: sessionStart, in: calendar, session: session).map(\.id), ["counter"])
        XCTAssertEqual(entries([counter], on: sessionStart, in: calendar, session: nil).map(\.id), [], "no session: it stays in 1970")
    }

    // MARK: Order

    func testMarginsComeInTheOrderTheyWereMadeAcrossItems() {
        let calendar = calendar("UTC")
        let noon = date("2026-11-12T12:00:00Z")
        let candidates: [(margin: Interjection, itemTitle: String, session: Session?)] = [
            (margin("b-late", at: noon.addingTimeInterval(60)), "Beta", nil),
            (margin("a-same-2", at: noon), "Alpha", nil),
            (margin("a-same", at: noon), "Alpha", nil),
            (margin("c-early", at: noon.addingTimeInterval(-3_600)), "Gamma", nil),
        ]
        let found = TodaysMarginsDigest.entries(from: candidates, on: noon, calendar: calendar)
        XCTAssertEqual(found.map(\.id), ["c-early", "a-same", "a-same-2", "b-late"])
        XCTAssertEqual(found.map(\.itemTitle), ["Gamma", "Alpha", "Alpha", "Beta"])
    }

    // MARK: Live and quick sessions

    private func liveMargin(
        _ id: String, at markedAt: Date, text: String = "words", audio: String? = nil, whereNote: String? = nil,
        offsetMs: Int = 90_000, place: LiveSessionPlace? = nil, blind: Bool = false
    ) -> LiveSessionMargin {
        var margin = LiveSessionMargin(
            id: id, text: text, markedAt: markedAt, sessionOffsetMs: offsetMs, whereNote: whereNote, isBlindMark: blind)
        margin.audioPath = audio
        margin.place = place
        return margin
    }

    func testLiveAndQuickSessionMarginsCountForTheDayAndMergeInOrder() {
        let calendar = calendar("UTC")
        let noon = date("2026-11-12T12:00:00Z")
        var meeting = LiveSession(id: "m", kind: .meeting, title: "  Budget review ", startedAt: noon)
        meeting.margins = [
            liveMargin("m-late", at: noon.addingTimeInterval(120), text: "  late words ", whereNote: " page 118 "),
            liveMargin("m-yesterday", at: noon.addingTimeInterval(-86_400)),
            liveMargin("m-blind", at: noon, text: "  ", blind: true),
            liveMargin("m-spoken", at: noon.addingTimeInterval(60), text: "", audio: "SpokenMargins/interjections/x.m4a"),
        ]
        var quick = LiveSession(id: "q", kind: .other, startedAt: noon, isQuick: true)
        quick.margins = [liveMargin("q1", at: noon.addingTimeInterval(30), place: LiveSessionPlace(unit: .percent, value: 40))]
        var untitled = LiveSession(id: "p", kind: .paper, startedAt: noon)
        untitled.margins = [liveMargin("p1", at: noon.addingTimeInterval(150), offsetMs: 3_725_000)]
        let library = TodaysMarginsDigest.entries(
            from: [(margin("lib", at: noon.addingTimeInterval(45)), "Library Item", nil)], on: noon, calendar: calendar)

        let live = TodaysMarginsDigest.entries(fromLiveSessions: [meeting, quick, untitled], on: noon, calendar: calendar)
        let day = TodaysMarginsDigest.ordered(library + live)

        XCTAssertEqual(day.map(\.id), ["q1", "lib", "m-spoken", "m-late", "p1"])
        XCTAssertEqual(day.map(\.itemTitle), ["Quick session", "Library Item", "Budget review", "Budget review", "Paper book session"])
        XCTAssertEqual(day.map(\.place), ["40%", "about 40% through", "01:30 into the session", "page 118", "1:02:05 into the session"])
        XCTAssertEqual(day.first { $0.id == "m-late" }?.words, "late words")
        XCTAssertEqual(day.first { $0.id == "m-spoken" }?.isSpoken, true)
        XCTAssertEqual(day.first { $0.id == "m-spoken" }?.words, "")
    }

    /// A saved session's Margins are on its Library item and counted there, so it adds nothing here.
    func testASessionSavedAsALibraryItemIsNotCountedTwice() {
        let noon = date("2026-11-12T12:00:00Z")
        var saved = LiveSession(id: "s", kind: .meeting, startedAt: noon, savedItemId: "item")
        saved.margins = [liveMargin("s1", at: noon)]
        XCTAssertEqual(TodaysMarginsDigest.entries(fromLiveSessions: [saved], on: noon, calendar: calendar("UTC")), [])
    }

    func testLiveSessionMarginsFollowTheLocalDay() {
        let chicago = calendar("America/Chicago")
        let start = chicago.startOfDay(for: date("2026-11-12T15:00:00Z"))
        var session = LiveSession(id: "s", kind: .meeting, startedAt: start)
        session.margins = [
            liveMargin("before", at: start.addingTimeInterval(-1)), liveMargin("first", at: start),
            liveMargin("last", at: start.addingTimeInterval(86_399)), liveMargin("after", at: start.addingTimeInterval(86_400)),
        ]
        let found = TodaysMarginsDigest.entries(fromLiveSessions: [session], on: start, calendar: chicago)
        XCTAssertEqual(Set(found.map(\.id)), ["first", "last"])
    }

    // MARK: Margins saved from a live session

    /// Saving a live session stamps each Margin in the database with the save time. The digest uses the time it was
    /// made, from the session's record: a Margin made at 10:05 and saved at 16:00 sorts at 10:05, and one saved the next
    /// morning is counted on the day it was made and not on the day it was saved.
    func testAMarginSavedFromALiveSessionIsDatedByWhenItWasMade() {
        let calendar = calendar("UTC")
        let day = date("2026-11-12T12:00:00Z")
        let madeMorning = date("2026-11-12T10:05:00Z")
        let saved = date("2026-11-13T09:00:00Z")
        var session = LiveSession(id: "live", kind: .meeting, startedAt: madeMorning, savedItemId: "item")
        session.margins = [liveMargin("live-1", at: madeMorning)]
        let record = LiveSessionRecord(itemId: "item", session: session, transcript: nil, placed: [], savedMarginIds: ["live-1": "stored-1"])
        let madeAt = TodaysMarginsDigest.madeAt(records: [record])
        XCTAssertEqual(madeAt, ["stored-1": madeMorning])
        // The database copy carries the save time, a day later.
        let stored = margin("stored-1", at: saved)
        let another = margin("lib-noon", at: date("2026-11-12T11:00:00Z"))

        let made = TodaysMarginsDigest.entries(
            from: [(stored, "Meeting item", nil), (another, "Other", nil)], on: day, calendar: calendar, madeAt: madeAt)
        XCTAssertEqual(made.map(\.id), ["stored-1", "lib-noon"], "10:05 comes before 11:00")
        XCTAssertEqual(made.first?.takenAt, madeMorning)

        let nextDay = TodaysMarginsDigest.entries(
            from: [(stored, "Meeting item", nil)], on: saved, calendar: calendar, madeAt: madeAt)
        XCTAssertEqual(nextDay, [], "saved on the 13th, made on the 12th: not a Margin of the 13th")
        let withoutRecord = TodaysMarginsDigest.entries(from: [(stored, "Meeting item", nil)], on: saved, calendar: calendar)
        XCTAssertEqual(withoutRecord.map(\.id), ["stored-1"], "with no record the stored time is all there is")
    }

    func testRecordsWithoutLinksAndLinksToUnknownMarginsAddNothing() {
        let now = date("2026-11-12T10:00:00Z")
        var session = LiveSession(id: "live", kind: .meeting, startedAt: now, savedItemId: "item")
        session.margins = [liveMargin("live-1", at: now)]
        let oldRecord = LiveSessionRecord(itemId: "item", session: session, transcript: nil, placed: [])
        let strayLink = LiveSessionRecord(itemId: "item", session: session, transcript: nil, placed: [], savedMarginIds: ["gone": "stored-x"])
        XCTAssertEqual(TodaysMarginsDigest.madeAt(records: [oldRecord, strayLink]), [:])
    }

    /// The real record files: `save(in:)` writes them, `loadAll` reads every one back, and a file that isn't a record
    /// is skipped and left alone.
    func testSavedRecordsReadBackFromTheirFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "records-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let made = date("2026-11-12T10:05:00Z")
        for (itemId, liveId, storedId) in [("item-a", "a1", "sa1"), ("item-b", "b1", "sb1")] {
            var session = LiveSession(id: "live-\(itemId)", kind: .meeting, startedAt: made, savedItemId: itemId)
            session.margins = [liveMargin(liveId, at: made)]
            try LiveSessionRecord(itemId: itemId, session: session, transcript: nil, placed: [], savedMarginIds: [liveId: storedId])
                .save(in: directory)
        }
        let folder = directory.appending(path: "LiveSessions", directoryHint: .isDirectory)
        try Data("not json".utf8).write(to: folder.appending(path: "broken.json"))
        XCTAssertEqual(LiveSessionRecord.loadAll(from: directory).count, 2)
        XCTAssertEqual(TodaysMarginsDigest.madeAt(records: LiveSessionRecord.loadAll(from: directory)), ["sa1": made, "sb1": made])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "broken.json").path))
        XCTAssertEqual(LiveSessionRecord.loadAll(from: directory.appending(path: "missing")), [])
    }

    // MARK: Words and places

    func testWordsFollowTheNotesFolderRule() {
        let now = Date()
        XCTAssertEqual(TodaysMarginsDigest.words(of: margin("w", at: now, words: "  typed \n", cleaned: "ignored")), "typed", "written: its own text")
        XCTAssertEqual(TodaysMarginsDigest.words(of: margin("s", at: now, words: "raw words", cleaned: "Clean words.", written: false)), "Clean words.")
        XCTAssertEqual(TodaysMarginsDigest.words(of: margin("r", at: now, words: "raw words", cleaned: nil, written: false)), "raw words")
        XCTAssertEqual(TodaysMarginsDigest.words(of: margin("n", at: now, words: nil, written: false)), "")
    }

    func testPlacesAreInTheListenersTerms() {
        let now = Date()
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("m", at: now, media: 724_000)), "at 12:04")
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("h", at: now, media: 3_725_000)), "at 1:02:05")
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("t", at: now, percent: 34)), "about 34% through")
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("hi", at: now, percent: 180)), "about 100% through")
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("lo", at: now, percent: -5)), "about 0% through")
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("s", at: now, target: .summaryTurn)), "on the summary")
        XCTAssertEqual(TodaysMarginsDigest.place(of: margin("a", at: now, target: .assistantTurn)), "on an answer")
    }

    // MARK: Markdown

    func testTheMarkdownForADay() {
        let calendar = calendar("UTC")
        let day = date("2026-11-12T09:00:00Z")
        let found = TodaysMarginsDigest.entries(from: [
            (margin("one", at: date("2026-11-12T09:14:00Z"), words: "Check this against the 2019 paper.", media: 724_000), "The Long Episode", nil),
            (margin("two", at: date("2026-11-12T21:05:00Z"), words: nil, written: false), "An Article", nil),
        ], on: day, calendar: calendar)
        let expected = """
        # Margins for Thu 12 Nov 2026

        2 Margins.

        ## 09:14 · The Long Episode
        at 12:04

        > Check this against the 2019 paper.

        ## 21:05 · An Article
        about 40% through

        > (Spoken Margin, not written out yet.)

        """
        XCTAssertEqual(TodaysMarginsDigest.markdown(found, day: day, calendar: calendar, locale: Locale(identifier: "en_US_POSIX")), expected)
    }

    func testAnEmptyDayAndASingleMargin() {
        let calendar = calendar("UTC")
        let day = date("2026-11-12T09:00:00Z")
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(
            TodaysMarginsDigest.markdown([], day: day, calendar: calendar, locale: locale),
            "# Margins for Thu 12 Nov 2026\n\nNo Margins today.\n")
        let one = TodaysMarginsDigest.entries(from: [(margin("x", at: day), "T", nil)], on: day, calendar: calendar)
        XCTAssertTrue(TodaysMarginsDigest.markdown(one, day: day, calendar: calendar, locale: locale).contains("\n1 Margin.\n"))
    }

    /// Neighbouring inputs for titles and words: Markdown marks, a newline in the title, an empty title, words that
    /// look like a heading, blank lines and Unicode.
    func testTitlesAndWordsCannotBreakTheDigestsStructure() {
        let calendar = calendar("UTC")
        let day = date("2026-11-12T09:00:00Z")
        let locale = Locale(identifier: "en_US_POSIX")
        let rows: [(title: String, words: String)] = [
            ("Plain", "Plain words."),
            ("snake_case *bold* [link](x) `code`", "words"),
            ("Two\nlines\r\nhere", "words"),
            ("   ", "words"),
            ("Café ☕ 日本語", "# Plan\r\n\r\n## Not a section\nlast line"),
            ("C# tips", "A > B"),
        ]
        let found = TodaysMarginsDigest.entries(
            from: rows.enumerated().map { index, row in (margin("m\(index)", at: day.addingTimeInterval(Double(index)), words: row.words), row.title, nil) },
            on: day, calendar: calendar)
        let text = TodaysMarginsDigest.markdown(found, day: day, calendar: calendar, locale: locale)
        let headings = text.components(separatedBy: "\n").filter { $0.hasPrefix("#") }
        XCTAssertEqual(headings.count, 1 + rows.count, "one title line and one section heading per Margin; no words became a heading")
        XCTAssertTrue(text.contains("## 09:00 · snake\\_case \\*bold\\* \\[link\\](x) \\`code\\`"))
        XCTAssertTrue(text.contains("· Two lines here\n"))
        XCTAssertTrue(text.contains("· Untitled\n"))
        XCTAssertTrue(text.contains("· Café ☕ 日本語\n"))
        XCTAssertTrue(text.contains("· C# tips\n"))
        XCTAssertTrue(text.contains("> # Plan\n>\n> ## Not a section\n> last line\n"))
        XCTAssertTrue(text.contains("> A > B\n"))
    }
}
