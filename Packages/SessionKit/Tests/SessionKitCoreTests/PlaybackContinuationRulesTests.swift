import Foundation
import XCTest
@testable import SessionKit

final class PlaybackContinuationRulesTests: XCTestCase {
    private func session(_ id: String, status: String = "in_progress", phase: SessionPhase = .itemPlayback,
                         percent: Int = 0, created: TimeInterval? = nil, updated: TimeInterval? = nil) -> Session {
        Session(id: id, itemId: "item", createdAt: created.map(Date.init(timeIntervalSince1970:)),
                updatedAt: updated.map(Date.init(timeIntervalSince1970:)), status: status, phase: phase,
                currentTargetType: .itemTextTTS, currentTargetId: "item", position: Position(),
                completionPercent: percent, playbackRate: 1)
    }

    func testContinuationEligibilityAndOrdering() {
        let eligible = session("progress")
        let abandoned = session("abandoned", phase: .abandoned, updated: 100)
        let incomplete = session("99", status: "finished", phase: .finished, percent: 99, updated: 100)
        let complete = session("100", status: "finished", phase: .finished, percent: 100, updated: 10)
        XCTAssertTrue(SessionContinuation.isResumableSession(eligible))
        XCTAssertFalse(SessionContinuation.isResumableSession(abandoned))
        XCTAssertFalse(SessionContinuation.isResumableSession(complete))
        XCTAssertNil(SessionContinuation.preferredContinuationSession(in: [abandoned, incomplete]))
        XCTAssertNil(SessionContinuation.preferredContinuationSession(in: []))
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: [eligible, incomplete, abandoned, complete])?.id, "100")
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: [session("over", status: "finished", percent: 101)])?.id, "over")
        XCTAssertNil(SessionContinuation.preferredContinuationSession(in: [session("other", status: "paused", percent: 100)]))
        let rows = [session("b"), session("a"), session("created", created: 5),
                    session("updated", created: 1, updated: 6)]
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: rows)?.id, "updated")
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: Array(rows.prefix(3)))?.id, "created")
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: Array(rows.prefix(2)))?.id, "a")
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: [session("z", updated: 5), session("a", created: 5)])?.id, "a")
        XCTAssertEqual(SessionContinuation.preferredContinuationSession(in: [session("z", created: 99, updated: 1), session("a", created: 2)])?.id, "a")
    }

    func testStatusWordingIsByteIdentical() {
        let cases = [("not_started", "not started"), ("rendering", "preparing"),
                     ("starter_ready", "starter ready"), ("ready", "ready"), ("complete", "ready"),
                     ("failed", "failed"), ("live_fallback", "live fallback"), ("queued", "queued"),
                     ("downloading", "downloading"), ("transcribing", "transcribing"),
                     ("unavailable", "unavailable"), ("Not started", "Not started"),
                     ("other_status", "other status"), ("", ""), (" READY_é ", " READY é ")]
        for (input, expected) in cases {
            XCTAssertEqual(Array(PlaybackStatusWording.humanReadableStatus(input).utf8), Array(expected.utf8), input)
        }
    }

    func testSpeechGenerationStatusTargetSupport() {
        for target: TargetType in [.itemTextTTS, .summaryTurnTTS, .assistantTurnTTS, .transcriptBackedMedia, .browserOwnedMedia] {
            let expected: Bool = [.itemTextTTS, .summaryTurnTTS, .assistantTurnTTS].contains(target)
            XCTAssertEqual(PlaybackStatusWording.supportsOnDeviceSpeechGenerationStatus(targetType: target.rawValue), expected, target.rawValue)
        }
        for target: String? in [nil, "", "ITEM_TEXT_TTS", "unknown"] {
            XCTAssertFalse(PlaybackStatusWording.supportsOnDeviceSpeechGenerationStatus(targetType: target))
        }
    }

    func testSharedMarginRawPercentPrefersMediaThenTextAndRounds() {
        let cases: [(Int?, Int?, Int?, Int, Int?)] = [
            (1, 8, 90, 100, 13), (0, 100, 90, 100, 0),
            (nil, 100, 1, 8, 13), (1, nil, 1, 8, 13),
            (1, 0, 1, 8, 13), (1, -1, 1, 8, 13),
            (nil, nil, nil, 100, nil), (nil, nil, 1, 0, nil), (nil, nil, 1, -1, nil),
            (1, 100, nil, 0, 1), (124, 1000, nil, 0, 12),
            (101, 100, nil, 0, 101), (-1, 8, nil, 0, -13),
            (nil, nil, 101, 100, 101), (nil, nil, -1, 8, -13)
        ]
        for (time, duration, offset, length, expected) in cases {
            XCTAssertEqual(SharedMarginPosition.percent(mediaTimeMs: time, mediaDurationMs: duration,
                                                       charOffset: offset, textLength: length), expected)
        }
    }
}
