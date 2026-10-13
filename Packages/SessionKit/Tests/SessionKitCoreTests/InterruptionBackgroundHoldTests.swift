import Foundation
import XCTest
@testable import SessionKit

/// #1434: a message announced through AirPods paused narration, and it stayed paused. A backgrounded app with no
/// audio playing can be suspended before iOS reports the end of the interruption, so "ended, resume" never
/// arrived. The hold asks iOS for background time from the start of the interruption until it ends. They are async
/// only because Linux XCTest can't run a synchronous main-actor test.
@MainActor
final class InterruptionBackgroundHoldTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 9_000)

    func testAnInterruptionHoldsBackgroundTimeUntilIOSReportsItsEnd() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()

        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.outcome, .held)
        XCTAssertEqual(ledger.names, ["Audio interruption wait"])
        XCTAssertEqual(ledger.ends, 0, "the app must stay awake while it waits for the end")

        now = now.addingTimeInterval(6.2)
        hold.interruptionEnded()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .ended)
        XCTAssertEqual(ledger.ends, 1)
        let event = try XCTUnwrap(ledger.events.first)
        XCTAssertEqual(event.kind, "speech.interruption_hold")
        XCTAssertEqual(event.fields, ["outcome": "ended", "heldMs": "6200"])
    }

    func testTheListenerTakingOverGivesTheTimeBackAndSaysSo() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        now = now.addingTimeInterval(10.4)
        hold.listenerActed()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .listenerActed)
        XCTAssertEqual(ledger.ends, 1)
        // The owner's trace: Play ten seconds after the interruption, with no end ever reported.
        XCTAssertEqual(ledger.events.first?.fields, ["outcome": "listener_acted", "heldMs": "10400"])
    }

    func testASecondInterruptionWhileHoldingAsksForNothingMore() async {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        hold.interruptionBegan()
        hold.interruptionEnded()
        hold.interruptionEnded()

        XCTAssertEqual(ledger.begins, 1)
        XCTAssertEqual(ledger.ends, 1)
        XCTAssertEqual(ledger.events.count, 1, "one wait, one line")
    }

    func testEndingOrActingWithNothingHeldDoesNothing() async {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionEnded()
        hold.listenerActed()

        XCTAssertEqual(ledger.begins, 0)
        XCTAssertEqual(ledger.ends, 0)
        XCTAssertNil(hold.outcome)
        XCTAssertTrue(ledger.events.isEmpty)
    }

    func testTheSystemTakingTheTimeBackIsRecordedAsTheEndNeverArrivingInTime() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        now = now.addingTimeInterval(29.5)
        ledger.expire(0)

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .expired)
        XCTAssertEqual(ledger.ends, 1, "the system's task is still ended")
        XCTAssertEqual(ledger.events.first?.fields, ["outcome": "expired", "heldMs": "29500"])

        hold.interruptionBegan()
        XCTAssertEqual(ledger.begins, 2, "the next interruption asks again")
    }

    func testALateExpiryOfAnEarlierHoldDoesNotEndTheCurrentOne() async {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.interruptionBegan()
        hold.interruptionEnded()
        hold.interruptionBegan()
        ledger.expire(0)

        XCTAssertTrue(hold.isHolding, "the first hold's expiry arrived after it was given back")
        XCTAssertEqual(hold.outcome, .held)
    }

    func testARefusalIsRecordedAndTheNextInterruptionTriesAgain() async throws {
        let ledger = InterruptionHoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })
        ledger.refuses = true

        hold.interruptionBegan()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .unavailable)
        XCTAssertEqual(ledger.events.first?.fields, ["outcome": "unavailable"])

        ledger.refuses = false
        hold.interruptionBegan()
        XCTAssertTrue(hold.isHolding)
    }
}

/// Counts the background time asked for and given back, standing in for UIApplication's background tasks.
@MainActor
private final class InterruptionHoldLedger {
    var begins = 0
    var ends = 0
    var refuses = false
    var names: [String] = []
    var events: [(kind: String, fields: [String: String])] = []
    private var expiries: [@MainActor () -> Void] = []

    func hold(now: @escaping () -> Date) -> InterruptionBackgroundHold {
        InterruptionBackgroundHold(
            begin: { [unowned self] name, expired in
                guard !self.refuses else { return nil }
                self.begins += 1
                self.names.append(name)
                self.expiries.append(expired)
                var ended = false
                return { [unowned self] in
                    guard !ended else { return }
                    ended = true
                    self.ends += 1
                }
            },
            record: { [unowned self] kind, fields in self.events.append((kind, fields)) },
            now: now
        )
    }

    /// The system takes background time back: it calls the expiry handler, which in the app then ends the task.
    func expire(_ index: Int) {
        guard expiries.indices.contains(index) else { return XCTFail("no hold \(index) to expire") }
        expiries[index]()
    }
}
