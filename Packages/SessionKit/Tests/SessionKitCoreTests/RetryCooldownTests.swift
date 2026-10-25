import Foundation
import SessionKit
import XCTest

final class RetryCooldownTests: XCTestCase {
    private final class Clock { var date = Date(timeIntervalSince1970: 1_000) }

    /// Mirrors a schedule that runs on every trigger and only attempts when the cooldown allows.
    private func trigger(_ cooldown: inout RetryCooldown, key: String, attempts: inout Int, succeeds: Bool) {
        guard cooldown.canAttempt(key) else { return }
        attempts += 1
        if succeeds { cooldown.recordSuccess(key) } else { cooldown.recordFailure(key) }
    }

    func testManyTriggersAfterOneFailureMakeOneAttempt() {
        let clock = Clock()
        var cooldown = RetryCooldown(base: 30, ceiling: 600, now: { clock.date })
        var attempts = 0
        for _ in 0..<50 { trigger(&cooldown, key: "a", attempts: &attempts, succeeds: false) }
        XCTAssertEqual(attempts, 1)
    }

    func testAttemptIsAllowedAgainAfterCooldownAndBacksOffToCeiling() {
        let clock = Clock()
        var cooldown = RetryCooldown(base: 30, ceiling: 100, now: { clock.date })
        var attempts = 0
        trigger(&cooldown, key: "a", attempts: &attempts, succeeds: false)
        clock.date.addTimeInterval(29)
        XCTAssertFalse(cooldown.canAttempt("a"))
        clock.date.addTimeInterval(1)
        XCTAssertTrue(cooldown.canAttempt("a"))
        trigger(&cooldown, key: "a", attempts: &attempts, succeeds: false)
        clock.date.addTimeInterval(59)
        XCTAssertFalse(cooldown.canAttempt("a"))
        clock.date.addTimeInterval(1)
        trigger(&cooldown, key: "a", attempts: &attempts, succeeds: false)
        clock.date.addTimeInterval(99)
        XCTAssertFalse(cooldown.canAttempt("a"))
        clock.date.addTimeInterval(1)
        XCTAssertTrue(cooldown.canAttempt("a"))
        XCTAssertEqual(attempts, 3)
    }

    func testKeysAreIndependentAndSuccessAndClearForgetFailures() {
        let clock = Clock()
        var cooldown = RetryCooldown(base: 30, ceiling: 600, now: { clock.date })
        cooldown.recordFailure("a")
        XCTAssertTrue(cooldown.canAttempt("b"))
        cooldown.clear("a")
        XCTAssertTrue(cooldown.canAttempt("a"))
        XCTAssertEqual(cooldown.failureCount("a"), 0)
        cooldown.recordFailure("a")
        cooldown.recordSuccess("a")
        XCTAssertTrue(cooldown.canAttempt("a"))
    }
}
