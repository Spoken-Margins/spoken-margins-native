#if canImport(AVFoundation)
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// "Play this moment" (#159) with no player at all: the conductor's own rules, driven by hand-fed clock readings.
/// The tests that play real audio are in RealPlayerMarginMomentTests.
@MainActor
final class MarginMomentConductorTests: XCTestCase {
    func testAMissingRecordingIsReportedAndTheEpisodeKeepsPlaying() throws {
        var resumed = 0
        let conductor = MarginMomentConductor(
            sequence: MarginMomentSequence(
                itemId: "episode", target: MarginMomentAnchor(marginId: "ij-009", mediaTimeMs: 5_000), otherMargins: []
            ),
            source: .init(pause: {}, resume: { resumed += 1 }, seek: { _ in }),
            voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/ij-009.m4a") }
        )
        var unavailable: [String] = []
        conductor.onVoiceUnavailable = { id, reason in unavailable.append("\(id):\(reason)") }
        conductor.start()
        conductor.observe(mediaTimeMs: 4_800)
        conductor.observe(mediaTimeMs: 5_200)
        XCTAssertEqual(unavailable, ["ij-009:recording_missing"])
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(conductor.sequence.phase, .listening)
    }
}
#endif
