import XCTest
@testable import SessionKitAudio

/// #2094: the player's clock froze while the audio played on; the decoded audio's time overrules it.
final class DecodedAudioClockGuardTests: XCTestCase {
    private typealias Sample = DecodedAudioClockGuard.DecodedSample

    func testAMovingClockIsTrustedAndTeachesTheDecodeLead() {
        var guardian = DecodedAudioClockGuard()
        for tick in 0..<10 {
            let clock = 10_000 + tick * 1_000
            let decoded = Sample(endMediaTimeMs: clock + 300, uptimeMs: tick * 1_000)
            XCTAssertNil(guardian.observe(reportedMediaTimeMs: clock, rawClockMediaTimeMs: clock,
                                          decoded: decoded, uptimeMs: tick * 1_000))
        }
        XCTAssertLessThan(abs(guardian.decodeLeadMs - 300), 50, "the lead converges on what decoding shows")
    }

    func testAFrozenClockWithAudioDecodingOnIsOverruled() {
        var guardian = DecodedAudioClockGuard()
        _ = guardian.observe(reportedMediaTimeMs: 3_069_830, rawClockMediaTimeMs: 3_069_830,
                             decoded: Sample(endMediaTimeMs: 3_070_330, uptimeMs: 0), uptimeMs: 0)
        // 66 s later at 1.5×, the clock still reads the same while decoding has moved on 99 s.
        let trusted = guardian.observe(reportedMediaTimeMs: 3_069_830, rawClockMediaTimeMs: 3_069_830,
                                       decoded: Sample(endMediaTimeMs: 3_169_330, uptimeMs: 65_900), uptimeMs: 66_000)
        XCTAssertEqual(trusted, 3_169_330 - DecodedAudioClockGuard.defaultLeadMs)
    }

    func testAPendingSeekTargetIsOverruledWhenTheAudioPlaysPastIt() {
        var guardian = DecodedAudioClockGuard()
        guardian.noteSeek(uptimeMs: 0)
        _ = guardian.observe(reportedMediaTimeMs: 50_000, rawClockMediaTimeMs: 50_000, decoded: nil, uptimeMs: 100)
        let trusted = guardian.observe(reportedMediaTimeMs: 50_000, rawClockMediaTimeMs: 50_000,
                                       decoded: Sample(endMediaTimeMs: 58_000, uptimeMs: 5_000), uptimeMs: 5_100)
        XCTAssertEqual(trusted, 58_000 - DecodedAudioClockGuard.defaultLeadMs)
    }

    func testStaleOrPreSeekDecodingNeverOverrulesTheClock() {
        var guardian = DecodedAudioClockGuard()
        _ = guardian.observe(reportedMediaTimeMs: 20_000, rawClockMediaTimeMs: 20_000, decoded: nil, uptimeMs: 0)
        XCTAssertNil(guardian.observe(reportedMediaTimeMs: 20_000, rawClockMediaTimeMs: 20_000,
                                      decoded: Sample(endMediaTimeMs: 40_000, uptimeMs: 1_000), uptimeMs: 5_000),
                     "buffering: nothing decoded lately, so the clock standing still is right")
        // A rejoin seek back 3 s: audio decoded before it is not where the player is now.
        guardian.noteSeek(uptimeMs: 6_000)
        _ = guardian.observe(reportedMediaTimeMs: 17_000, rawClockMediaTimeMs: 17_000, decoded: nil, uptimeMs: 6_100)
        XCTAssertNil(guardian.observe(reportedMediaTimeMs: 17_000, rawClockMediaTimeMs: 17_000,
                                      decoded: Sample(endMediaTimeMs: 20_500, uptimeMs: 5_990), uptimeMs: 7_200))
    }

    func testAClockFrozenOnlyBrieflyOrCloseToTheAudioStands() {
        var guardian = DecodedAudioClockGuard()
        _ = guardian.observe(reportedMediaTimeMs: 1_000, rawClockMediaTimeMs: 1_000, decoded: nil, uptimeMs: 0)
        XCTAssertNil(guardian.observe(reportedMediaTimeMs: 1_000, rawClockMediaTimeMs: 1_000,
                                      decoded: Sample(endMediaTimeMs: 4_000, uptimeMs: 500), uptimeMs: 600),
                     "under a second of standing still is not a freeze")
        XCTAssertNil(guardian.observe(reportedMediaTimeMs: 1_000, rawClockMediaTimeMs: 1_000,
                                      decoded: Sample(endMediaTimeMs: 2_800, uptimeMs: 1_900), uptimeMs: 2_000),
                     "within the decode lead plus tolerance, the clock stands")
    }

    func testAPauseForgetsTheFreezeHistory() {
        var guardian = DecodedAudioClockGuard()
        _ = guardian.observe(reportedMediaTimeMs: 1_000, rawClockMediaTimeMs: 1_000, decoded: nil, uptimeMs: 0)
        guardian.notePaused()
        XCTAssertNil(guardian.observe(reportedMediaTimeMs: 1_000, rawClockMediaTimeMs: 1_000,
                                      decoded: Sample(endMediaTimeMs: 9_000, uptimeMs: 9_900), uptimeMs: 10_000),
                     "the first reading after a pause starts a new watch")
    }
}
