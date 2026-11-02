import Foundation
import XCTest
@testable import SessionKit

/// #3144 (#3032 slice 3): one owner answers "does the source resume after a Margin capture, a call that cut one short
/// or a relaunch, and from where". These tables are that answer, one row per path that used to carry its own copy:
/// a spoken Margin, a hands-free Margin, a written Margin, the Watch and Live Activity placer, a call, a relaunch.
/// The engine's own tests (`MarginCapturePauseOnTapTests`, `FinishedSessionMarginTests`, `FailedMarginStartTests`,
/// `CutShortMarginsTests`) check that `SessionEngine` obeys the answer; `test_resume_owners` fails if a second copy
/// of the decision is declared outside the owner's files.
final class MarginCaptureResumeTests: XCTestCase {
    // MARK: What the source does once a capture is over

    func testOutcomeTableForEveryPathThatEndsACapture() {
        struct Row {
            let path: String
            let startedOnFinished: Bool
            let target: InterjectionTargetType
            let resumesSource: Bool
            let expected: MarginCaptureResume.Outcome
        }
        let rows: [Row] = [
            // Save, Cancel and a switch to writing on a source that was playing.
            Row(path: "spoken Margin, source plays on", startedOnFinished: false, target: .item, resumesSource: true, expected: .resumePlaying),
            Row(path: "hands-free Margin, resume command", startedOnFinished: false, target: .item, resumesSource: true, expected: .resumePlaying),
            Row(path: "written Margin after Save or Cancel", startedOnFinished: false, target: .item, resumesSource: true, expected: .resumePlaying),
            Row(path: "Margin recorded over a summary", startedOnFinished: false, target: .summaryTurn, resumesSource: true, expected: .resumePlaying),
            Row(path: "Margin recorded over an answer", startedOnFinished: false, target: .assistantTurn, resumesSource: true, expected: .resumePlaying),
            // Another voice plays on instead, or the placer (Watch, Live Activity) saves without playing.
            Row(path: "Margin voice held the recording", startedOnFinished: false, target: .item, resumesSource: false, expected: .stayPaused),
            Row(path: "Watch / Live Activity placer", startedOnFinished: false, target: .item, resumesSource: false, expected: .stayPaused),
            Row(path: "hands-free, headphones removed", startedOnFinished: false, target: .item, resumesSource: false, expected: .stayPaused),
            // A finished source stays finished, whatever the caller asked.
            Row(path: "recap Margin on a finished item", startedOnFinished: true, target: .item, resumesSource: true, expected: .settleFinished),
            Row(path: "recap Margin on a finished item, source held", startedOnFinished: true, target: .item, resumesSource: false, expected: .settleFinished),
            // The finished flag is about the item; a summary recorded in the same session is not finished.
            Row(path: "summary Margin after a finished item", startedOnFinished: true, target: .summaryTurn, resumesSource: true, expected: .resumePlaying),
        ]
        for row in rows {
            var owner = MarginCaptureResume()
            owner.captureStarting(finishedAtEnd: row.startedOnFinished)
            XCTAssertEqual(owner.outcome(targetType: row.target, resumesSource: row.resumesSource), row.expected, row.path)
        }
    }

    func testAFailedRecorderStartPutsBackOnlyASourceThatWasPlaying() {
        let rows: [(finished: Bool, wasPlaying: Bool, resumes: Bool)] = [
            (false, true, true), (false, false, false), (true, true, false), (true, false, false),
        ]
        for row in rows {
            var owner = MarginCaptureResume()
            owner.captureStarting(finishedAtEnd: row.finished)
            XCTAssertEqual(owner.resumesAfterFailedStart(sourceWasPlaying: row.wasPlaying), row.resumes,
                           "finished \(row.finished), playing \(row.wasPlaying)")
        }
    }

    func testTheOwnerForgetsAFailedCaptureAndAnEndedSession() {
        var owner = MarginCaptureResume()
        owner.captureStarting(finishedAtEnd: true)
        owner.sourcePaused(in: .summaryPlayback)
        owner.captureAbandoned()
        XCTAssertFalse(owner.returnsToFinishedSource(targetType: .item), "a failed start leaves nothing finished behind")
        XCTAssertEqual(owner.phase(afterCancellingOn: .item), .itemPlayback, "nor a phase to return to")

        owner.tapPaused(MarginCaptureTiming(request: MarginCaptureRequest()))
        owner.captureStarting(finishedAtEnd: true)
        owner.sourcePaused(in: .summaryPlayback)
        XCTAssertTrue(owner.claimRejoin(forMargin: "m1", inSession: "s1"))
        owner.sessionEnded()
        XCTAssertFalse(owner.isSourcePausedOnTap, "the tap's pause belonged to the session that ended")
        XCTAssertFalse(owner.startedOnFinishedSource)
        XCTAssertEqual(owner.phase(afterCancellingOn: .summaryTurn), .summaryPlayback, "no recording began: the plain phase")
        XCTAssertTrue(owner.claimRejoin(forMargin: "m1", inSession: "s1"), "a new session steps back for its first Margin again")
    }

    // MARK: Which phase the source returns to

    func testPhaseTable() {
        let kinds: [(InterjectionTargetType, SessionPhase)] = [
            (.item, .itemPlayback), (.summaryTurn, .summaryPlayback), (.assistantTurn, .aiResponsePlayback),
        ]
        for (target, plain) in kinds {
            XCTAssertEqual(MarginCaptureResume.phase(afterSavingOn: target), plain, "Save returns to the plain phase of \(target)")
            var owner = MarginCaptureResume()
            XCTAssertEqual(owner.phase(afterCancellingOn: target), plain, "no recording began: the plain phase")
            owner.sourcePaused(in: .recordingInterjection)
            XCTAssertEqual(owner.phase(afterCancellingOn: target), .recordingInterjection, "Cancel returns to where the recording began")
        }
    }

    // MARK: The tap's pause and the step back over a saved Margin

    func testTheTapsPauseIsTakenOverOnce() {
        var owner = MarginCaptureResume()
        XCTAssertNil(owner.takeOverTapPause(), "a tap that paused nothing leaves nothing to take over")
        owner.tapPaused(MarginCaptureTiming(request: MarginCaptureRequest()))
        XCTAssertTrue(owner.isSourcePausedOnTap)
        XCTAssertNotNil(owner.takeOverTapPause())
        XCTAssertFalse(owner.isSourcePausedOnTap)
        XCTAssertNil(owner.takeOverTapPause(), "the next Margin cannot take the same pause over twice")
    }

    func testTheStepBackIsNotSkippedForAnotherSessionsMarginWithTheSameId() {
        var owner = MarginCaptureResume()
        XCTAssertTrue(owner.claimRejoin(forMargin: "ij-001", inSession: "A"))
        XCTAssertTrue(owner.claimRejoin(forMargin: "ij-001", inSession: "B"), "every session's first Margin is ij-001")
        XCTAssertFalse(owner.claimRejoin(forMargin: "ij-001", inSession: "B"))
    }

    func testTheStepBackRunsOncePerMarginHoweverOftenSaveIsRetried() {
        var owner = MarginCaptureResume()
        XCTAssertTrue(owner.claimRejoin(forMargin: "m1", inSession: "s1"))
        XCTAssertFalse(owner.claimRejoin(forMargin: "m1", inSession: "s1"), "a retried Save must not step the podcast back again")
        XCTAssertTrue(owner.claimRejoin(forMargin: "m2", inSession: "s1"), "the next Margin steps back for itself")
        XCTAssertFalse(owner.claimRejoin(forMargin: "m2", inSession: "s1"))
    }

    // MARK: Relaunch and Margin jumps: the protected position

    private func session(target: String = "t1", type: TargetType = .transcriptBackedMedia, ms: Int = 5_000) -> Session {
        Session(
            id: "s1", itemId: "i1", status: "in_progress", phase: .itemPlayback,
            currentTargetType: type, currentTargetId: target,
            position: Position(charOffset: 0, mediaTimeMs: ms, chapterId: nil), completionPercent: 10, playbackRate: 1
        )
    }

    func testAProtectedPositionIsSeenOnlyByItsOwnTarget() {
        var held = ProtectedResumePosition()
        XCTAssertFalse(held.holdsPosition(for: session()), "nothing is held at launch")
        held.protect(session(ms: 7_000))
        XCTAssertEqual(held.position(for: session())?.mediaTimeMs, 7_000)
        XCTAssertNil(held.position(for: session(target: "t2")), "another target must not see it")
        XCTAssertNil(held.position(for: session(type: .itemTextTTS)), "nor the same id as another kind of target")
    }

    func testAProtectedPositionIsReleasedByItsOwnTargetsConfirmationOnly() {
        var held = ProtectedResumePosition()
        held.protect(session())
        held.playbackConfirmed(targetId: "other")
        XCTAssertTrue(held.holdsPosition(for: session()), "another target's start is not this one's confirmation")
        held.playbackConfirmed(targetId: "t1")
        XCTAssertFalse(held.holdsPosition(for: session()))
    }

    func testAMediaSeekWaitsWithItsPositionAndReleaseDropsBoth() {
        var held = ProtectedResumePosition()
        let request = MediaSeekRequest(id: 4, targetId: "t1", requestedMediaTimeMs: 9_000)
        held.protect(session(ms: 9_000), mediaSeekRequest: request)
        XCTAssertEqual(held.mediaSeekRequest(for: session()), request)
        XCTAssertNil(held.mediaSeekRequest(for: session(target: "t2")))
        held.release()
        XCTAssertNil(held.mediaSeekRequest(for: session()))
        XCTAssertNil(held.position(for: session()))
    }

    func testAJumpThatFailsRestoresThePositionHeldBefore() {
        var held = ProtectedResumePosition()
        held.protect(session(ms: 1_000))
        let before = held
        held.protect(session(target: "t2", ms: 2_000))
        held = before
        XCTAssertEqual(held.position(for: session())?.mediaTimeMs, 1_000)
        XCTAssertNil(held.position(for: session(target: "t2")))
    }

    // MARK: A call that cut a spoken Margin short

    private func mark(_ target: String = "t1", ms: Int = 5_000, margins: Int = 1) -> InterruptedSourceMark {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = "s1"
        snapshot.targetId = target
        snapshot.currentMediaTimeMs = ms
        snapshot.activeInterjectionCount = margins
        return InterruptedSourceMark(snapshot)
    }

    func testCallResumeTable() {
        struct Row {
            let name: String
            let cutShort: Bool
            let settledAt: InterruptedSourceMark?
            let cancelled: Bool
            let iosEnd: InterruptionEnd
            let recording: TimeInterval?
            let pausedNow: InterruptedSourceMark?
            let expected: Bool
        }
        let here = mark()
        let rows: [Row] = [
            Row(name: "call ends, iOS says resume, source untouched", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: here, expected: true),
            Row(name: "iOS says do not resume", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioStaysStopped, recording: nil, pausedNow: here, expected: false),
            Row(name: "listener recorded again during the call", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: 2, pausedNow: here, expected: false),
            Row(name: "listener moved the source", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: mark(ms: 6_000), expected: false),
            Row(name: "listener recorded a Margin on it", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: mark(margins: 2), expected: false),
            Row(name: "listener opened another item", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: mark("t2"), expected: false),
            Row(name: "source no longer paused part-way", cutShort: true, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: nil, expected: false),
            Row(name: "save left the source playing or finished", cutShort: true, settledAt: nil, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: here, expected: false),
            Row(name: "headphones lost during the call", cutShort: true, settledAt: here, cancelled: true, iosEnd: .audioMayStart, recording: nil, pausedNow: here, expected: false),
            Row(name: "no Margin was cut short", cutShort: false, settledAt: here, cancelled: false, iosEnd: .audioMayStart, recording: nil, pausedNow: here, expected: false),
        ]
        for row in rows {
            var call = InterruptedCaptureResume()
            if row.cutShort { call.marginCutShort() }
            call.sourceSettled(at: row.settledAt)
            if row.cancelled { call.cancel() }
            XCTAssertEqual(call.ended(row.iosEnd, recordedSeconds: row.recording, pausedSource: row.pausedNow), row.expected, row.name)
        }
    }

    func testACallsEndSpendsTheWait() {
        var call = InterruptedCaptureResume()
        call.marginCutShort()
        call.sourceSettled(at: mark())
        XCTAssertTrue(call.ended(.audioMayStart, recordedSeconds: nil, pausedSource: mark()))
        XCTAssertFalse(call.ended(.audioMayStart, recordedSeconds: nil, pausedSource: mark()), "a late second end cannot resume twice")
    }

    func testASettleBeforeTheCallCutAMarginShortChangesNothing() {
        var call = InterruptedCaptureResume()
        call.sourceSettled(at: mark())
        XCTAssertFalse(call.ended(.audioMayStart, recordedSeconds: nil, pausedSource: mark()))
    }

    // MARK: Where the source resumes from after a system pause

    func testSystemPausePointTable() {
        let paused = Date(timeIntervalSince1970: 1_000)
        var point = InterruptionResumePoint()
        XCTAssertNil(point.rewindMs(sessionId: "s1", mediaTimeMs: 5_000, now: { paused }), "nothing paused it")
        point.paused(sessionId: "s1", mediaTimeMs: 5_000, at: paused)
        XCTAssertEqual(point.rewindMs(sessionId: "s1", mediaTimeMs: 5_000, now: { paused })?.pausedAtMs, 5_000)
        XCTAssertNil(point.rewindMs(sessionId: "s2", mediaTimeMs: 5_000, now: { paused }), "another session")
        XCTAssertNil(point.rewindMs(sessionId: "s1", mediaTimeMs: 6_000, now: { paused }), "the listener moved it")
        XCTAssertNil(point.rewindMs(sessionId: "s1", mediaTimeMs: nil, now: { paused }))
        let longPause = point.rewindMs(sessionId: "s1", mediaTimeMs: 5_000, now: { paused.addingTimeInterval(600) })
        XCTAssertEqual(longPause?.rewindMs, InterruptionRewind.rewindMs(pausedForSeconds: 600))
        point.forget()
        XCTAssertNil(point.rewindMs(sessionId: "s1", mediaTimeMs: 5_000, now: { paused }))
        point.paused(sessionId: "s1", mediaTimeMs: nil, at: paused) // text, read from a character
        XCTAssertNil(point.rewindMs(sessionId: "s1", mediaTimeMs: nil, now: { paused }), "text has no clock to step back on")
    }

    // MARK: Hands-free Margin (#3170, #3032 slice 4)

    func testHandsFreeResumeTableForEveryEdgeThatUsedToCarryItsOwnCopy() {
        struct Row {
            let edge: String
            let steps: (inout HandsFreeCaptureResume) -> Void
            let resumes: Bool
            let waitingForCall: Bool
        }
        let rows: [Row] = [
            Row(edge: "a new Margin resumes by default", steps: { $0.reset() }, resumes: true, waitingForCall: false),
            Row(edge: "a saved Margin closes with the source resuming", steps: { $0.closing(resume: true) }, resumes: true, waitingForCall: false),
            Row(edge: "a save after headphones came out", steps: { $0.closing(resume: false) }, resumes: false, waitingForCall: false),
            Row(edge: "a call is awaited", steps: { $0.callBegan() }, resumes: true, waitingForCall: true),
            Row(edge: "press after a call iOS never ended", steps: { $0.callBegan(); $0.pressedAfterCallThatNeverEnded() },
                resumes: false, waitingForCall: false),
            Row(edge: "headphones during the closing tone", steps: { $0.closing(resume: true); $0.headphonesRemoved() },
                resumes: false, waitingForCall: false),
            Row(edge: "headphones while a call is awaited", steps: { $0.callBegan(); $0.headphonesRemoved() },
                resumes: false, waitingForCall: true),
            Row(edge: "a call during the rejoin, iOS says resume", steps: { $0.closing(resume: true); $0.callBegan(); _ = $0.callEnded(.audioMayStart) },
                resumes: true, waitingForCall: false),
            Row(edge: "a call that iOS ends without the resume bit", steps: { $0.callBegan(); _ = $0.callEnded(.audioStaysStopped) },
                resumes: false, waitingForCall: false),
            Row(edge: "iOS says resume after headphones came out", steps: { $0.callBegan(); $0.headphonesRemoved(); _ = $0.callEnded(.audioMayStart) },
                resumes: false, waitingForCall: false),
            Row(edge: "a new Margin forgets a stale answer", steps: { $0.callBegan(); $0.headphonesRemoved(); $0.reset() },
                resumes: true, waitingForCall: false),
        ]
        for row in rows {
            var intent = HandsFreeCaptureResume()
            row.steps(&intent)
            XCTAssertEqual(intent.resumesSource, row.resumes, row.edge)
            XCTAssertEqual(intent.isWaitingForCallToEnd, row.waitingForCall, row.edge)
        }
    }

    func testACallEndWithNoWaitChangesNothing() {
        var intent = HandsFreeCaptureResume()
        XCTAssertFalse(intent.callEnded(.audioStaysStopped))
        XCTAssertTrue(intent.resumesSource, "a call end nobody waited for must not rule the resume out")
    }

    func testACallsEndSpendsTheHandsFreeWait() {
        var intent = HandsFreeCaptureResume()
        intent.callBegan()
        XCTAssertTrue(intent.callEnded(.audioMayStart))
        XCTAssertFalse(intent.callEnded(.audioStaysStopped), "a second end report finds nothing waiting")
        XCTAssertTrue(intent.resumesSource)
    }
}
