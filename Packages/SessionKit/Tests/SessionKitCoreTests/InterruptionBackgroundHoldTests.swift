import Foundation
import XCTest
@testable import SessionKit

/// #1434: a message announced through AirPods paused narration, and it stayed paused. A backgrounded app with no
/// audio playing can be suspended before iOS reports the end of the interruption, so "ended, resume" never
/// arrived. The hold asks iOS for background time from the start of the interruption until it ends. They are async
/// only because Linux XCTest can't run a synchronous main-actor test.
@MainActor
final class InterruptionBackgroundHoldTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 9_000)

    func testAnInterruptionHoldsBackgroundTimeUntilIOSReportsItsEnd() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()

        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.outcome, .held)
        XCTAssertEqual(ledger.names, ["Audio interruption wait"])
        XCTAssertEqual(ledger.ends, 0, "the app must stay awake while it waits for the end")

        now = now.addingTimeInterval(6.2)
        hold.interruptionEnded()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .ended)
        XCTAssertEqual(ledger.ends, 1)
        let event = try XCTUnwrap(ledger.events.first)
        XCTAssertEqual(event.kind, "speech.interruption_hold")
        XCTAssertEqual(event.fields, ["outcome": "ended", "heldMs": "6200"])
    }

    func testTheListenerTakingOverGivesTheTimeBackAndSaysSo() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        now = now.addingTimeInterval(10.4)
        hold.listenerActed()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .listenerActed)
        XCTAssertEqual(ledger.ends, 1)
        // The owner's trace: Play ten seconds after the interruption, with no end ever reported.
        XCTAssertEqual(ledger.events.first?.fields, ["outcome": "listener_acted", "heldMs": "10400"])
    }

    func testASecondInterruptionWhileHoldingAsksForNothingMore() async {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        hold.interruptionBegan()
        hold.interruptionEnded()
        hold.interruptionEnded()

        XCTAssertEqual(ledger.begins, 1)
        XCTAssertEqual(ledger.ends, 1)
        XCTAssertEqual(ledger.events.count, 1, "one wait, one line")
    }

    func testEndingOrActingWithNothingHeldDoesNothing() async {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionEnded()
        hold.listenerActed()

        XCTAssertEqual(ledger.begins, 0)
        XCTAssertEqual(ledger.ends, 0)
        XCTAssertNil(hold.outcome)
        XCTAssertTrue(ledger.events.isEmpty)
    }

    func testTheSystemTakingTheTimeBackIsRecordedAsTheEndNeverArrivingInTime() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        now = now.addingTimeInterval(29.5)
        ledger.expire(0)

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .expired)
        XCTAssertEqual(ledger.ends, 1, "the system's task is still ended")
        XCTAssertEqual(ledger.events.first?.fields, ["outcome": "expired", "heldMs": "29500"])

        hold.interruptionBegan()
        XCTAssertEqual(ledger.begins, 2, "the next interruption asks again")
    }

    func testALateExpiryOfAnEarlierHoldDoesNotEndTheCurrentOne() async {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        hold.interruptionEnded()
        hold.interruptionBegan()
        ledger.expire(0)

        XCTAssertTrue(hold.isHolding, "the first hold's expiry arrived after it was given back")
        XCTAssertEqual(hold.outcome, .held)
    }

    func testARefusalIsRecordedAndTheNextInterruptionTriesAgain() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })
        ledger.refuses = true

        hold.interruptionBegan()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .unavailable)
        XCTAssertEqual(ledger.events.first?.fields, ["outcome": "unavailable"])

        ledger.refuses = false
        hold.interruptionBegan()
        XCTAssertTrue(hold.isHolding)
    }
    // MARK: - Watching for the other audio to stop (#1434, owner's phone on 437fbc9: no end ever arrived)

    func testAnAnnouncementThatNeverReportsItsEndResumesOnceTheOtherAudioStops() async throws {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        // The owner's trace: the announcement plays for a while, with the hint to silence secondary audio on.
        rig.audio = .init(isPlaying: true, secondaryShouldBeSilenced: true)
        for _ in 0..<8 { advance(rig, by: 0.5) }
        XCTAssertEqual(resumes, 0, "the announcement is still playing")
        XCTAssertTrue(hold.isHolding)

        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        advance(rig, by: 0.5)
        XCTAssertEqual(resumes, 0, "clear for an instant is not yet the end")
        advance(rig, by: 0.5)
        advance(rig, by: 0.5)

        XCTAssertEqual(resumes, 1)
        XCTAssertEqual(rig.activations, 1)
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .otherAudioStopped)
        XCTAssertEqual(rig.ledger.events.last?.fields, ["outcome": "other_audio_stopped", "heldMs": "5500"])
        XCTAssertEqual(rig.ledger.ends, 0, "the background time outlasts the resume until playback starts")
        advance(rig, by: 3)
        XCTAssertEqual(rig.ledger.ends, 1)

        for _ in 0..<10 { advance(rig, by: 0.5) }
        XCTAssertEqual(resumes, 1, "one resume per interruption")
        XCTAssertEqual(rig.ledger.events.count, 1)
    }

    func testAShortGapInTheOtherAudioIsNotTakenForItsEnd() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        advance(rig, by: 0.5)
        rig.audio = .init(isPlaying: true, secondaryShouldBeSilenced: false)
        advance(rig, by: 0.5)
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: true)
        advance(rig, by: 0.5)
        advance(rig, by: 0.5)
        advance(rig, by: 0.5)

        XCTAssertEqual(resumes, 0, "the hint alone still means another sound has the floor")
        XCTAssertTrue(hold.isHolding)
    }

    func testTheListenerPausingDuringTheHoldKeepsPlaybackPaused() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: true, secondaryShouldBeSilenced: true)
        advance(rig, by: 0.5)
        hold.listenerActed()
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<30 { advance(rig, by: 0.5) }

        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(rig.activations, 0)
        XCTAssertEqual(hold.outcome, .listenerActed)
        XCTAssertEqual(rig.ledger.events.count, 1)
    }

    func testOtherAudioThatNeverStopsEndsTheWatchPausedWhenTheWindowRunsOut() async throws {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: true, secondaryShouldBeSilenced: false)
        for _ in 0..<200 { advance(rig, by: 0.5) }

        XCTAssertEqual(resumes, 0)
        XCTAssertTrue(hold.isHolding, "a real end can still arrive after the watch stops")
        XCTAssertEqual(hold.outcome, .otherAudioStillPlaying)
        XCTAssertEqual(rig.ledger.ends, 0)
        XCTAssertEqual(rig.ledger.events.map(\.fields), [["outcome": "other_audio_still_playing", "heldMs": "15000"]])
        XCTAssertTrue(rig.pending.isEmpty, "the watch stops polling")
    }

    func testPausingOtherMediaAfterTheAnnouncementWindowDoesNotResumeNarration() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0
        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        for _ in 0..<40 { advance(rig, by: 0.5) }

        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<10 { advance(rig, by: 0.5) }

        XCTAssertEqual(resumes, 0, "pausing other media after 15 s must not reclaim its session")
        XCTAssertEqual(rig.activations, 0)
        XCTAssertEqual(hold.outcome, .otherAudioStillPlaying)
        XCTAssertTrue(hold.isHolding, "a real end can still arrive")
        XCTAssertTrue(rig.pending.isEmpty)
        XCTAssertEqual(rig.ledger.events.first?.fields, [
            "outcome": "other_audio_still_playing", "heldMs": "15000"
        ])
        hold.interruptionEnded()
        XCTAssertEqual(rig.ledger.ends, 1)
    }

    func testClearAudioAtTheDeadlineCannotResumeEvenIfTheSettleFinished() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0
        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        advance(rig, by: 13.5)
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        advance(rig, by: 0.5)
        // A delayed callback arrives at the deadline after a full second of clear audio.
        advance(rig, by: 1)

        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(rig.activations, 0, "the deadline takes precedence over settling")
        XCTAssertEqual(hold.outcome, .otherAudioStillPlaying)
        XCTAssertTrue(rig.pending.isEmpty)
    }

    func testFailedActivationKeepsBackgroundTimeUntilTheRealEnd() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0
        rig.activationFailure = "CannotInterruptOthers"
        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<40 { advance(rig, by: 0.5) }

        XCTAssertTrue(hold.isHolding, "a call must not cause early suspension while waiting for its real end")
        XCTAssertEqual(rig.ledger.ends, 0)
        XCTAssertEqual(rig.activations, 1)
        XCTAssertEqual(resumes, 0)
        XCTAssertTrue(rig.pending.isEmpty, "activation is not retried during the call")
        XCTAssertEqual(rig.ledger.events.first?.fields, [
            "outcome": "activation_failed", "heldMs": "1500", "error": "CannotInterruptOthers"
        ])

        hold.interruptionEnded()
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(rig.ledger.ends, 1)
        XCTAssertEqual(hold.outcome, .ended)
        XCTAssertEqual(rig.ledger.events.last?.fields, ["outcome": "ended", "heldMs": "20000"])
        for _ in 0..<10 { advance(rig, by: 0.5) }
        XCTAssertEqual(resumes, 0, "only the player's real-end handler decides whether to resume")
    }

    func testARealEndArrivingFirstMeansTheWatchNeverResumesToo() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: true, secondaryShouldBeSilenced: false)
        advance(rig, by: 0.5)
        hold.interruptionEnded()
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<10 { advance(rig, by: 0.5) }

        XCTAssertEqual(resumes, 0, "the player's own end handling resumes; the watch must not resume a second time")
        XCTAssertEqual(hold.outcome, .ended)
        XCTAssertEqual(rig.activations, 0)
        XCTAssertEqual(rig.ledger.events.count, 1)
    }

    func testFailedActivationStillReleasesOnListenerActionOrSystemExpiry() async {
        for expires in [false, true] {
            let rig = OtherAudioRig()
            let hold = rig.hold(now: { [unowned self] in self.now })
            var resumes = 0
            rig.activationFailure = "CannotInterruptOthers"
            rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
            hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
            for _ in 0..<3 { advance(rig, by: 0.5) }
            XCTAssertTrue(hold.isHolding)

            if expires { rig.ledger.expire(0) } else { hold.listenerActed() }
            XCTAssertFalse(hold.isHolding)
            XCTAssertEqual(hold.outcome, expires ? .expired : .listenerActed)
            hold.interruptionEnded()
            rig.ledger.expire(0)
            XCTAssertEqual(rig.ledger.ends, 1, "give back the retained task exactly once")
            XCTAssertEqual(rig.ledger.events.count, 2, "watch failure, then the hold's final outcome")
            XCTAssertEqual(resumes, 0)

            rig.activationFailure = nil
            hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
            rig.ledger.expire(0)
            for _ in 0..<3 { advance(rig, by: 0.5) }
            XCTAssertEqual(resumes, 1, "the next interruption starts a fresh watch")
            XCTAssertEqual(rig.activations, 2)
            advance(rig, by: 3)
            XCTAssertEqual(rig.ledger.ends, 2)
        }
    }

    func testASessionThatCannotBeActivatedLeavesPlaybackPausedAndSaysWhy() async throws {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0
        // A phone call: no "other audio" reported, but the call won't give up the audio session.
        rig.activationFailure = "Session activation failed (CannotInterruptOthers)"

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<10 { advance(rig, by: 0.5) }

        XCTAssertEqual(resumes, 0)
        XCTAssertEqual(rig.activations, 1, "one try, then the real end from iOS decides")
        XCTAssertTrue(hold.isHolding, "keep the app awake for the call's real end")
        XCTAssertEqual(rig.ledger.ends, 0)
        XCTAssertEqual(hold.outcome, .activationFailed)
        XCTAssertEqual(rig.ledger.events.last?.fields, [
            "outcome": "activation_failed",
            "heldMs": "1500",
            "error": "Session activation failed (CannotInterruptOthers)"
        ])
    }

    func testWithoutAResumeRequestTheHoldOnlyWaitsForTheEnd() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<10 { advance(rig, by: 0.5) }

        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(rig.activations, 0)
        XCTAssertTrue(rig.pending.isEmpty)
    }

    func testAnExpiryEndsTheWatch() async {
        let rig = OtherAudioRig()
        let hold = rig.hold(now: { [unowned self] in self.now })
        var resumes = 0

        hold.interruptionBegan(resumeWhenOtherAudioStops: { resumes += 1 })
        rig.audio = .init(isPlaying: true, secondaryShouldBeSilenced: true)
        advance(rig, by: 0.5)
        rig.ledger.expire(0)
        rig.audio = .init(isPlaying: false, secondaryShouldBeSilenced: false)
        for _ in 0..<10 { advance(rig, by: 0.5) }

        XCTAssertEqual(resumes, 0, "a suspended app can't resume; the next Play does")
        XCTAssertEqual(hold.outcome, .expired)
    }

    /// Moves the clock on and runs every check that has come due.
    private func advance(_ rig: OtherAudioRig, by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        rig.runDue(at: now)
    }
}

/// The audio session's state and a manual scheduler for the hold's checks.
@MainActor
private final class OtherAudioRig {
    let ledger = InterruptionHoldLedger()
    var audio = InterruptionBackgroundHold.OtherAudio(isPlaying: true, secondaryShouldBeSilenced: true)
    var activationFailure: String?
    var activations = 0
    private(set) var pending: [(due: Date, work: @MainActor () -> Void)] = []
    private var clock: () -> Date = Date.init

    func hold(now: @escaping () -> Date) -> InterruptionBackgroundHold {
        clock = now
        return ledger.hold(
            now: now,
            watch: .init(
                probe: { [unowned self] in self.audio },
                activate: { [unowned self] in
                    self.activations += 1
                    return self.activationFailure
                }
            ),
            schedule: { [unowned self] delay, work in
                self.pending.append((self.clock().addingTimeInterval(delay), work))
            }
        )
    }

    func runDue(at time: Date) {
        while let index = pending.firstIndex(where: { $0.due <= time }) {
            let item = pending.remove(at: index)
            item.work()
        }
    }
}

/// Counts the background time asked for and given back, standing in for UIApplication's background tasks.
@MainActor
private final class InterruptionHoldLedger {
    var begins = 0
    var ends = 0
    var refuses = false
    var names: [String] = []
    var events: [(kind: String, fields: [String: String])] = []
    private var expiries: [@MainActor () -> Void] = []

    func hold(
        now: @escaping () -> Date,
        watch: InterruptionBackgroundHold.OtherAudioWatch? = nil,
        schedule: InterruptionBackgroundHold.Schedule? = nil
    ) -> InterruptionBackgroundHold {
        InterruptionBackgroundHold(
            begin: { [unowned self] name, expired in
                guard !self.refuses else { return nil }
                self.begins += 1
                self.names.append(name)
                self.expiries.append(expired)
                var ended = false
                return { [unowned self] in
                    guard !ended else { return }
                    ended = true
                    self.ends += 1
                }
            },
            record: { [unowned self] kind, fields in self.events.append((kind, fields)) },
            now: now,
            otherAudioWatch: watch,
            schedule: schedule ?? InterruptionBackgroundHold.mainQueueSchedule
        )
    }

    /// The system takes background time back: it calls the expiry handler, which in the app then ends the task.
    func expire(_ index: Int) {
        guard expiries.indices.contains(index) else { return XCTFail("no hold \(index) to expire") }
        expiries[index]()
    }
}
