import Foundation
import XCTest
@testable import SessionKit

/// The phone side of a Watch Margin while the phone plays (#788).
final class WatchCaptureHandoffTests: XCTestCase {
    private let episode = WatchCaptureSource(itemId: "episode-1", revision: "r1")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(
        _ source: WatchCaptureSource? = nil,
        positionMs: Int? = 61_000,
        playing: Bool = true,
        generation: Int = 7,
        at offset: TimeInterval = 0.3
    ) -> PhonePlaybackReading {
        PhonePlaybackReading(
            source: source ?? episode,
            positionMs: positionMs,
            isPlaying: playing,
            transportGeneration: generation,
            readAt: t0.addingTimeInterval(offset)
        )
    }

    private func request(_ id: String = "cap-1", observed: WatchCaptureSource? = nil, generation: Int? = 7, playing: Bool? = true) -> WatchCaptureRequest {
        WatchCaptureRequest(captureId: id, observedSource: observed ?? episode, observedTransportGeneration: generation, observedPlaying: playing, requestedAt: t0)
    }

    func testStartWhilePlayingPausesAndAnchorsExactlyAtThePhonePosition() {
        var handoff = WatchCaptureHandoff()
        let decision = handoff.begin(request(), reading: reading(), now: t0.addingTimeInterval(0.4))
        XCTAssertEqual(decision, .start(WatchCaptureAcknowledgement(
            captureId: "cap-1",
            anchor: .anchored(WatchCaptureAnchor(source: episode, positionMs: 61_000, precision: .exact)),
            pausedPlayback: true
        )))
        XCTAssertEqual(handoff.pausedAtTransportGeneration, 7)
    }

    func testSavedCaptureResumesWhenNothingElseTouchedPlayback() {
        var handoff = WatchCaptureHandoff()
        _ = handoff.begin(request(), reading: reading(), now: t0)
        let paused = reading(playing: false, generation: 7, at: 20)
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: paused), .resumePlayback)
        XCTAssertNil(handoff.pausedAtTransportGeneration)
    }

    func testCancelledAndFailedCapturesHandPlaybackBackTheSameWay() {
        for end in [WatchCaptureEnd.cancelled, .failed] {
            var handoff = WatchCaptureHandoff()
            _ = handoff.begin(request(), reading: reading(), now: t0)
            XCTAssertEqual(handoff.end(captureId: "cap-1", as: end, reading: reading(playing: false, at: 5)), .resumePlayback, "\(end)")
        }
    }

    func testANewerTransportCommandDuringTheCaptureIsNotOverridden() {
        // Listener pressed play on the phone (or sought with headphones) while talking to the Watch.
        var handoff = WatchCaptureHandoff()
        _ = handoff.begin(request(), reading: reading(), now: t0)
        let afterPlay = reading(playing: true, generation: 8, at: 10)
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: afterPlay), .leavePlayback(.newerTransportCommand))

        var paused = WatchCaptureHandoff()
        _ = paused.begin(request(), reading: reading(), now: t0)
        let afterPause = reading(playing: false, generation: 9, at: 10)
        XCTAssertEqual(paused.end(captureId: "cap-1", as: .saved, reading: afterPause), .leavePlayback(.newerTransportCommand))
    }

    func testStartWhilePausedLeavesPlaybackPausedAfterwards() {
        var handoff = WatchCaptureHandoff()
        guard case .start(let ack) = handoff.begin(request(), reading: reading(playing: false), now: t0) else {
            return XCTFail("expected a start")
        }
        XCTAssertFalse(ack.pausedPlayback)
        XCTAssertEqual(ack.anchor.anchor?.precision, .exact)
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(playing: false, at: 9)), .leavePlayback(.notPausedForCapture))
    }

    func testDuplicateStartResendsTheSameAcknowledgementWithoutPausingAgain() {
        var handoff = WatchCaptureHandoff()
        guard case .start(let first) = handoff.begin(request(), reading: reading(), now: t0) else {
            return XCTFail("expected a start")
        }
        // The retry arrives after the pause, at a later position: same answer, no new anchor.
        let retry = handoff.begin(request(), reading: reading(positionMs: 64_000, playing: false, at: 3), now: t0.addingTimeInterval(3))
        XCTAssertEqual(retry, .duplicate(first))
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(playing: false, at: 9)), .resumePlayback)
    }

    func testDuplicateEndIsIgnored() {
        var handoff = WatchCaptureHandoff()
        _ = handoff.begin(request(), reading: reading(), now: t0)
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(playing: false, at: 9)), .resumePlayback)
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(playing: true, at: 10)), .ignored(.alreadyEnded))
    }

    func testEndBeforeStartIsRememberedAndTheLateStartNeitherPausesNorFakesAnAnchor() {
        var handoff = WatchCaptureHandoff()
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(at: 9)), .ignored(.endBeforeStart))
        let late = handoff.begin(request(), reading: reading(positionMs: 70_000, at: 9.5), now: t0.addingTimeInterval(9.5))
        XCTAssertEqual(late, .alreadyEnded(WatchCaptureAcknowledgement(
            captureId: "cap-1",
            anchor: .unavailable(.requestArrivedAfterFinish),
            pausedPlayback: false
        )))
        XCTAssertNil(handoff.pausedAtTransportGeneration)
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(at: 10)), .ignored(.alreadyEnded))
    }

    func testSourceChangedBeforeTheRequestArrivedGivesNoAnchor() {
        var handoff = WatchCaptureHandoff()
        let other = WatchCaptureSource(itemId: "episode-2", revision: "r1")
        let decision = handoff.begin(request(), reading: reading(other, generation: 8), now: t0)
        guard case .start(let ack) = decision else { return XCTFail("expected a start") }
        XCTAssertEqual(ack.anchor, .unavailable(.sourceChanged))
        XCTAssertTrue(ack.pausedPlayback, "the listener is talking, so playback still pauses")

        // A new revision of the same item counts as a different source.
        var revised = WatchCaptureHandoff()
        let reimported = WatchCaptureSource(itemId: "episode-1", revision: "r2")
        guard case .start(let revisedAck) = revised.begin(request(), reading: reading(reimported), now: t0) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(revisedAck.anchor, .unavailable(.sourceChanged))
    }

    func testSeekDuringTheRequestMakesTheAnchorApproximate() {
        var handoff = WatchCaptureHandoff()
        guard case .start(let ack) = handoff.begin(request(generation: 7), reading: reading(positionMs: 300_000, generation: 8), now: t0) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(ack.anchor, .anchored(WatchCaptureAnchor(
            source: episode,
            positionMs: 300_000,
            precision: .approximate,
            approximateReason: .transportChangedDuringRequest
        )))
    }

    func testARequestThatArrivesLateWhilePlayingIsApproximate() {
        var handoff = WatchCaptureHandoff()
        let lateReading = reading(at: WatchCaptureHandoff.lateRequestTolerance + 1)
        guard case .start(let ack) = handoff.begin(request(), reading: lateReading, now: lateReading.readAt) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(ack.anchor.anchor?.precision, .approximate)
        XCTAssertEqual(ack.anchor.anchor?.approximateReason, .requestArrivedLate)
    }

    func testWithoutAWatchSnapshotTheAnchorIsNeverExact() {
        var handoff = WatchCaptureHandoff()
        let blind = WatchCaptureRequest(captureId: "cap-1", observedSource: nil, observedTransportGeneration: nil, requestedAt: t0)
        guard case .start(let ack) = handoff.begin(blind, reading: reading(playing: false), now: t0) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(ack.anchor.anchor?.precision, .approximate)
        XCTAssertEqual(ack.anchor.anchor?.approximateReason, .noWatchSnapshot)
    }

    func testALateRequestIsApproximateWhenPlaybackStoppedWithoutATransportCommand() {
        // Playing at the press; an interruption stopped it before the queued request arrived.
        var handoff = WatchCaptureHandoff()
        let stopped = reading(playing: false, at: 30)
        guard case .start(let ack) = handoff.begin(request(playing: true), reading: stopped, now: stopped.readAt) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(ack.anchor.anchor?.approximateReason, .requestArrivedLate)

        // Paused at the press and still paused: the position can't have moved, so it stays exact.
        var paused = WatchCaptureHandoff()
        guard case .start(let pausedAck) = paused.begin(request(playing: false), reading: stopped, now: stopped.readAt) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(pausedAck.anchor.anchor?.precision, .exact)
    }

    func testStaleOrMissingPhonePositionNeverFabricatesAnAnchor() {
        var stale = WatchCaptureHandoff()
        guard case .start(let staleAck) = stale.begin(request(), reading: reading(at: 0), now: t0.addingTimeInterval(WatchCaptureHandoff.readingTolerance + 0.5)) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(staleAck.anchor, .unavailable(.staleReading))

        var noPosition = WatchCaptureHandoff()
        guard case .start(let noPositionAck) = noPosition.begin(request(), reading: reading(positionMs: nil), now: t0) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(noPositionAck.anchor, .unavailable(.noPosition))

        var nothing = WatchCaptureHandoff()
        let empty = PhonePlaybackReading(source: nil, positionMs: nil, isPlaying: false, transportGeneration: 0, readAt: t0)
        guard case .start(let nothingAck) = nothing.begin(request(), reading: empty, now: t0) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(nothingAck, WatchCaptureAcknowledgement(captureId: "cap-1", anchor: .unavailable(.nothingLoaded), pausedPlayback: false))
    }

    func testOverlappingCapturesResumeOnlyAfterTheLastEnds() {
        var handoff = WatchCaptureHandoff()
        _ = handoff.begin(request("cap-1"), reading: reading(), now: t0)
        // The second starts while the first holds playback paused.
        _ = handoff.begin(request("cap-2"), reading: reading(playing: false, at: 2), now: t0.addingTimeInterval(2))
        XCTAssertEqual(handoff.end(captureId: "cap-1", as: .saved, reading: reading(playing: false, at: 5)), .leavePlayback(.anotherCaptureOpen))
        XCTAssertEqual(handoff.end(captureId: "cap-2", as: .cancelled, reading: reading(playing: false, at: 8)), .resumePlayback)
    }

    func testACaptureWhoseEndNeverArrivesStopsHoldingPlaybackAfterTheTimeout() {
        var handoff = WatchCaptureHandoff()
        _ = handoff.begin(request("lost"), reading: reading(), now: t0)
        let later = t0.addingTimeInterval(WatchCaptureHandoff.openCaptureTimeout + 60)
        let nextRequest = WatchCaptureRequest(captureId: "cap-2", observedSource: episode, observedTransportGeneration: 7, observedPlaying: false, requestedAt: later)
        let pausedReading = PhonePlaybackReading(source: episode, positionMs: 61_000, isPlaying: false, transportGeneration: 7, readAt: later)
        _ = handoff.begin(nextRequest, reading: pausedReading, now: later)
        XCTAssertEqual(handoff.end(captureId: "cap-2", as: .saved, reading: pausedReading), .resumePlayback)
    }

    // MARK: The numbers, as literals
    //
    // The tests above compute their inputs from the constants (`lateRequestTolerance + 1`), so a
    // constant changed to a wrong number moves the input with it. These use the documented values.

    func testALateRequestIsExactUpToOneAndAHalfSecondsAndApproximateAfter() {
        for (lateBy, expected) in [(1.4, WatchCaptureAnchor.Precision.exact), (1.5, .exact), (1.6, .approximate)] {
            var handoff = WatchCaptureHandoff()
            let late = reading(at: lateBy)
            guard case .start(let ack) = handoff.begin(request(), reading: late, now: late.readAt) else {
                return XCTFail("expected a start")
            }
            XCTAssertEqual(ack.anchor.anchor?.precision, expected, "read \(lateBy) s after the press")
        }
    }

    func testAPhoneReadingIsUsedUpToTwoSecondsOldAndStaleAfter() {
        for (age, usable) in [(1.9, true), (2.0, true), (2.1, false)] {
            var handoff = WatchCaptureHandoff()
            guard case .start(let ack) = handoff.begin(request(), reading: reading(at: 0), now: t0.addingTimeInterval(age)) else {
                return XCTFail("expected a start")
            }
            if usable {
                XCTAssertEqual(ack.anchor.anchor?.positionMs, 61_000, "a reading \(age) s old")
            } else {
                XCTAssertEqual(ack.anchor, .unavailable(.staleReading), "a reading \(age) s old")
            }
        }
    }

    func testACaptureStopsHoldingPlaybackTenMinutesAfterItBegan() {
        var handoff = WatchCaptureHandoff()
        _ = handoff.begin(request("lost"), reading: reading(), now: t0)
        XCTAssertEqual(handoff.openCaptureIds(now: t0.addingTimeInterval(599)), ["lost"])
        XCTAssertEqual(handoff.openCaptureIds(now: t0.addingTimeInterval(600)), ["lost"])
        XCTAssertEqual(handoff.openCaptureIds(now: t0.addingTimeInterval(601)), [])

        // The same through `end`: a second capture that ends 599 s in still sees the first as open.
        _ = handoff.begin(request("cap-2"), reading: reading(playing: false, at: 598), now: t0.addingTimeInterval(598))
        XCTAssertEqual(handoff.end(captureId: "cap-2", as: .saved, reading: reading(playing: false, at: 599)), .leavePlayback(.anotherCaptureOpen))
    }

    /// Old Watch builds send no playing flag, and "nil counts as running": playback may have run on for
    /// seconds before it stopped, so a request that arrives late is approximate, not exact.
    func testARequestFromAnOlderWatchWithNoPlayingFlagCountsAsRunning() {
        var handoff = WatchCaptureHandoff()
        let stopped = reading(playing: false, at: 30)
        guard case .start(let ack) = handoff.begin(request(playing: nil), reading: stopped, now: stopped.readAt) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(ack.anchor.anchor?.precision, .approximate)
        XCTAssertEqual(ack.anchor.anchor?.approximateReason, .requestArrivedLate)

        // The same request while the phone is still within the tolerance stays exact.
        var prompt = WatchCaptureHandoff()
        let soon = reading(playing: false, at: 1)
        guard case .start(let promptAck) = prompt.begin(request(playing: nil), reading: soon, now: soon.readAt) else {
            return XCTFail("expected a start")
        }
        XCTAssertEqual(promptAck.anchor.anchor?.precision, .exact)
    }

    // MARK: Bounded memory

    /// A retry is answered from the last 64 ended captures. A capture that ended 64 captures ago is
    /// forgotten, so a retry for it is a new capture; it can't be one that is still recording.
    func testOnlyTheLast64EndedCapturesAreRemembered() {
        var handoff = WatchCaptureHandoff()
        for index in 0..<65 {
            let id = "cap-\(index)"
            _ = handoff.begin(request(id, playing: false), reading: reading(playing: false), now: t0)
            XCTAssertEqual(handoff.end(captureId: id, as: .saved, reading: reading(playing: false, at: 1)), .leavePlayback(.notPausedForCapture), id)
        }
        for index in 1..<65 {
            let id = "cap-\(index)"
            guard case .duplicate = handoff.begin(request(id, playing: false), reading: reading(playing: false), now: t0) else {
                return XCTFail("\(id) ended within the last 64 captures and should still be remembered")
            }
            XCTAssertEqual(handoff.end(captureId: id, as: .saved, reading: reading(playing: false, at: 2)), .ignored(.alreadyEnded), id)
        }
        guard case .start = handoff.begin(request("cap-0", playing: false), reading: reading(playing: false), now: t0) else {
            return XCTFail("cap-0 ended 64 captures ago and is forgotten, so its retry begins a new capture")
        }
    }

    /// Ends that arrive before their start are remembered the same way, so the late start doesn't pause.
    func testOnlyTheLast64EarlyEndsAreRemembered() {
        var handoff = WatchCaptureHandoff()
        for index in 0..<65 {
            XCTAssertEqual(handoff.end(captureId: "cap-\(index)", as: .saved, reading: reading(at: 9)), .ignored(.endBeforeStart))
        }
        for index in 1..<65 {
            guard case .alreadyEnded(let ack) = handoff.begin(request("cap-\(index)"), reading: reading(at: 9.5), now: t0.addingTimeInterval(9.5)) else {
                return XCTFail("cap-\(index) ended before it started, within the last 64, and should be remembered")
            }
            XCTAssertFalse(ack.pausedPlayback)
        }
        XCTAssertNil(handoff.pausedAtTransportGeneration)
        guard case .start(let ack) = handoff.begin(request("cap-0"), reading: reading(at: 9.5), now: t0.addingTimeInterval(9.5)) else {
            return XCTFail("cap-0's early end is 64 early ends old and forgotten, so its start begins a new capture")
        }
        XCTAssertTrue(ack.pausedPlayback)
    }

    func testMessagesRoundTripAsJSON() throws {
        let ack = WatchCaptureAcknowledgement(
            captureId: "cap-1",
            anchor: .anchored(WatchCaptureAnchor(source: episode, positionMs: 1, precision: .approximate, approximateReason: .requestArrivedLate)),
            pausedPlayback: true
        )
        XCTAssertEqual(try JSONDecoder().decode(WatchCaptureAcknowledgement.self, from: JSONEncoder().encode(ack)), ack)
        let unanchored = WatchCaptureAcknowledgement(captureId: "cap-2", anchor: .unavailable(.staleReading), pausedPlayback: false)
        XCTAssertEqual(try JSONDecoder().decode(WatchCaptureAcknowledgement.self, from: JSONEncoder().encode(unanchored)), unanchored)
        let request = request()
        XCTAssertEqual(try JSONDecoder().decode(WatchCaptureRequest.self, from: JSONEncoder().encode(request)), request)
    }
}
