import Foundation
import XCTest
@testable import SessionKit

/// #2481, owner rule 2026-10-22: a Margin's source position = start position + elapsed wall time × rate, where
/// the rate comes from the end position when there is one; estimates are "about"; transcript anchors override.
final class LiveSessionPositionMapTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(start: Int?, end: Int?, wallSeconds: Double?) -> LiveSession {
        LiveSession(
            id: "s", kind: .audiobook, startedAt: t0, endedAt: wallSeconds.map { t0.addingTimeInterval($0) },
            startPositionMs: start, endPositionMs: end
        )
    }

    func testOneAndAHalfSpeedWithNoPauses() throws {
        // 10 minutes of wall time covered 15 minutes of the book.
        let live = session(start: 3_600_000, end: 4_500_000, wallSeconds: 600)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: live), 1.5, accuracy: 1e-9)
        let position = try XCTUnwrap(LiveSessionPositionMap.position(at: t0.addingTimeInterval(200), in: live))
        XCTAssertEqual(position.ms, 3_900_000)
        XCTAssertTrue(position.isApproximate)
        XCTAssertEqual(position.label, "about 1:05:00")
    }

    func testAMidSessionPauseIsAveragedIn() throws {
        // 20 minutes on the clock, 5 of them paused: 15 minutes of the book at 1×, so the rate is 0.75.
        let live = session(start: 0, end: 900_000, wallSeconds: 1_200)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: live), 0.75, accuracy: 1e-9)
        XCTAssertEqual(LiveSessionPositionMap.position(at: t0.addingTimeInterval(600), in: live)?.ms, 450_000)
        // Past the end of the session it stays at the end position.
        XCTAssertEqual(LiveSessionPositionMap.position(at: t0.addingTimeInterval(5_000), in: live)?.ms, 900_000)
        // Before the start it stays at the start position.
        XCTAssertEqual(LiveSessionPositionMap.position(at: t0.addingTimeInterval(-30), in: live)?.ms, 0)
    }

    func testNoEndPositionMeansRealTime() {
        let live = session(start: 120_000, end: nil, wallSeconds: 600)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: live), 1)
        XCTAssertEqual(LiveSessionPositionMap.position(at: t0.addingTimeInterval(90), in: live)?.ms, 210_000)
        // Still running: rate 1 even with an end position typed early.
        let running = session(start: 0, end: 60_000, wallSeconds: nil)
        XCTAssertEqual(LiveSessionPositionMap.rate(for: running), 1)
        XCTAssertNil(LiveSessionPositionMap.position(at: t0, in: session(start: nil, end: nil, wallSeconds: nil)))
    }

    func testAnEndBeforeTheStartIsRejected() {
        XCTAssertThrowsError(try LiveSessionPositionMap.validate(startPositionMs: 600_000, endPositionMs: 300_000)) {
            XCTAssertEqual($0 as? LiveSessionPositionMap.Failure, .endBeforeStart)
        }
        XCTAssertNoThrow(try LiveSessionPositionMap.validate(startPositionMs: 0, endPositionMs: 0))
        XCTAssertNoThrow(try LiveSessionPositionMap.validate(startPositionMs: 0, endPositionMs: nil))
        // A stored bad end is ignored rather than trusted.
        XCTAssertEqual(LiveSessionPositionMap.rate(for: session(start: 600_000, end: 300_000, wallSeconds: 600)), 1)
    }

    func testAnchorsOverrideTheEstimateWithinTheirSpan() throws {
        let live = session(start: 0, end: 600_000, wallSeconds: 600)
        let anchors = [
            LiveSessionPositionMap.Anchor(wallTime: t0.addingTimeInterval(100), positionMs: 200_000),
            LiveSessionPositionMap.Anchor(wallTime: t0.addingTimeInterval(300), positionMs: 300_000)
        ]
        let pinned = try XCTUnwrap(LiveSessionPositionMap.position(at: t0.addingTimeInterval(100), in: live, anchors: anchors))
        XCTAssertEqual(pinned, .init(ms: 200_000, isApproximate: false))
        XCTAssertEqual(pinned.label, "3:20")
        // Halfway between the anchors: halfway between their positions, not the estimate's 200 s.
        XCTAssertEqual(LiveSessionPositionMap.position(at: t0.addingTimeInterval(200), in: live, anchors: anchors), .init(ms: 250_000, isApproximate: true))
        // Outside their span, the start/end estimate.
        XCTAssertEqual(LiveSessionPositionMap.position(at: t0.addingTimeInterval(400), in: live, anchors: anchors)?.ms, 400_000)
    }

    func testParsingWhatTheListenerTypes() {
        XCTAssertEqual(LiveSessionPositionMap.parse("2"), 120_000)
        XCTAssertEqual(LiveSessionPositionMap.parse("2:00"), 120_000)
        XCTAssertEqual(LiveSessionPositionMap.parse(" 1:23:10 "), 4_990_000)
        XCTAssertNil(LiveSessionPositionMap.parse(""))
        XCTAssertNil(LiveSessionPositionMap.parse("chapter 4"))
    }

    func testAMeetingClockAtTheStartSetsTheTranscriptZero() {
        let live = LiveSession(id: "m", kind: .meeting, startedAt: t0, startPositionMs: 120_000)
        let transcript = ImportedTranscript(format: .webVTT, cues: [TranscriptCue(startMs: 0, endMs: 1_000, text: "Hello there everyone")])
        XCTAssertEqual(TranscriptAlignment.fallbackStart(transcript: transcript, session: live, roughStart: nil).date, t0.addingTimeInterval(-120))
    }
}
