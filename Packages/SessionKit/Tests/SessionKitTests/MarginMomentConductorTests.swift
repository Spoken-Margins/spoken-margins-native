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

    /// #1646: a skip of any length is not playback reaching the Margin just ahead.
    func testASkipOverAMarginDoesNotPlayItEvenWhenTheSkipIsShort() throws {
        var unavailable: [String] = []
        let conductor = MarginMomentConductor(
            sequence: MarginMomentSequence(
                itemId: "article", target: MarginMomentAnchor(marginId: "ij-009", mediaTimeMs: 5_000), otherMargins: [],
                tickAdvanceLimitMs: 6_000
            ),
            source: .init(pause: {}, resume: {}, seek: { _ in }),
            voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/ij-009.m4a") }
        )
        conductor.onVoiceUnavailable = { id, reason in unavailable.append("\(id):\(reason)") }
        conductor.start()
        conductor.observe(mediaTimeMs: 4_000)
        conductor.sourceMoved()
        conductor.observe(mediaTimeMs: 5_500)
        XCTAssertEqual(unavailable, [], "the reading after a skip has nothing before it to cross from")
        XCTAssertEqual(conductor.sequence.unplayed.count, 1, "the Margin still waits")
    }

    func testReadingStillReachesTheMarginAfterASkip() throws {
        var unavailable: [String] = []
        let conductor = MarginMomentConductor(
            sequence: MarginMomentSequence(
                itemId: "article", target: MarginMomentAnchor(marginId: "ij-009", mediaTimeMs: 5_000), otherMargins: []
            ),
            source: .init(pause: {}, resume: {}, seek: { _ in }),
            voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/ij-009.m4a") }
        )
        conductor.onVoiceUnavailable = { id, reason in unavailable.append("\(id):\(reason)") }
        conductor.sourceMoved()
        conductor.observe(mediaTimeMs: 3_000)
        conductor.observe(mediaTimeMs: 4_800)
        XCTAssertEqual(unavailable, [])
        conductor.observe(mediaTimeMs: 5_200)
        XCTAssertEqual(unavailable, ["ij-009:recording_missing"])
    }

    /// #1646 audit: the app reports every seek to `sourceMoved()`, including the lead-in's own, which must not wipe
    /// the baseline: the first reading after the lead-in starts still crosses a Margin just after the start.
    func testTheLeadInsOwnSeekDoesNotCostTheFirstReadingItsBaseline() throws {
        var unavailable: [String] = []
        var conductorBox: MarginMomentConductor?
        let conductor = MarginMomentConductor(
            sequence: MarginMomentSequence(
                itemId: "episode", target: MarginMomentAnchor(marginId: "target", mediaTimeMs: 40_000),
                otherMargins: [MarginMomentAnchor(marginId: "early", mediaTimeMs: 10_200)]
            ),
            source: .init(pause: {}, resume: {}, seek: { _ in conductorBox?.sourceMoved() }),
            voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/voice.m4a") }
        )
        conductorBox = conductor
        conductor.onVoiceUnavailable = { id, reason in unavailable.append("\(id):\(reason)") }
        XCTAssertEqual(conductor.sequence.startMediaTimeMs, 10_000)
        conductor.start()
        conductor.observe(mediaTimeMs: 10_450)
        XCTAssertEqual(unavailable, ["early:recording_missing"], "10.0 s to 10.45 s crosses the Margin at 10.2 s")
    }
}
#endif
