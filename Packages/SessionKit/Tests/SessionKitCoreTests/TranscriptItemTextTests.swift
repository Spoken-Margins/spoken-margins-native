import Foundation
import XCTest
@testable import SessionKit

/// #2997: the text a transcript becomes, where each cue sits in it, and the id and title it gets.
final class TranscriptItemTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func build(_ cues: [TranscriptCue], fileName: String = "meeting.vtt", title: String? = nil, start: Date? = nil) -> TranscriptItemText {
        TranscriptItemText.build(ImportedTranscript(format: .webVTT, cues: cues, absoluteStart: start, title: title), fileName: fileName, timeZone: utc)
    }

    private func cue(_ startMs: Int, _ speaker: String?, _ text: String) -> TranscriptCue {
        TranscriptCue(startMs: startMs, endMs: startMs + 1_000, speaker: speaker, text: text)
    }

    // MARK: Paragraphs

    func testAChangeOfSpeakerStartsAParagraphAndCuesOfATurnShareOne() {
        let item = build([cue(0, "Alice", "Welcome."), cue(2_000, "Alice", "Let's start."), cue(5_000, "Ben", "Thanks."), cue(7_000, "Alice", "Go on.")])
        XCTAssertEqual(item.text, "Alice: Welcome. Let's start.\n\nBen: Thanks.\n\nAlice: Go on.")
        XCTAssertEqual(item.cues.map(\.startChar), [0, 16, 30, 44])
    }

    func testCuesWithNoSpeakerFormOneUnnamedTurn() {
        let item = build([cue(0, nil, "One."), cue(2_000, nil, "Two."), cue(4_000, "Ben", "Three."), cue(6_000, nil, "Four.")])
        XCTAssertEqual(item.text, "One. Two.\n\nBen: Three.\n\nFour.")
    }

    func testATurnBreaksAMinuteAfterItsFirstCueAndTheContinuationHasNoName() {
        let item = build([
            cue(0, "Alice", "First."), cue(30_000, "Alice", "Second."), cue(59_999, "Alice", "Third."),
            cue(60_000, "Alice", "Fourth."), cue(100_000, "Alice", "Fifth."), cue(125_000, "Alice", "Sixth."), cue(130_000, "Ben", "Seventh.")
        ])
        XCTAssertEqual(item.text, "Alice: First. Second. Third.\n\nFourth. Fifth.\n\nSixth.\n\nBen: Seventh.")
    }

    func testEveryCueStartsWhereItsWordsAre() {
        let cues = [
            cue(0, "Zoe\u{0308}", "Hello, wörld 👩‍👩‍👧."), cue(1_000, "Zoë", "Second line, déjà vu."), cue(2_000, "Ben", "日本語のテキスト。"),
            cue(70_000, "Ben", "Later 🎉 and later."), cue(71_000, nil, "No name.")
        ]
        let item = build(cues)
        let characters = Array(item.text)
        XCTAssertEqual(item.cues.count, cues.count)
        for (built, source) in zip(item.cues, cues) {
            // The first cue of a paragraph starts at the name; the others start at their words.
            let tail = characters[built.startChar...]
            let named = Array((built.speaker.map { "\($0): " } ?? "") + source.text)
            XCTAssertTrue(tail.starts(with: Array(source.text)) || tail.starts(with: named), "\(source.text) at \(built.startChar)")
        }
        XCTAssertEqual(item.cues[1].startChar, "Zoë: Hello, wörld 👩‍👩‍👧. ".count)
        XCTAssertEqual(item.cues.map(\.speaker), ["Zoë", "Zoë", "Ben", "Ben", nil])
    }

    func testALeadingCombiningMarkDoesNotShiftTheOffsetsAfterIt() {
        // U+0301 merges into the space before it, so that cue's words start inside a character.
        let item = build([cue(0, "Zoe", "\u{0301}hi"), cue(1_000, "Zoe", "next"), cue(2_000, "Ben", "last")])
        let characters = Array(item.text)
        XCTAssertEqual(String(characters[item.cues[2].startChar...]), "Ben: last")
        XCTAssertEqual(String(characters[item.cues[1].startChar...].prefix(4)), "next")
    }

    func testTimesAreNeverWrittenIntoTheText() {
        let item = build([cue(3_723_000, "Alice", "Late in the meeting."), cue(3_724_000, "Ben", "Yes.")])
        XCTAssertFalse(item.text.contains("1:02"))
        XCTAssertEqual(item.cues.map(\.startMs), [3_723_000, 3_724_000])
        XCTAssertEqual(item.cues.map(\.endMs), [3_724_000, 3_725_000])
    }

    func testAnEmptyTranscriptBuildsEmptyText() {
        let item = build([])
        XCTAssertEqual(item.text, "")
        XCTAssertTrue(item.cues.isEmpty)
        XCTAssertEqual(item.title, "meeting")
    }

    func testTenThousandCuesBuildInUnderASecond() throws {
        let cues = (0..<10_000).map { cue($0 * 1_000, "Speaker \($0 % 4)", "This is sentence number \($0) of a long meeting.") }
        let started = Date()
        let item = build(cues)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(item.cues.count, 10_000)
        XCTAssertEqual(item.cues.last.map { Array(item.text)[$0.startChar...].starts(with: Array("Speaker 3: ")) }, true)
    }

    // MARK: Id

    func testTheSameBytesGiveTheSameTextAndId() throws {
        for (name, contents) in TranscriptFixtures.all {
            let first = TranscriptItemText.build(try TranscriptImport.parse(text: contents, timeZone: utc), fileName: name, timeZone: utc)
            let second = TranscriptItemText.build(try TranscriptImport.parse(data: Data(contents.utf8), timeZone: utc), fileName: name, timeZone: utc)
            XCTAssertEqual(first, second, name)
            XCTAssertTrue(first.id.hasPrefix("item-transcript-"), name)
            XCTAssertEqual(first.id.count, "item-transcript-".count + 24, name)
        }
    }

    /// A parser or builder change that moves these breaks the ids of items already imported, and the digests of
    /// packets made on them. It needs a maintainer's yes.
    func testTheIdsOfTheFixturesAreFrozen() throws {
        // All eight layouts carry one conversation, so they share one text and one id.
        for (name, contents) in TranscriptFixtures.all {
            let id = TranscriptItemText.build(try TranscriptImport.parse(text: contents, timeZone: utc), fileName: name, timeZone: utc).id
            XCTAssertEqual(id, "item-transcript-15a671faecec38cd99ca12d0", name)
        }
    }

    func testTheFixturesShareOneConversation() throws {
        let texts = try TranscriptFixtures.all.mapValues { TranscriptItemText.build(try TranscriptImport.parse(text: $0, timeZone: utc), fileName: "x", timeZone: utc).text }
        XCTAssertEqual(Set(texts.values).count, 1)
        XCTAssertEqual(texts.values.first, "Alice Example: Welcome everyone, let's start with the budget.\n\nBen Sample: Thanks. I have the draft numbers ready.\n\nAlice Example: Great, please share them.")
    }

    // MARK: Title and start

    func testTitleRules() throws {
        let plain = [cue(0, "A", "Hi.")]
        XCTAssertEqual(build(plain, fileName: "Zoom.vtt", title: "Budget sync").title, "Budget sync")
        XCTAssertEqual(build(plain, fileName: "Weekly review.transcript.vtt").title, "Weekly review")
        XCTAssertEqual(build(plain, fileName: "Q3 review.v2.vtt").title, "Q3 review.v2")
        XCTAssertEqual(build(plain, fileName: "notes.TXT").title, "notes")
        XCTAssertEqual(build(plain, fileName: "Minutes.docx").title, "Minutes")
        XCTAssertEqual(build(plain, fileName: "no extension").title, "no extension")
        XCTAssertEqual(build(plain, fileName: ".vtt").title, "Meeting transcript")
        XCTAssertEqual(build(plain, fileName: "").title, "Meeting transcript")
        XCTAssertEqual(build(plain, fileName: "x.vtt", title: "   ").title, "x")
    }

    func testAZoomFileNameGivesTheMeetingDateInThePhonesZone() throws {
        let plain = [cue(0, "A", "Hi.")]
        let item = build(plain, fileName: "GMT20261112-150000_Recording.transcript.vtt")
        XCTAssertEqual(item.meetingStart, ISO8601DateFormatter().date(from: "2026-11-12T15:00:00Z"))
        let chicago = TimeZone(identifier: "America/Chicago")!
        let local = TranscriptItemText.build(ImportedTranscript(format: .webVTT, cues: plain), fileName: "GMT20261112-150000_Recording.transcript.vtt", timeZone: chicago)
        XCTAssertTrue(local.title.hasPrefix("Meeting on "))
        XCTAssertTrue(local.title.contains("9:00") || local.title.contains("09:00"), local.title)
        XCTAssertNil(build(plain, fileName: "GMT2026111-150000.vtt").meetingStart)
        for impossible in ["GMT20261399-150000", "GMT20261112-256100", "GMT20260230-010101", "GMT20261112-240000"] {
            XCTAssertNil(build(plain, fileName: "\(impossible)_Recording.vtt").meetingStart, impossible)
            XCTAssertEqual(build(plain, fileName: "\(impossible)_Recording.vtt").title, "\(impossible)_Recording", impossible)
        }
        // A header title still wins over the file name, and a header date over the name's.
        let header = build(plain, fileName: "GMT20261112-150000_Recording.vtt", title: "Budget sync", start: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(header.title, "Budget sync")
        XCTAssertEqual(header.meetingStart, Date(timeIntervalSince1970: 1_000))
    }

    func testMeetingDateShowsTheYearOnlyWhenItIsNotThisYear() {
        let locale = Locale(identifier: "en_US")
        let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
        let thisYear = TranscriptItemText.meetingDateText(ISO8601DateFormatter().date(from: "2026-11-12T15:00:00Z")!, now: now, locale: locale, timeZone: utc)
        let lastYear = TranscriptItemText.meetingDateText(ISO8601DateFormatter().date(from: "2025-11-12T15:00:00Z")!, now: now, locale: locale, timeZone: utc)
        XCTAssertTrue(thisYear.contains("Thu") && thisYear.contains("Nov") && thisYear.contains("12"), thisYear)
        XCTAssertFalse(thisYear.contains("2026"), thisYear)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
    }
}
