import Foundation
import XCTest
@testable import SessionKit

/// #2481: every meeting transcript layout reads into the same cues, and Margins line up with them.
final class TranscriptImportTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let texts = [
        "Welcome everyone, let's start with the budget.",
        "Thanks. I have the draft numbers ready.",
        "Great, please share them."
    ]
    private let speakers = ["Alice Example", "Ben Sample", "Alice Example"]

    // MARK: Parsing

    func testEveryFixtureNormalizesToTheSameConversation() throws {
        XCTAssertEqual(TranscriptFixtures.all.count, 8)
        for (name, contents) in TranscriptFixtures.all {
            let transcript = try TranscriptImport.parse(text: contents, timeZone: utc)
            XCTAssertEqual(transcript.cues.map(\.text), texts, name)
            XCTAssertEqual(transcript.cues.map(\.speaker), speakers, name)
            let starts = transcript.cues.map(\.startMs)
            // Exact times where the format keeps milliseconds, whole seconds otherwise, and the wall-clock
            // captions count from their first line.
            if name.hasSuffix(".vtt") || name.hasSuffix(".srt") {
                XCTAssertEqual(starts, [3_500, 6_500, 9_500], name)
            } else if name == "zoom-captions.txt" {
                XCTAssertEqual(starts, [0, 3_000, 6_000], name)
            } else {
                XCTAssertEqual(starts, [3_000, 6_000, 9_000], name)
            }
            XCTAssertTrue(transcript.cues.allSatisfy { $0.endMs != nil } || transcript.cues.last?.endMs == nil, name)
        }
    }

    func testFormatsAreDetectedByContent() throws {
        XCTAssertEqual(try TranscriptImport.parse(text: TranscriptFixtures.all["teams.vtt"]!).format, .webVTT)
        XCTAssertEqual(try TranscriptImport.parse(text: TranscriptFixtures.all["generic.srt"]!).format, .srt)
        XCTAssertEqual(try TranscriptImport.parse(text: TranscriptFixtures.all["otter.txt"]!).format, .plainText)
    }

    func testHeaderDatesGiveTheAbsoluteStart() throws {
        let expected = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")
        for name in ["meet.txt", "otter.txt", "teams-docx.txt"] {
            let transcript = try TranscriptImport.parse(text: TranscriptFixtures.all[name]!, timeZone: utc)
            XCTAssertEqual(transcript.absoluteStart, expected, name)
        }
        XCTAssertEqual(try TranscriptImport.parse(text: TranscriptFixtures.all["meet.txt"]!, timeZone: utc).title, "Budget sync")
        for name in ["teams.vtt", "zoom.vtt", "webex.vtt", "generic.srt", "zoom-captions.txt"] {
            XCTAssertNil(try TranscriptImport.parse(text: TranscriptFixtures.all[name]!, timeZone: utc).absoluteStart, name)
        }
        XCTAssertEqual(try TranscriptImport.parse(text: TranscriptFixtures.all["zoom-captions.txt"]!).startTimeOfDaySeconds, 36_003)
    }

    func testMeetZoneIsHonouredOverTheLocalZone() throws {
        let chicago = TimeZone(identifier: "America/Chicago")!
        let transcript = try TranscriptImport.parse(text: TranscriptFixtures.all["meet.txt"]!, timeZone: chicago)
        XCTAssertEqual(transcript.absoluteStart, ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z"))
    }

    func testLenientVTT() throws {
        let vtt = "\u{FEFF}WEBVTT\r\nKind: captions\r\n\r\nNOTE written by hand\r\n\r\nabc/1-0\r\n0:0:3.48 --> 0:0:5.0 align:start\r\n<v.loud Dana>Hi &amp; <b>welcome</b></v>\r\n\r\n00:07.000 --> 00:09.000\r\nNo speaker here.\r\n"
        let transcript = try TranscriptImport.parse(text: vtt)
        XCTAssertEqual(transcript.cues, [
            TranscriptCue(startMs: 3_480, endMs: 5_000, speaker: "Dana", text: "Hi & welcome"),
            TranscriptCue(startMs: 7_000, endMs: 9_000, speaker: nil, text: "No speaker here.")
        ])
    }

    func testTimeStyles() {
        XCTAssertEqual(TranscriptImport.clockMs("0:0:3.480"), 3_480)
        XCTAssertEqual(TranscriptImport.clockMs("00:00:03,500"), 3_500)
        XCTAssertEqual(TranscriptImport.clockMs("59:59"), 3_599_000)
        XCTAssertEqual(TranscriptImport.clockMs("1:02:03"), 3_723_000)
        XCTAssertNil(TranscriptImport.clockMs("1:75"))
        XCTAssertNil(TranscriptImport.clockMs("budget"))
        XCTAssertEqual(TranscriptImport.spelledMs("0 minutes 3 seconds"), 3_000)
        XCTAssertEqual(TranscriptImport.spelledMs("1 hour 2 minutes 3 seconds"), 3_723_000)
        XCTAssertEqual(TranscriptImport.spelledMs("45 seconds"), 45_000)
        XCTAssertNil(TranscriptImport.spelledMs("3 apples"))
    }

    func testOtterRollsPastAnHour() throws {
        let text = "Alice  59:58\nAlmost an hour.\n\nBen  1:00:02\nNow past it.\n"
        XCTAssertEqual(try TranscriptImport.parse(text: text).cues.map(\.startMs), [3_598_000, 3_602_000])
    }

    func testNamePrefixLeavesProseAlone() {
        XCTAssertEqual(TranscriptImport.namePrefix("Ben Sample: Thanks.")?.0, "Ben Sample")
        XCTAssertNil(TranscriptImport.namePrefix("So the point I was making, really: the budget is late"))
        XCTAssertNil(TranscriptImport.namePrefix("See https://example.com"))
        XCTAssertNil(TranscriptImport.namePrefix("Ratio is 3:2 overall"))
    }

    func testEmptyAndUntimedFilesFail() {
        XCTAssertThrowsError(try TranscriptImport.parse(text: "  \n")) { XCTAssertEqual($0 as? TranscriptImport.Failure, .empty) }
        XCTAssertThrowsError(try TranscriptImport.parse(text: "Just some notes\nwith no times")) {
            XCTAssertEqual($0 as? TranscriptImport.Failure, .noCues)
        }
    }

    // MARK: Alignment

    private let sessionStart = ISO8601DateFormatter().date(from: "2026-03-04T10:00:30Z")!

    private func session(_ margins: [(String, Double)], blind: Set<Int> = []) -> LiveSession {
        var live = LiveSession(id: "s", kind: .meeting, title: "Budget sync", startedAt: sessionStart)
        for (index, (text, seconds)) in margins.enumerated() {
            live.margins.append(live.margin(id: "m\(index)", text: text, markedAt: sessionStart.addingTimeInterval(seconds), isBlindMark: blind.contains(index)))
        }
        return live
    }

    private func longTranscript() -> ImportedTranscript {
        ImportedTranscript(format: .webVTT, cues: [
            TranscriptCue(startMs: 0, endMs: 60_000, speaker: "Alice", text: "Welcome everyone, let's start with the budget."),
            TranscriptCue(startMs: 60_000, endMs: 120_000, speaker: "Ben", text: "Thanks. I have the draft numbers ready."),
            TranscriptCue(startMs: 600_000, endMs: 660_000, speaker: "Me", text: "I think we should move the launch to April."),
            TranscriptCue(startMs: 900_000, endMs: 960_000, speaker: "Alice", text: "Great, please share them.")
        ])
    }

    func testAgreeingTextMatchesPinTheTranscriptAndPlaceTheRest() {
        // The transcript's zero is 2 minutes before the session started; two spoken Margins, saved 8 and 13
        // minutes in, agree on it, so they outrank a wrong rough start (#2485 audit: one match alone doesn't).
        let live = session([("we should move the launch to April", 480), ("Blind", 600), ("great please share them", 780)], blind: [1])
        let result = TranscriptAlignment.align(session: live, transcript: longTranscript(), roughStart: sessionStart.addingTimeInterval(-9_999))
        XCTAssertEqual(result.method, .textMatch)
        XCTAssertEqual(result.matches, ["m0": 2, "m2": 3])
        XCTAssertEqual(result.transcriptStart, sessionStart.addingTimeInterval(480 - 600))
        XCTAssertEqual(result.placed.map(\.offsetMs), [600_000, 720_000, 900_000])
    }

    func testWithoutAMatchTheHeaderDateThenTheRoughStartAreUsed() {
        let live = session([("Something nobody said aloud at all", 120)])
        var transcript = longTranscript()
        transcript.absoluteStart = sessionStart.addingTimeInterval(-30)
        let fromHeader = TranscriptAlignment.align(session: live, transcript: transcript)
        XCTAssertEqual(fromHeader.method, .transcriptStart)
        XCTAssertEqual(fromHeader.placed.first?.offsetMs, 150_000)

        transcript.absoluteStart = nil
        let rough = TranscriptAlignment.align(session: live, transcript: transcript, roughStart: sessionStart.addingTimeInterval(-60), nudgeMs: 5_000)
        XCTAssertEqual(rough.method, .roughStart)
        XCTAssertEqual(rough.placed.first?.offsetMs, 175_000)

        let noRough = TranscriptAlignment.align(session: live, transcript: transcript)
        XCTAssertEqual(noRough.placed.first?.offsetMs, 120_000)
    }

    func testWallClockCaptionsUseTheSessionDate() throws {
        let transcript = try TranscriptImport.parse(text: TranscriptFixtures.all["zoom-captions.txt"]!)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let start = TranscriptAlignment.fallbackStart(transcript: transcript, session: session([]), roughStart: nil, calendar: calendar)
        XCTAssertEqual(start.method, .transcriptStart)
        XCTAssertEqual(start.date, ISO8601DateFormatter().date(from: "2026-03-04T10:00:03Z"))
    }

    func testShortOrUnrelatedTextDoesNotMatch() {
        let cues = longTranscript().cues
        XCTAssertNil(TranscriptAlignment.bestCue(for: "the budget", in: cues))
        XCTAssertNil(TranscriptAlignment.bestCue(for: "pizza for lunch on friday", in: cues))
        XCTAssertEqual(TranscriptAlignment.bestCue(for: "MOVE the launch to april!", in: cues)?.index, 2)
        // Words split across two neighbouring cues still match, at the first of them.
        XCTAssertEqual(TranscriptAlignment.bestCue(for: "the budget thanks I have the draft", in: cues)?.index, 0)
    }

    // MARK: Item text

    func testTranscriptTextPutsMarginsAtTheirCue() throws {
        let transcript = try TranscriptImport.parse(text: TranscriptFixtures.all["teams.vtt"]!)
        let placed = [
            LiveSessionAlignment.Placed(id: "a", text: "On Ben", offsetMs: 7_000),
            LiveSessionAlignment.Placed(id: "b", text: "Before", offsetMs: 0)
        ]
        let built = LiveSessionText.transcript(transcript, placed: placed)
        XCTAssertTrue(built.text.hasPrefix("Alice Example: Welcome everyone"))
        let ben = built.text.distance(from: built.text.startIndex, to: built.text.range(of: "Ben Sample:")!.lowerBound)
        XCTAssertEqual(built.placed.map(\.charOffset), [ben, 0])
    }

    func testSessionNotesKeepTheListenersWordsAndNoPosition() {
        var live = LiveSession(id: "s", kind: .audiobook, title: "A book", startedAt: sessionStart, startWhere: "Chapter 4", endWhere: "Chapter 6")
        live.margins = [live.margin(id: "a", text: "Great line", markedAt: sessionStart.addingTimeInterval(75), whereNote: "Chapter 5")]
        let built = LiveSessionText.notes(live)
        XCTAssertEqual(built.text, "Audiobook session, Chapter 4 to Chapter 6.\n\n1:15 into the session, Chapter 5 or so.")
        XCTAssertEqual(built.placed.first?.charOffset, built.text.distance(from: built.text.startIndex, to: built.text.range(of: "1:15")!.lowerBound))
        XCTAssertEqual(built.placed.first?.text, "Great line")
    }
}

/// Owner rule 2026-10-22: a Margin's own words work as a hint ("Johnny was just talking about the budget"),
/// matched near the estimate with the speaker weighted, and only a confident match anchors it.
final class TranscriptHintTests: XCTestCase {
    private let cues = [
        TranscriptCue(startMs: 0, endMs: 60_000, speaker: "Alice Example", text: "Welcome, the budget is first on the list."),
        TranscriptCue(startMs: 120_000, endMs: 180_000, speaker: "Johnny Rivera", text: "The travel budget is over by a third."),
        TranscriptCue(startMs: 240_000, endMs: 300_000, speaker: "Alice Example", text: "Let's talk hiring next quarter."),
        TranscriptCue(startMs: 2_400_000, endMs: 2_460_000, speaker: "Johnny Rivera", text: "Back to the travel budget once more."),
        TranscriptCue(startMs: 3_000_000, endMs: 3_060_000, speaker: "Ben Sample", text: "Hiring plan approved.")
    ]

    func testSpeakerAndTopicFindTheRightCue() {
        let match = TranscriptAlignment.hintCue(for: "Johnny was just talking about the budget", near: 200_000, in: cues, windowMs: 600_000)
        XCTAssertEqual(match?.index, 1)
        XCTAssertEqual(match?.confidence ?? 0, 1, accuracy: 1e-9)
    }

    func testAHintMatchingTwoCuesPicksTheOneNearerTheEstimate() {
        let wide = 4_000_000
        XCTAssertEqual(TranscriptAlignment.hintCue(for: "Johnny on the travel budget", near: 300_000, in: cues, windowMs: wide)?.index, 1)
        XCTAssertEqual(TranscriptAlignment.hintCue(for: "Johnny on the travel budget", near: 2_300_000, in: cues, windowMs: wide)?.index, 3)
    }

    func testTheWindowLimitsTheSearch() {
        // The only hiring cue Ben spoke is 46 minutes from the estimate.
        XCTAssertNil(TranscriptAlignment.hintCue(for: "Ben said the hiring plan", near: 200_000, in: cues, windowMs: 600_000))
    }

    func testAWeakHintDoesNotAnchor() {
        XCTAssertNil(TranscriptAlignment.hintCue(for: "something about money", near: 100_000, in: cues, windowMs: 600_000))
        // One topic word with no speaker is too thin.
        XCTAssertNil(TranscriptAlignment.hintCue(for: "budget", near: 100_000, in: cues, windowMs: 600_000))
        // A speaker alone isn't a topic.
        XCTAssertNil(TranscriptAlignment.hintCue(for: "Johnny", near: 100_000, in: cues, windowMs: 600_000))
    }

    func testAHintBecomesAnAnchorInAlignmentAndAWeakOneStaysAnEstimate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 0)
        live.margins = [
            live.margin(id: "hint", text: "Johnny was just talking about the travel budget", markedAt: start.addingTimeInterval(170)),
            live.margin(id: "weak", text: "remember to follow up", markedAt: start.addingTimeInterval(200))
        ]
        let transcript = ImportedTranscript(format: .webVTT, cues: cues)
        let result = TranscriptAlignment.align(session: live, transcript: transcript)
        XCTAssertEqual(result.matches, ["hint": 1])
        XCTAssertEqual(result.placed.first { $0.id == "hint" }?.offsetMs, 120_000)
        XCTAssertEqual(result.placed.first { $0.id == "weak" }?.offsetMs, 200_000)
    }
}

/// #2485 audit: one weak or lone text match must never move the other Margins.
final class TranscriptAnchorAgreementTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let cues = [
        TranscriptCue(startMs: 0, endMs: 60_000, speaker: "Alice", text: "Welcome everyone, let's start with the budget."),
        TranscriptCue(startMs: 600_000, endMs: 660_000, speaker: "Ben", text: "I think we should move the launch to April."),
        TranscriptCue(startMs: 1_500_000, endMs: 1_560_000, speaker: "Cara", text: "Marketing needs another designer before summer."),
        TranscriptCue(startMs: 2_700_000, endMs: 2_760_000, speaker: "Ben", text: "Hiring plan approved for next quarter."),
        TranscriptCue(startMs: 3_000_000, endMs: 3_060_000, speaker: "Alice", text: "Thanks all, see you next week.")
    ]

    private func session(_ margins: [(String, Double)]) -> LiveSession {
        var live = LiveSession(id: "s", kind: .meeting, startedAt: start, startPositionMs: 0)
        live.margins = margins.enumerated().map { live.margin(id: "m\($0.offset)", text: $0.element.0, markedAt: start.addingTimeInterval($0.element.1)) }
        return live
    }

    func testCommonWordsDoNotMatchAnEarlyCue() {
        // The audit's case: "the budget is the issue", typed 45 minutes in, scored 3 of 5 on the opening cue.
        XCTAssertNil(TranscriptAlignment.bestCue(for: "the budget is the issue", in: [cues[0]]))
        // Repeated words count once.
        XCTAssertNil(TranscriptAlignment.bestCue(for: "budget budget budget welcome", in: [cues[0]]))
    }

    func testATypedMarginSharingWordsWithTheOpeningDoesNotShiftTheRest() {
        let live = session([("the budget is the issue", 2_700), ("remember to follow up", 1_500)])
        let result = TranscriptAlignment.align(session: live, transcript: ImportedTranscript(format: .webVTT, cues: cues))
        XCTAssertEqual(result.transcriptStart, start)
        XCTAssertEqual(result.placed.first { $0.id == "m1" }?.offsetMs, 1_500_000)
        XCTAssertNotEqual(result.placed.first { $0.id == "m0" }?.offsetMs, 0)
    }

    func testALoneFarMatchIsKeptAsEvidenceButMovesNothing() {
        // Four distinctive words of the opening cue, typed 45 minutes in: a confident match, but alone and
        // 45 minutes from every other estimate.
        let live = session([("welcome everyone let's start budget", 2_700), ("remember to follow up", 1_500)])
        let result = TranscriptAlignment.align(session: live, transcript: ImportedTranscript(format: .webVTT, cues: cues))
        XCTAssertEqual(result.transcriptStart, start)
        XCTAssertEqual(result.method, .roughStart)
        XCTAssertEqual(result.placed.first { $0.id == "m1" }?.offsetMs, 1_500_000)
        let lone = result.placed.first { $0.id == "m0" }
        XCTAssertEqual(lone?.offsetMs, 2_700_000)
        XCTAssertEqual(lone?.source, .estimate)
        XCTAssertEqual(lone?.matchMs, 0, "the match is still reported")
        XCTAssertEqual(result.setAside, ["m0": 0])
        XCTAssertTrue(LiveSessionMarkdown.evidence(margin: live.margins[0], placed: lone, session: live)
            .hasPrefix("Transcript match 100% at 0:00, not used: it disagrees with the other evidence · estimate about 45:00"))
    }

    func testTwoAgreeingMatchesPinTheTranscript() {
        // The transcript's zero is 2 minutes before the session; two spoken Margins agree on it.
        let live = session([("we should move the launch to April", 480), ("marketing needs another designer", 1_380), ("Mark", 2_000)])
        let result = TranscriptAlignment.align(session: live, transcript: ImportedTranscript(format: .webVTT, cues: cues))
        XCTAssertEqual(result.method, .textMatch)
        XCTAssertEqual(result.transcriptStart, start.addingTimeInterval(-120))
        XCTAssertEqual(result.placed.first { $0.id == "m2" }?.offsetMs, 2_120_000)
    }

    func testAMatchFarFromTheListenersOwnSettingDoesNotOverrideIt() {
        var live = session([("we should move the launch to April", 480)])
        live.margins[0].listenerPositionMs = 3_000_000
        let result = TranscriptAlignment.align(session: live, transcript: ImportedTranscript(format: .webVTT, cues: cues))
        let placed = result.placed[0]
        XCTAssertEqual(placed.source, .listener)
        XCTAssertEqual(placed.offsetMs, 3_000_000)
        XCTAssertEqual(placed.matchMs, 600_000)
    }

    func testContractionsMatchTheirStem() {
        XCTAssertEqual(TranscriptAlignment.tokens("Let's go, I'm in, we're done"), ["let", "go", "i", "in", "we", "done"])
    }
}
