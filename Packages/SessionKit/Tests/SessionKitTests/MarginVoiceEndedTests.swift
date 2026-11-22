#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #4711: the conductor tells the app how a Margin's voice stopped, so "first Margin heard" fires only for a voice that
/// played to its end. Real recording, real `AVAudioPlayer`, muted; waits on the callback, never on the clock.
@MainActor
final class MarginVoiceEndedTests: XCTestCase {
    private struct Ended: Equatable {
        let marginId: String
        let reachedEnd: Bool
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let conductor: MarginMomentConductor
        var ended: [Ended] = []
        var resumed = 0
        var onEnded: (() -> Void)?

        init(recordingExists: Bool = true, seconds: Double = 0.5) throws {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "voice-ended-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "ij-001.caf")
            if recordingExists { _ = try RealPlayerMarginMomentTests.writeTone(to: url, seconds: seconds, hz: 440) }
            var resume: () -> Void = {}
            conductor = MarginMomentConductor(
                sequence: MarginMomentSequence(
                    itemId: "episode", target: MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 2_500), otherMargins: []
                ),
                source: .init(pause: {}, resume: { resume() }, seek: { _ in }),
                voiceURL: { _ in url }
            )
            resume = { [unowned self] in resumed += 1 }
            conductor.voiceVolume = 0
            conductor.onVoiceEnded = { [unowned self] margin, reachedEnd in
                ended.append(Ended(marginId: margin.marginId, reachedEnd: reachedEnd))
                onEnded?()
            }
        }

        func cleanUp() {
            conductor.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func waitForEnd(_ fixture: Fixture, line: UInt = #line) {
        guard fixture.ended.isEmpty else { return }
        let ended = expectation(description: "voice ended")
        fixture.onEnded = { ended.fulfill() }
        wait(for: [ended], timeout: 30) // a ceiling, not the expected time
        XCTAssertFalse(fixture.ended.isEmpty, line: line)
    }

    func testAVoiceThatPlaysOutReportsReachedEnd() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.conductor.start()
        fixture.conductor.playTargetNow()
        XCTAssertTrue(fixture.conductor.isPlayingVoice)
        waitForEnd(fixture)
        XCTAssertEqual(fixture.ended, [Ended(marginId: "ij-001", reachedEnd: true)])
        XCTAssertEqual(fixture.resumed, 1, "the source still resumes as before")
    }

    func testSkippingReportsNotReachedEnd() throws {
        let fixture = try Fixture(seconds: 5)
        defer { fixture.cleanUp() }
        fixture.conductor.start()
        fixture.conductor.playTargetNow()
        XCTAssertTrue(fixture.conductor.isPlayingVoice)
        fixture.conductor.skipVoice()
        XCTAssertEqual(fixture.ended, [Ended(marginId: "ij-001", reachedEnd: false)])
        XCTAssertEqual(fixture.resumed, 1)
    }

    func testAMissingRecordingReportsNotReachedEnd() throws {
        let fixture = try Fixture(recordingExists: false)
        defer { fixture.cleanUp() }
        fixture.conductor.start()
        fixture.conductor.playTargetNow()
        XCTAssertEqual(fixture.ended, [Ended(marginId: "ij-001", reachedEnd: false)])
    }

    /// The regression test for the `successfully` check: a finish the system reports as unsuccessful (the player's
    /// own flag) is not an end. Without the check this reports true.
    func testAnUnsuccessfulFinishReportsNotReachedEnd() throws {
        let fixture = try Fixture(seconds: 5)
        defer { fixture.cleanUp() }
        fixture.conductor.start()
        fixture.conductor.playTargetNow()
        fixture.conductor.deliverVoiceFinishForTesting(successfully: false)
        waitForEnd(fixture)
        XCTAssertEqual(fixture.ended, [Ended(marginId: "ij-001", reachedEnd: false)])
    }

    func testCancellingReportsNothing() throws {
        let fixture = try Fixture(seconds: 5)
        defer { fixture.cleanUp() }
        fixture.conductor.start()
        fixture.conductor.playTargetNow()
        XCTAssertTrue(fixture.conductor.isPlayingVoice)
        fixture.conductor.cancel()
        XCTAssertEqual(fixture.ended, [])
        XCTAssertFalse(fixture.conductor.isPlayingVoice)
    }

    func testStoppingAReviewReportsNothing() throws {
        let fixture = try Fixture(seconds: 5)
        defer { fixture.cleanUp() }
        fixture.conductor.start()
        fixture.conductor.playTargetNow()
        fixture.conductor.stopReview()
        XCTAssertEqual(fixture.ended, [])
    }
}
#endif
