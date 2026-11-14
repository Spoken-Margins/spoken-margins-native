import Foundation
import XCTest
@testable import SessionKit

/// #2997 PR 2b: the words a transcript item adds to the Library row, the item screen and a Margin's place line.
final class TranscriptItemWordingTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    /// Thursday 12 Nov 2026, 15:00 UTC.
    private let thursday = Date(timeIntervalSince1970: 1_794_495_600)

    /// The meeting's date as `meetingDateText` writes it. The words of a localized date differ between ICU versions
    /// ("Thu 12 Nov, 15:00" on one, "Thu, 12 Nov at 15:00" on another), so the tests pin the line's parts and order
    /// and check the date text itself for its fields.
    private func date(_ date: Date, now: Date? = nil, timeZone: TimeZone? = nil) -> String {
        TranscriptItemText.meetingDateText(date, now: now ?? thursday, locale: gb, timeZone: timeZone ?? utc)
    }

    private func line(
        start: Date? = nil, timeOfDay: Int? = nil, durationMs: Int? = nil, speakers: [String] = [], now: Date? = nil
    ) -> String {
        TranscriptItemWording.meetingLine(
            start: start, timeOfDaySeconds: timeOfDay, durationMs: durationMs, speakers: speakers,
            now: now ?? thursday, locale: gb, timeZone: utc)
    }

    // MARK: Meeting line (the four rows of the Design table, and their neighbours)

    func testDateAndTimeWithSpeakers() {
        XCTAssertEqual(
            line(start: thursday, durationMs: 48 * 60_000, speakers: ["Priya Patel", "Sam Lee", "Ana", "Bo"]),
            "Meeting on \(date(thursday)) · 48 min · Priya Patel, Sam Lee and 2 others")
        let shown = date(thursday)
        for field in ["Thu", "12", "Nov", "15:00"] { XCTAssertTrue(shown.contains(field), "\(field) in \(shown)") }
    }

    func testTimeOfDayOnlyAsZoomCaptionsGiveIt() {
        XCTAssertEqual(
            line(timeOfDay: 15 * 3_600, durationMs: 48 * 60_000, speakers: ["Priya Patel", "Sam Lee"]),
            "Meeting at 15:00 · 48 min · Priya Patel and Sam Lee")
        XCTAssertEqual(line(timeOfDay: 9 * 3_600 + 5 * 60, durationMs: 60_000), "Meeting at 09:05 · 1 min")
    }

    func testNoStartAtAll() {
        XCTAssertEqual(line(durationMs: 48 * 60_000, speakers: ["Priya Patel"]), "Meeting · 48 min · Priya Patel")
    }

    func testDateAndTimeWithNoSpeakers() {
        XCTAssertEqual(line(start: thursday, durationMs: 48 * 60_000), "Meeting on \(date(thursday)) · 48 min")
    }

    func testTheLeastALineSaysIsMeeting() {
        XCTAssertEqual(line(), "Meeting")
        XCTAssertEqual(line(speakers: ["Priya Patel"]), "Meeting · Priya Patel")
    }

    func testADateWinsOverATimeOfDayAndAnImpossibleTimeOfDayIsLeftOut() {
        XCTAssertEqual(line(start: thursday, timeOfDay: 3_600, durationMs: 120_000), "Meeting on \(date(thursday)) · 2 min")
        XCTAssertEqual(line(timeOfDay: -5, durationMs: 120_000), "Meeting · 2 min")
        XCTAssertEqual(line(timeOfDay: 86_400, durationMs: 120_000), "Meeting · 2 min")
    }

    func testTheYearAppearsOnlyWhenTheMeetingWasNotThisYear() {
        let nextYear = thursday.addingTimeInterval(86_400 * 120)
        XCTAssertTrue(line(start: thursday, now: nextYear).contains("2026"))
        XCTAssertFalse(line(start: thursday, now: thursday).contains("2026"))
    }

    func testTheDateIsShownInTheGivenTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let text = TranscriptItemWording.meetingLine(
            start: thursday, timeOfDaySeconds: nil, durationMs: nil, speakers: [], now: thursday, locale: gb, timeZone: tokyo)
        XCTAssertEqual(text, "Meeting on \(date(thursday, timeZone: tokyo))")
        for field in ["Fri", "13", "Nov", "00:00"] { XCTAssertTrue(text.contains(field), "\(field) in \(text)") }
    }

    func testATimeOfDayReadsAsWrittenWhateverTheDevicesZone() {
        // Zoom's captions say 15:00 in the meeting's own zone; moving it to the phone's zone would be a wrong answer.
        XCTAssertEqual(
            TranscriptItemWording.meetingLine(
                start: nil, timeOfDaySeconds: 15 * 3_600, durationMs: nil, speakers: [], now: thursday, locale: gb,
                timeZone: TimeZone(identifier: "Asia/Tokyo")!),
            "Meeting at 15:00")
    }

    func testAnAmericanLocaleKeepsItsOwnClock() {
        let us = Locale(identifier: "en_US")
        let text = TranscriptItemWording.meetingLine(
            start: nil, timeOfDaySeconds: 15 * 3_600, durationMs: nil, speakers: [], now: thursday, locale: us, timeZone: utc)
        XCTAssertTrue(text.hasPrefix("Meeting at 3:00"), text)
        XCTAssertTrue(text.contains("PM"), text)
    }

    // MARK: Length

    func testLengthTable() {
        let cases: [(Int, String)] = [
            (0, "under 1 min"), (59_999, "under 1 min"), (60_000, "1 min"), (119_999, "1 min"),
            (48 * 60_000, "48 min"), (59 * 60_000 + 59_999, "59 min"), (3_600_000, "1 h"),
            (72 * 60_000, "1 h 12 min"), (3 * 3_600_000, "3 h"), (25 * 3_600_000 + 60_000, "25 h 1 min"),
        ]
        for (ms, expected) in cases { XCTAssertEqual(TranscriptItemWording.lengthText(durationMs: ms), expected, "\(ms) ms") }
        XCTAssertEqual(line(durationMs: 72 * 60_000), "Meeting · 1 h 12 min")
    }

    func testAMissingLengthLeavesThePartOut() {
        XCTAssertEqual(line(start: thursday, durationMs: nil, speakers: ["Ana"]), "Meeting on \(date(thursday)) · Ana")
    }

    // MARK: Speakers

    func testSpeakersTable() {
        let cases: [([String], String?)] = [
            ([], nil),
            (["", "  ", "\n"], nil),
            (["Ana"], "Ana"),
            (["Ana", "Bo"], "Ana and Bo"),
            (["Ana", "Bo", "Cy"], "Ana, Bo and 1 other"),
            (["Ana", "Bo", "Cy", "Di"], "Ana, Bo and 2 others"),
            (["Ana", "Ana", "Bo"], "Ana and Bo"),
            (["Ana", " ", "Bo", "Ana", "Cy"], "Ana, Bo and 1 other"),
            ([" Ana "], "Ana"),
        ]
        for (speakers, expected) in cases { XCTAssertEqual(TranscriptItemWording.speakersText(speakers), expected, "\(speakers)") }
    }

    func testTheSameNameInTwoUnicodeFormsIsOneSpeaker() {
        let nfc = "Zo\u{00EB} Hart", nfd = "Zoe\u{0308} Hart"
        XCTAssertEqual(TranscriptItemWording.speakersText([nfc, nfd]), "Zo\u{00EB} Hart")
    }

    // MARK: The meeting clock

    private let starts = [0, 40, 120, 121]
    private let times = [0, 5_000, 65_000, 70_000]

    func testTheClockIsTheLastCueAtOrBeforeTheMargin() {
        func clock(_ character: Int) -> Int? {
            TranscriptMeetingClock.clockMs(atCharacter: character, cueStartChars: starts, cueStartMs: times)
        }
        XCTAssertEqual(clock(0), 0)
        XCTAssertEqual(clock(39), 0)
        XCTAssertEqual(clock(40), 5_000)
        XCTAssertEqual(clock(119), 5_000)
        XCTAssertEqual(clock(120), 65_000)
        XCTAssertEqual(clock(121), 70_000)
        XCTAssertEqual(clock(10_000), 70_000, "past the last cue")
    }

    func testTheClockFallsBackOnOddInputs() {
        XCTAssertNil(TranscriptMeetingClock.clockMs(atCharacter: 5, cueStartChars: [], cueStartMs: []))
        XCTAssertNil(TranscriptMeetingClock.clockMs(atCharacter: -1, cueStartChars: starts, cueStartMs: times))
        XCTAssertNil(TranscriptMeetingClock.clockMs(atCharacter: 3, cueStartChars: [10], cueStartMs: [1_000]), "before the first cue")
        XCTAssertEqual(
            TranscriptMeetingClock.clockMs(atCharacter: 500, cueStartChars: [0, 10, 20], cueStartMs: [0, 1_000]), 1_000,
            "arrays of different lengths use the shorter")
    }

    func testAMarginAtASeparatorOrInsideANamePrefixGetsTheRightClock() {
        // "Ana: Hello there." is 17 characters; a blank line follows; "Bo: Hi." starts at 19.
        let transcript = ImportedTranscript(format: .webVTT, cues: [
            TranscriptCue(startMs: 1_000, endMs: 3_000, speaker: "Ana", text: "Hello there."),
            TranscriptCue(startMs: 4_000, endMs: 6_000, speaker: "Bo", text: "Hi."),
        ])
        let built = TranscriptItemText.build(transcript, fileName: "m.vtt", timeZone: utc)
        XCTAssertEqual(built.text, "Ana: Hello there.\n\nBo: Hi.")
        XCTAssertEqual(built.cues.map(\.startChar), [0, 19])
        func clock(_ character: Int) -> Int? { TranscriptMeetingClock.clockMs(atCharacter: character, cues: built.cues) }
        XCTAssertEqual(clock(0), 1_000, "inside Ana's name")
        XCTAssertEqual(clock(2), 1_000)
        XCTAssertEqual(clock(5), 1_000, "her first word")
        XCTAssertEqual(clock(17), 1_000, "the blank line belongs to the paragraph before it")
        XCTAssertEqual(clock(18), 1_000)
        XCTAssertEqual(clock(19), 4_000, "Bo's name")
        XCTAssertEqual(clock(22), 4_000)
    }

    // MARK: Place line

    private let tuesday = Date(timeIntervalSince1970: 1_791_288_000)

    private func placeLine(
        placeName: String? = nil, mediaTimeMs: Int? = nil, meetingClockMs: Int? = nil, paragraph: Int? = nil
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return MarginRowWording.placeLine(
            placeName: placeName, mediaTimeMs: mediaTimeMs, meetingClockMs: meetingClockMs, paragraph: paragraph,
            roughPercent: 42, createdAt: tuesday, now: tuesday, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    func testAMeetingClockReplacesTheParagraphNumber() {
        XCTAssertEqual(placeLine(placeName: "Budget", meetingClockMs: 760_000, paragraph: 14), "Budget · 12:40 · Tue")
        XCTAssertEqual(placeLine(meetingClockMs: 3_760_000, paragraph: 14), "1:02:40 · Tue")
        XCTAssertEqual(placeLine(meetingClockMs: 0, paragraph: 3), "00:00 · Tue", "the first cue is a clock too")
    }

    func testOtherPlaceLinesAreUnchangedAndAMediaTimeStillWins() {
        XCTAssertEqual(placeLine(paragraph: 14), "paragraph 14 · Tue")
        XCTAssertEqual(placeLine(mediaTimeMs: 1_263_000, meetingClockMs: 5_000), "21:03 · Tue")
        XCTAssertEqual(placeLine(), "42% · Tue")
    }

    func testAPlaceCanCarryOnlyAClock() {
        let place = MarginPlaces.Place(chapterName: nil, paragraph: nil, meetingClockMs: 5_000)
        XCTAssertEqual(place.meetingClockMs, 5_000)
        XCTAssertNil(MarginPlaces.Place(chapterName: "A", paragraph: 1).meetingClockMs)
    }

    // MARK: Library row, noun and icon

    func testTheRowSaysTranscriptWithASpeechBubbleAndStaysUnderText() {
        let transcript = TranscriptItemText.referenceType
        XCTAssertEqual(
            LibraryRowWording.kindLabel(mediaType: "text", sourceReference: "Budget sync.vtt", sourceReferenceType: transcript, usesNewReader: false),
            "Transcript")
        XCTAssertEqual(LibraryRowWording.contentType(mediaType: "text", sourceReference: "Budget sync.vtt", sourceReferenceType: transcript), .text)
        let row = LibraryItemRow(
            id: "i", title: "Budget sync", status: "needs_listening_map", canDelete: true, mediaType: "text",
            sourceReference: "Budget sync.vtt", sourceReferenceType: transcript)
        XCTAssertEqual(row.mediaSymbol, "text.bubble")
        XCTAssertEqual(SourceNoun(mediaType: "text", sourceReference: "Budget sync.vtt", sourceReferenceType: transcript), .transcript)
        XCTAssertEqual(SourceNoun.transcript.capitalized, "Transcript")
        XCTAssertEqual(SourceNoun.transcript.inSentence, "transcript")
    }

    func testAFileNamedLikeAPDFIsStillATranscript() {
        let transcript = TranscriptItemText.referenceType
        for name in ["notes.pdf.txt", "Paper.PDF.vtt", "a.epub.srt"] {
            XCTAssertEqual(LibraryRowWording.contentType(mediaType: "text", sourceReference: name, sourceReferenceType: transcript), .text, name)
            XCTAssertEqual(
                LibraryRowWording.kindLabel(mediaType: "text", sourceReference: name, sourceReferenceType: transcript, usesNewReader: false),
                "Transcript", name)
        }
    }

    func testEveryOtherRowKeepsItsWords() {
        let table: [(String, String?, String?, String, String, String)] = [
            ("text", nil, nil, "Text", "doc.text", "Text"),
            ("text", "Notes.txt", "file", "Text", "doc.text", "Text"),
            ("text", "Paper.pdf", "file", "PDF", "doc.text", "PDF"),
            ("text", "https://example.com/a", "url", "Article", "doc.text", "Article"),
            ("pdf", nil, nil, "PDF", "doc.richtext", "PDF"),
            ("epub", nil, "epub", "EPUB", "book.closed", "Book"),
            ("audiobook", nil, nil, "Audiobook", "headphones", "Audiobook"),
        ]
        for (media, reference, type, kind, symbol, noun) in table {
            XCTAssertEqual(LibraryRowWording.kindLabel(mediaType: media, sourceReference: reference, sourceReferenceType: type, usesNewReader: false), kind, media)
            XCTAssertEqual(
                LibraryItemRow(id: "i", title: "T", status: "s", canDelete: true, mediaType: media, sourceReference: reference, sourceReferenceType: type).mediaSymbol,
                symbol, media)
            XCTAssertEqual(SourceNoun(mediaType: media, sourceReference: reference, sourceReferenceType: type).capitalized, noun, media)
        }
    }
}
