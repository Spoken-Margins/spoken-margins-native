import Foundation
import XCTest
@testable import SessionKit

/// #540, #538: the app could be suspended in the moment between one narration chunk ending and the next one
/// playing, so a ready item sat at time 0 until the owner came back. The hold asks iOS for background time over
/// that moment. They are async only because Linux XCTest can't run a synchronous main-actor test.
@MainActor
final class HandOverBackgroundHoldTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 5_400)

    func testTheEndOfAChunkHoldsBackgroundTimeUntilTheNextOneMoves() async {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.chunkEnded()

        XCTAssertEqual(ledger.begins, 1)
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.outcome, .held)
        XCTAssertEqual(ledger.names, ["Narration chunk hand-over"])

        hold.nextChunkMoving()

        XCTAssertEqual(ledger.ends, 1)
        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .released)
    }

    func testAnotherChunkEndWhileHoldingAsksForNothingMore() async {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.chunkEnded()
        hold.chunkEnded()
        hold.nextChunkMoving()
        hold.nextChunkMoving()

        XCTAssertEqual(ledger.begins, 1, "one hold covers one gap")
        XCTAssertEqual(ledger.ends, 1, "and is given back once")
    }

    func testEachSeamGetsItsOwnHold() async {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        for _ in 0..<3 {
            hold.chunkEnded()
            hold.nextChunkMoving()
        }

        XCTAssertEqual(ledger.begins, 3)
        XCTAssertEqual(ledger.ends, 3)
        XCTAssertEqual(hold.grantedCount, 3)
    }

    func testMovingWithNothingHeldDoesNothing() async {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.nextChunkMoving()

        XCTAssertEqual(ledger.begins, 0)
        XCTAssertEqual(ledger.ends, 0)
        XCTAssertNil(hold.outcome)
        XCTAssertTrue(ledger.events.isEmpty)
    }

    func testAShortHandOverLeavesNoEvent() async {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.chunkEnded()
        now = now.addingTimeInterval(0.4)
        hold.nextChunkMoving()

        XCTAssertTrue(ledger.events.isEmpty, "a normal seam is not worth a log line: \(ledger.events)")
    }

    func testALongHandOverIsRecordedWithHowLongItWasHeld() async throws {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.chunkEnded()
        now = now.addingTimeInterval(7.25)
        hold.nextChunkMoving()

        let event = try XCTUnwrap(ledger.events.first)
        XCTAssertEqual(event.kind, "handover.hold_released")
        XCTAssertEqual(event.fields["heldMs"], "7250")
    }

    func testTheSystemTakingTheTimeBackIsRecordedAndEndsTheHold() async throws {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.chunkEnded()
        now = now.addingTimeInterval(29.5)
        ledger.expire(0)

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .expired)
        XCTAssertEqual(ledger.ends, 1, "the system's task is still ended")
        let event = try XCTUnwrap(ledger.events.first)
        XCTAssertEqual(event.kind, "handover.hold_expired")
        XCTAssertEqual(event.fields["heldMs"], "29500")

        hold.chunkEnded()
        XCTAssertEqual(ledger.begins, 2, "the next seam asks again")
    }

    func testALateExpiryOfAnEarlierHoldDoesNotEndTheCurrentOne() async {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })

        hold.chunkEnded()
        hold.nextChunkMoving()
        hold.chunkEnded()
        ledger.expire(0)

        XCTAssertTrue(hold.isHolding, "the first hold's expiry arrived after it was given back")
        XCTAssertEqual(hold.outcome, .held)
    }

    func testARefusalIsRecordedAndTheNextSeamTriesAgain() async throws {
        let ledger = HoldLedger()
        let hold = ledger.hold(now: { [unowned self] in self.now })
        ledger.refuses = true

        hold.chunkEnded()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(hold.outcome, .unavailable)
        XCTAssertEqual(ledger.events.first?.kind, "handover.hold_unavailable")

        ledger.refuses = false
        hold.chunkEnded()
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.grantedCount, 1)
    }
}

/// Counts the background time asked for and given back, standing in for UIApplication's background tasks.
@MainActor
private final class HoldLedger {
    var begins = 0
    var ends = 0
    var refuses = false
    var names: [String] = []
    var events: [(kind: String, fields: [String: String])] = []
    private var expiries: [@MainActor () -> Void] = []

    func hold(now: @escaping () -> Date) -> HandOverBackgroundHold {
        HandOverBackgroundHold(
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
