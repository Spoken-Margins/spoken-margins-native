import XCTest
@testable import SessionKitAudio

/// #166: the clock stopped while the app showed "playing"; the detector reports each stall once, then its end.
final class PlaybackStallDetectorTests: XCTestCase {
    func testReportsAStallOnceAfterTheThresholdAndItsEndWhenTheClockMoves() {
        var detector = PlaybackStallDetector()
        XCTAssertNil(detector.observe(uptimeMs: 0, mediaTimeMs: 346_900, intendsToPlay: true))
        XCTAssertNil(detector.observe(uptimeMs: 2_000, mediaTimeMs: 346_910, intendsToPlay: true))
        XCTAssertNil(detector.observe(uptimeMs: 4_000, mediaTimeMs: 346_920, intendsToPlay: true))
        XCTAssertEqual(detector.observe(uptimeMs: 6_000, mediaTimeMs: 346_921, intendsToPlay: true),
                       .stalled(atMediaTimeMs: 346_900, forMs: 6_000))
        XCTAssertNil(detector.observe(uptimeMs: 60_000, mediaTimeMs: 346_921, intendsToPlay: true), "reported once")
        XCTAssertEqual(detector.observe(uptimeMs: 150_000, mediaTimeMs: 573_799, intendsToPlay: true),
                       .ended(fromMediaTimeMs: 346_900, toMediaTimeMs: 573_799, stalledForMs: 150_000))
        XCTAssertNil(detector.observe(uptimeMs: 152_000, mediaTimeMs: 575_300, intendsToPlay: true))
    }

    func testNormalPlaybackAndPausesAreNotStalls() {
        var detector = PlaybackStallDetector()
        for second in 0..<20 {
            XCTAssertNil(detector.observe(uptimeMs: second * 2_000, mediaTimeMs: second * 3_000, intendsToPlay: true))
        }
        XCTAssertNil(detector.observe(uptimeMs: 50_000, mediaTimeMs: 57_000, intendsToPlay: false))
        XCTAssertNil(detector.observe(uptimeMs: 90_000, mediaTimeMs: 57_000, intendsToPlay: false), "paused isn't stalled")
        XCTAssertNil(detector.observe(uptimeMs: 92_000, mediaTimeMs: 57_000, intendsToPlay: true), "resume starts fresh")
        XCTAssertNil(detector.observe(uptimeMs: 94_000, mediaTimeMs: 58_000, intendsToPlay: true))
    }

    func testPausingDuringAStallEndsIt() {
        var detector = PlaybackStallDetector()
        _ = detector.observe(uptimeMs: 0, mediaTimeMs: 10_000, intendsToPlay: true)
        XCTAssertNotNil(detector.observe(uptimeMs: 8_000, mediaTimeMs: 10_000, intendsToPlay: true))
        XCTAssertEqual(detector.observe(uptimeMs: 20_000, mediaTimeMs: 10_000, intendsToPlay: false),
                       .ended(fromMediaTimeMs: 10_000, toMediaTimeMs: 10_000, stalledForMs: 20_000))
    }
}
