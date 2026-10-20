import AVFoundation
import XCTest
@testable import SpokenMarginsApp

/// #2101: the client asked the audio session to activate at every chunk seam and twice per play tap, each a
/// synchronous call to the audio server on the main thread. It now activates once for a run and again only
/// after something that can end or change the session.
@MainActor
final class SupertonicSessionActivationTests: XCTestCase {
    func testChunkSeamsDoNotActivateTheSessionAgain() async throws {
        let harness = try SupertonicClientHarness()
        defer { harness.tearDown() }
        try await harness.start(waitingForRenders: 4)
        let activated = harness.sessionActivations.values.count
        XCTAssertGreaterThan(activated, 0, "starting a run activates the session")

        for seam in 1...3 {
            let before = harness.playerStarts
            await harness.finishPlayingChunk()
            let next = await harness.waitForPlayerStarts(before + 1)
            XCTAssertTrue(next, "chunk \(seam + 1) started")
        }

        XCTAssertEqual(harness.sessionActivations.values.count, activated, "three seams activated the session again")
    }

    func testPlayingAgainAfterAPauseActivatesTheSession() async throws {
        let harness = try SupertonicClientHarness()
        defer { harness.tearDown() }
        try await harness.start(waitingForRenders: 2)
        let beforePause = harness.sessionActivations.values.count

        try harness.client.pause()
        let resumeAt = try XCTUnwrap(harness.client.currentCharOffset())
        try harness.play(from: resumeAt)

        XCTAssertGreaterThan(harness.sessionActivations.values.count, beforePause, "resuming re-activates the session")
    }

    func testASeamAfterARouteChangeActivatesTheSessionAgain() async throws {
        let center = NotificationCenter()
        let harness = try SupertonicClientHarness(notificationCenter: center)
        defer { harness.tearDown() }
        try await harness.start(waitingForRenders: 3)
        let beforeRouteChange = harness.sessionActivations.values.count

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        )
        try await Task.sleep(for: .milliseconds(100))
        let before = harness.playerStarts
        await harness.finishPlayingChunk()
        let next = await harness.waitForPlayerStarts(before + 1)

        XCTAssertTrue(next, "the next chunk started")
        XCTAssertGreaterThan(harness.sessionActivations.values.count, beforeRouteChange, "a route change ends the activation")
    }

    // A refused start is re-seated to put the session back; the remembered activation must not turn that into a no-op.
    func testReseatingARefusedStartActivatesTheSessionForReal() async throws {
        let harness = try SupertonicClientHarness(
            applicationIsActive: { false }, applicationIsInBackground: { true }
        )
        defer { harness.tearDown() }
        try await harness.start()
        let starts = harness.playerStarts
        let beforeRefusal = harness.sessionActivations.values.count

        harness.refuseTheNewestPlayersStart()

        let reseated = await harness.waitForPlayerStarts(starts + 1)
        XCTAssertTrue(reseated, "the refused player was re-seated")
        XCTAssertGreaterThan(harness.sessionActivations.values.count, beforeRefusal, "the re-seat activated the session again")
    }
}
