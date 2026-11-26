import XCTest
@testable import SessionKit

/// #3847: a Margin begun on a live session's screen is kept when the session ends somewhere else before Save.
final class LiveSessionBegunMarginTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func session(endedAfter end: TimeInterval? = nil, saved: Bool = false, reason: String? = nil, note: String? = nil, tapped: TimeInterval? = nil) -> LiveSession {
        var session = LiveSession(id: "live-1", title: "Budget meeting", startedAt: t0)
        session.endedAt = end.map { t0.addingTimeInterval($0) }
        session.endTappedAt = tapped.map { t0.addingTimeInterval($0) }
        session.endReason = reason
        session.endNote = note
        session.savedItemId = saved ? "item-1" : nil
        return session
    }

    private func margin(_ id: String = "m1", at offset: TimeInterval) -> LiveSessionMargin {
        LiveSessionMargin(id: id, text: "words", markedAt: t0.addingTimeInterval(offset))
    }

    // MARK: check

    func testARunningSessionAcceptsWithNoNote() {
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0.addingTimeInterval(30), in: session()), .accepted(afterEnd: false))
    }

    func testAMissingOrSavedSessionRefuses() {
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0, in: nil), .refused)
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0, in: session(saved: true)), .refused)
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0, in: session(endedAfter: 60, saved: true)), .refused)
    }

    func testAnEndedSessionAcceptsAndNotesOnlyWhatWasMarkedAfterTheStop() {
        let ended = session(endedAfter: 100)
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0.addingTimeInterval(40), in: ended), .accepted(afterEnd: false), "begun before the stop")
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0.addingTimeInterval(100), in: ended), .accepted(afterEnd: false), "at the stop")
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0.addingTimeInterval(101), in: ended), .accepted(afterEnd: true), "after the stop")
        // No time limit: a Margin an hour after the End is still the listener's, written on this screen.
        XCTAssertEqual(LiveSessionBegunMargin.check(markedAt: t0.addingTimeInterval(3_700), in: ended), .accepted(afterEnd: true))
    }

    // MARK: add

    func testAddKeepsAMarginInARunningSessionWithNoNote() {
        var running = session()
        XCTAssertEqual(LiveSessionBegunMargin.add(margin(at: 30), to: &running), .accepted(afterEnd: false))
        XCTAssertEqual(running.margins.map(\.id), ["m1"])
        XCTAssertNil(running.margins[0].filingNote)
        XCTAssertEqual(running.margins[0].sessionOffsetMs, 30_000)
    }

    func testAddKeepsAMarginAfterTheStopWithTheAfterEndNote() {
        var ended = session(endedAfter: 100)
        XCTAssertEqual(LiveSessionBegunMargin.add(margin(at: 160), to: &ended), .accepted(afterEnd: true))
        XCTAssertEqual(ended.margins.map(\.id), ["m1"])
        XCTAssertEqual(ended.margins[0].filingNote, LiveSessionFiling.afterEndNote)
        XCTAssertEqual(ended.endedAt, t0.addingTimeInterval(100), "the End is kept")
    }

    func testAddKeepsAnEarlierNoteAndALaterOneNotAtAll() {
        var ended = session(endedAfter: 100)
        var noted = margin("noted", at: 160)
        noted.filingNote = "moved from a quick session"
        LiveSessionBegunMargin.add(noted, to: &ended)
        LiveSessionBegunMargin.add(margin("before", at: 40), to: &ended)
        XCTAssertEqual(ended.margins.map(\.id), ["before", "noted"], "in time order")
        XCTAssertEqual(ended.margins.first { $0.id == "noted" }?.filingNote, "moved from a quick session")
        XCTAssertNil(ended.margins.first { $0.id == "before" }?.filingNote)
    }

    func testAddRefusesASavedSessionAndChangesNothing() {
        var saved = session(endedAfter: 100, saved: true)
        let before = saved
        XCTAssertEqual(LiveSessionBegunMargin.add(margin(at: 160), to: &saved), .refused)
        XCTAssertEqual(saved, before)
    }

    func testTheSameMarginAddedTwiceIsOneMarginAndStillAccepted() {
        var ended = session(endedAfter: 100)
        XCTAssertEqual(LiveSessionBegunMargin.add(margin(at: 160), to: &ended), .accepted(afterEnd: true))
        XCTAssertEqual(LiveSessionBegunMargin.add(margin(at: 160), to: &ended), .accepted(afterEnd: true))
        XCTAssertEqual(ended.margins.count, 1)
    }

    func testTheFirstMarginWithAnIdWinsAndAMarginAtTheStopTimeGetsNoNote() {
        var ended = session(endedAfter: 100)
        var first = margin("same", at: 100)
        first.text = "first words"
        LiveSessionBegunMargin.add(first, to: &ended)
        var again = margin("same", at: 160)
        again.text = "second words"
        XCTAssertEqual(LiveSessionBegunMargin.add(again, to: &ended), .accepted(afterEnd: true))
        XCTAssertEqual(ended.margins.map(\.text), ["first words"], "first wins")
        XCTAssertNil(ended.margins[0].filingNote, "marked at the stop time: not after the end")
    }

    func testAMarginKeepsItsPlaceAndWordsWhenAddedAfterTheEnd() {
        var ended = session(endedAfter: 100)
        var typed = margin(at: 160)
        typed.whereNote = "page 118"
        LiveSessionBegunMargin.add(typed, to: &ended)
        XCTAssertEqual(ended.margins[0].whereNote, "page 118")
        XCTAssertEqual(ended.margins[0].text, "words")
    }

    // MARK: endedLine

    func testTheEndedLineIsNilWhileRunningAndOnceSaved() {
        XCTAssertNil(LiveSessionBegunMargin.endedLine(for: session(), timeZone: utc))
        XCTAssertNil(LiveSessionBegunMargin.endedLine(for: session(endedAfter: 60, saved: true), timeZone: utc))
    }

    func testTheEndedLineNamesTheWatchOnlyWhenTheWatchEndedIt() {
        let at = WatchContractFormat.timeOfDay(t0.addingTimeInterval(60), timeZone: utc)
        XCTAssertEqual(
            LiveSessionBegunMargin.endedLine(for: session(endedAfter: 60, reason: "watch"), timeZone: utc),
            "This session was ended on your Watch at \(at). Saving still adds this Margin to it.")
        XCTAssertEqual(
            LiveSessionBegunMargin.endedLine(for: session(endedAfter: 60), timeZone: utc),
            "This session ended at \(at). Saving still adds this Margin to it.")
        XCTAssertEqual(
            LiveSessionBegunMargin.endedLine(for: session(endedAfter: 60, reason: "placeholder"), timeZone: utc),
            "This session ended at \(at). Saving still adds this Margin to it.")
    }

    func testAReplacedSessionReusesTheWordsTheWatchShows() {
        let note = "Budget meeting ended at 14:05, when you started Lecture on Watch"
        XCTAssertEqual(
            LiveSessionBegunMargin.endedLine(for: session(endedAfter: 60, reason: "replaced", note: note), timeZone: utc),
            "\(note). Saving still adds this Margin to it.")
        let at = WatchContractFormat.timeOfDay(t0.addingTimeInterval(60), timeZone: utc)
        for blank in [nil, "", "  \n"] {
            XCTAssertEqual(
                LiveSessionBegunMargin.endedLine(for: session(endedAfter: 60, reason: "replaced", note: blank), timeZone: utc),
                "This session ended at \(at). Saving still adds this Margin to it.", "a replaced end with no words falls back: \(String(describing: blank))")
        }
    }

    func testTheEndedLineTimeIsWrittenInTheGivenTimeZone() {
        // t0 is 08:00 UTC; the End is a minute later. A literal, so the formatter is not its own oracle.
        let ended = session(endedAfter: 60)
        XCTAssertEqual(LiveSessionBegunMargin.endedLine(for: ended, timeZone: utc), "This session ended at 8:01. Saving still adds this Margin to it.")
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(LiveSessionBegunMargin.endedLine(for: ended, timeZone: newYork), "This session ended at 3:01. Saving still adds this Margin to it.")
    }

    func testTheEndedLineTimeIsWhenTheEndWasTappedWhenTheStopWasEarlier() {
        let tapped = WatchContractFormat.timeOfDay(t0.addingTimeInterval(600), timeZone: utc)
        XCTAssertEqual(
            LiveSessionBegunMargin.endedLine(for: session(endedAfter: 300, reason: "watch", tapped: 600), timeZone: utc),
            "This session was ended on your Watch at \(tapped). Saving still adds this Margin to it.")
    }

    // MARK: afterPhoto

    func testAPhotoWhileARecordingIsGoingIsDroppedWhateverTheSession() {
        for running in [true, false] {
            XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: running, isRecordingSpoken: true, photoAt: t0, in: session(endedAfter: running ? nil : 60)), .discard)
        }
    }

    func testAPhotoInARunningSessionStartsARecording() {
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: true, isRecordingSpoken: false, photoAt: t0, in: session()), .record)
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: true, isRecordingSpoken: false, photoAt: t0, in: nil), .record)
    }

    func testAPhotoWhenTheSessionHasEndedButTheScreenStillSaysRunningGoesToTheWritingScreen() {
        // The Watch's End landed between the camera tap and the photo coming back.
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: true, isRecordingSpoken: false, photoAt: t0.addingTimeInterval(30), in: session(endedAfter: 60, reason: "watch")), .write)
    }

    func testAPhotoAfterTheEndGoesToTheWritingScreenNotTheMicrophone() {
        let ended = session(endedAfter: 60, reason: "watch")
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: false, isRecordingSpoken: false, photoAt: t0.addingTimeInterval(30), in: ended), .write)
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: false, isRecordingSpoken: false, photoAt: t0.addingTimeInterval(90), in: ended), .write)
    }

    func testAPhotoIsDroppedOnlyWhenTheSessionIsSavedGoneOrNeverEnded() {
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: false, isRecordingSpoken: false, photoAt: t0, in: session(endedAfter: 60, saved: true)), .discard)
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: false, isRecordingSpoken: false, photoAt: t0, in: nil), .discard)
        // Not running and not ended: nothing to write into.
        XCTAssertEqual(LiveSessionBegunMargin.afterPhoto(isRunning: false, isRecordingSpoken: false, photoAt: t0, in: session()), .discard)
    }

    // MARK: VoiceOver

    func testTheEndedLineIsAnnouncedOnlyWhenItAppears() {
        let line = "This session ended at 14:05. Saving still adds this Margin to it."
        XCTAssertEqual(VoiceOverAnnouncements.liveSessionEnded(from: nil, to: line), line)
        XCTAssertNil(VoiceOverAnnouncements.liveSessionEnded(from: nil, to: nil), "still running")
        XCTAssertNil(VoiceOverAnnouncements.liveSessionEnded(from: line, to: line), "the same line redrawn")
        XCTAssertNil(VoiceOverAnnouncements.liveSessionEnded(from: line, to: nil), "resumed: the line goes away")
        XCTAssertNil(VoiceOverAnnouncements.liveSessionEnded(from: line, to: "This session was ended on your Watch at 14:05. Saving still adds this Margin to it."), "only the words changed")
    }
}
