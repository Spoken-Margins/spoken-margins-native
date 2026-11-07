#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import SessionKitAudio
import SessionKit

/// The saved-Margin report path starts its cue without waiting on the audio system. The session gate stands in
/// for the slow part (`AVAudioSession` does not exist on macOS), so what these show is the main thread's wait, not
/// the device's.
final class OffMainOutcomeCuePlayerTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var result: String?
        var onMain = false
    }

    private func slowGate(_ seconds: Double, reason: String? = nil) -> OffMainOutcomeCuePlayer.SessionGate {
        { Thread.sleep(forTimeInterval: seconds); return reason }
    }

    private func elapsedMs(_ body: () -> Void) -> Double {
        let d = ContinuousClock().measure(body)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    func testStartingACueDoesNotWaitForTheAudioSystem() {
        let player = OffMainOutcomeCuePlayer(sessionGate: slowGate(0.4))
        let done = expectation(description: "completion")
        let box = Box()
        let startMs = elapsedMs {
            player.play(.saved) { box.result = $0; box.onMain = Thread.isMainThread; done.fulfill() }
        }
        XCTAssertLessThan(startMs, 50, "play must return before the slow audio call finishes")
        wait(for: [done], timeout: 5)
        XCTAssertTrue(box.onMain)
        XCTAssertNotNil(box.result)
        // The old shape, waiting for the answer on the calling thread, is the cost that was moved.
        let waitedMs = elapsedMs { _ = OffMainOutcomeCuePlayer(sessionGate: slowGate(0.4)).playAndWait(.saved) }
        XCTAssertGreaterThanOrEqual(waitedMs, 400)
        print("outcome cue (host, 400 ms stand-in): caller waits \(Int(startMs)) ms started off-main vs \(Int(waitedMs)) ms inline")
    }

    func testGateReasonComesBackAndNothingSounds() {
        let player = OffMainOutcomeCuePlayer(sessionGate: { "skipped:other_audio" })
        let done = expectation(description: "completion")
        let box = Box()
        player.play(.savedMaybeCut) { box.result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.result, "skipped:other_audio")
        XCTAssertFalse(player.isPlaying)
    }

    func testAStopSentAfterACueEndsItEvenWhenTheCueStartsLate() {
        let player = OffMainOutcomeCuePlayer(sessionGate: slowGate(0.2))
        player.play(.micStopped) { _ in }
        player.stop()
        player.drain()
        XCTAssertFalse(player.isPlaying, "the stop was sent after the cue, so it lands after it")
    }

    /// The audit on 50b2782: Try again sent the stop and started the new recorder straight away, so a looping cue
    /// could still be sounding into the new file. The queue here is busy with a slow cue start, as when the audio
    /// service is slow: the restart must come after that and the stop behind it, and the caller must not wait for them.
    @MainActor
    func testTryAgainsRestartFollowsTheCuesStopWithoutTheCallerWaiting() {
        let box = OrderBox()
        let player = OffMainOutcomeCuePlayer(sessionGate: { Thread.sleep(forTimeInterval: 0.4); box.earlierWorkDone = true; return nil })
        player.play(.micStopped) { _ in }
        let order = MarginCaptureRetryOrder()
        let restarted = expectation(description: "restart")
        let callerMs = elapsedMs {
            order.begin(stop: { finished in player.stop(then: { Task { @MainActor in finished() } }) }) {
                box.earlierWorkDoneAtRestart = box.earlierWorkDone
                restarted.fulfill()
            }
        }
        XCTAssertLessThan(callerMs, 50, "the main thread does not wait for the stop")
        XCTAssertTrue(order.isWaiting)
        wait(for: [restarted], timeout: 5)
        XCTAssertEqual(box.earlierWorkDoneAtRestart, true, "the restart ran ahead of the stop")
        XCTAssertFalse(order.isWaiting)
        XCTAssertFalse(player.isPlaying)
    }

    private final class OrderBox: @unchecked Sendable {
        var earlierWorkDone = false
        var earlierWorkDoneAtRestart: Bool?
    }

    func testANewCueReplacesTheOneSounding() {
        let player = OffMainOutcomeCuePlayer()
        XCTAssertNotNil(player.playAndWait(.micStopped))
        _ = player.playAndWait(.saved)
        player.stop()
        player.drain()
        XCTAssertFalse(player.isPlaying)
    }

    /// Real AVFoundation on macOS: building the cue's WAV and the player is small. The audio session's share on a
    /// phone cannot be measured here.
    func testHostCostOfBuildingAndStartingTheRealPlayer() throws {
        var data = Data()
        let buildMs = elapsedMs { data = MarginOutcomeCue.saved.wavData() }
        var player: AVAudioPlayer?
        let initMs = elapsedMs { player = try? AVAudioPlayer(data: data) }
        let playMs = elapsedMs { _ = player?.play() }
        player?.stop()
        print("outcome cue (host): wav \(Int(buildMs)) ms, player init \(Int(initMs)) ms, play \(Int(playMs)) ms")
        XCTAssertGreaterThan(data.count, 44)
    }
}
#endif
