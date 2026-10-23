import Foundation
import XCTest
@testable import SessionKit

/// #2487 slice 1b, #2531: the Watch's side of the contract, pure. The Watch keeps a recording until the phone says
/// "filed" for its exact id and bytes; answers may be lost, repeated or out of order; the Watch always knows the
/// session; and its clock is measured, not trusted.
final class WatchContractTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func transfer(_ id: String, at offset: TimeInterval = 0, sha: String = "abc123", session: String? = nil) -> WatchMarginTransfer {
        WatchMarginTransfer(id: id, wallStart: t0.addingTimeInterval(offset), durationMs: 3_000, sessionId: session, sha256: sha)
    }

    private func answer(_ id: String, _ outcome: WatchMarginAnswer.Outcome, status: WatchMarginReceipt.Status = .stored, sha: String = "abc123", filedIn: String? = "Budget meeting", positionMs: Int? = 70_000, reason: String? = nil) -> WatchMarginAnswer {
        WatchMarginAnswer(
            receipt: WatchMarginReceipt(captureId: id, sha256: sha, status: status), outcome: outcome,
            sessionId: "live-1", filedIn: filedIn, positionMs: positionMs, reason: reason
        )
    }

    private func ledgerWithOneSent(_ id: String = "m1") -> WatchMarginLedger {
        var ledger = WatchMarginLedger()
        ledger.record(transfer(id), fileName: "\(id).m4a", now: t0)
        _ = ledger.markSent(id, now: t0)
        return ledger
    }

    // MARK: #2531: keep the audio until the phone says filed

    func testTheRecordingIsKeptWhenTheTransferFinishesWithNoAnswer() {
        // The first build deleted its copy as soon as WatchConnectivity finished the transfer. Finishing the transfer
        // isn't an answer: nothing is deleted, and the Margin is still held.
        let ledger = ledgerWithOneSent()
        XCTAssertEqual(ledger.holdingIds, ["m1"])
        XCTAssertEqual(ledger.display("m1", now: t0.addingTimeInterval(1)), .savedOnWatch)
        XCTAssertEqual(ledger.display("m1", now: t0.addingTimeInterval(16)), .waitingForIPhone, "no answer within 15 seconds")
    }

    func testOnlyFiledForThatExactIdAndBytesLetsTheWatchDeleteIt() {
        var ledger = ledgerWithOneSent()
        ledger.record(transfer("m2"), fileName: "m2.m4a", now: t0)
        XCTAssertEqual(ledger.apply(answer("m2", .filed), now: t0), .filed(fileName: "m2.m4a"))
        XCTAssertEqual(ledger.holdingIds, ["m1"], "the other Margin's answer never releases this one")
        XCTAssertEqual(ledger.apply(answer("m1", .filed, sha: "different"), now: t0), .rejected, "the phone holds other bytes")
        XCTAssertEqual(ledger.holdingIds, ["m1"])
    }

    func testFiledWordsComeOnlyFromThePhonesAnswer() {
        var ledger = ledgerWithOneSent()
        XCTAssertNil(ledger.display("m1", now: t0).flatMap { if case .filed = $0 { $0 } else { nil } })
        _ = ledger.apply(answer("m1", .filed), now: t0)
        XCTAssertEqual(ledger.display("m1", now: t0)?.words, "Filed in Budget meeting, about 1:10")
        var quick = ledgerWithOneSent("q")
        _ = quick.apply(answer("q", .filed, filedIn: "a quick session", positionMs: 0), now: t0)
        XCTAssertEqual(quick.display("q", now: t0)?.words, "Filed in a quick session")
    }

    // MARK: Lost, repeated and out-of-order answers

    func testALostAnswerIsSentAgainAfterTenMinutesOnceWatchConnectivityLetsGo() {
        var ledger = ledgerWithOneSent()
        XCTAssertEqual(ledger.due(now: t0.addingTimeInterval(599), inFlight: []), [], "not yet")
        XCTAssertEqual(ledger.due(now: t0.addingTimeInterval(600), inFlight: ["m1"]), [], "still in WatchConnectivity's queue")
        XCTAssertEqual(ledger.due(now: t0.addingTimeInterval(600), inFlight: []), ["m1"])
        XCTAssertEqual(ledger.markSent("m1", now: t0.addingTimeInterval(600))?.attempt, 2)
    }

    func testAFailedTransferIsSentAgainAtOnce() {
        var ledger = ledgerWithOneSent()
        ledger.transferFailed("m1", error: "not reachable")
        XCTAssertEqual(ledger.due(now: t0.addingTimeInterval(1), inFlight: []), ["m1"])
        XCTAssertEqual(ledger.holdingIds, ["m1"], "kept")
    }

    func testAHelloThatDoesntAnswerAMarginMakesItDueAtOnce() {
        var ledger = ledgerWithOneSent()
        ledger.record(transfer("m2"), fileName: "m2.m4a", now: t0)
        _ = ledger.markSent("m2", now: t0)
        ledger.unansweredAfterHello(answered: ["m2"], inFlight: [])
        XCTAssertEqual(ledger.due(now: t0.addingTimeInterval(5), inFlight: []), ["m1"])
    }

    func testADuplicateAnswerChangesNothingAndDeletesNothingTwice() {
        var ledger = ledgerWithOneSent()
        XCTAssertEqual(ledger.apply(answer("m1", .filed), now: t0), .filed(fileName: "m1.m4a"))
        XCTAssertEqual(ledger.apply(answer("m1", .filed), now: t0), .ignored)
        XCTAssertEqual(ledger.apply(answer("m1", .alreadyFiled, status: .duplicate), now: t0), .ignored)
        XCTAssertEqual(ledger.filed.count, 1)
    }

    func testARejectionArrivingAfterFiledNeverUndoesIt() {
        // Attempt 1 arrived damaged, attempt 2 was filed, and their answers came back in the other order.
        var ledger = ledgerWithOneSent()
        _ = ledger.apply(answer("m1", .filed), now: t0)
        XCTAssertEqual(ledger.apply(answer("m1", .rejected, status: .checksumMismatch), now: t0), .ignored)
        XCTAssertEqual(ledger.display("m1", now: t0)?.words, "Filed in Budget meeting, about 1:10")
    }

    func testFiledArrivingAfterARejectionWins() {
        var ledger = ledgerWithOneSent()
        XCTAssertEqual(ledger.apply(answer("m1", .rejected, status: .incomplete), now: t0), .willResend)
        XCTAssertEqual(ledger.due(now: t0, inFlight: []), ["m1"], "a damaged transfer is sent again on its own")
        XCTAssertEqual(ledger.apply(answer("m1", .filed), now: t0), .filed(fileName: "m1.m4a"))
        XCTAssertTrue(ledger.holdingIds.isEmpty)
    }

    func testARefusalWaitsWithRetryAndDelete() {
        var ledger = ledgerWithOneSent()
        let refused = answer("m1", .rejected, status: .duplicate, reason: "You deleted this Margin on your iPhone.")
        XCTAssertEqual(ledger.apply(refused, now: t0), .rejected)
        XCTAssertEqual(ledger.display("m1", now: t0), .couldNotFile("You deleted this Margin on your iPhone."))
        XCTAssertEqual(ledger.due(now: t0.addingTimeInterval(3_600), inFlight: []), [], "never retried on its own")
        XCTAssertEqual(ledger.holdingIds, ["m1"], "never deleted on its own")
        ledger.retry("m1")
        XCTAssertEqual(ledger.due(now: t0, inFlight: []), ["m1"])
        XCTAssertEqual(ledger.delete("m1"), "m1.m4a")
        XCTAssertTrue(ledger.holdingIds.isEmpty)
    }

    func testAnAnswerAfterTheListenerDeletedTheMarginHereChangesNothing() {
        var ledger = ledgerWithOneSent()
        XCTAssertEqual(ledger.delete("m1"), "m1.m4a")
        XCTAssertEqual(ledger.apply(answer("m1", .filed), now: t0), .ignored, "no file to delete twice")
        XCTAssertTrue(ledger.filed.isEmpty)
        ledger.record(transfer("m1"), fileName: "m1.m4a", now: t0)
        XCTAssertTrue(ledger.holdingIds.isEmpty, "a deleted id never comes back")
    }

    func testAnAnswerForAMarginThisWatchNeverRecordedIsIgnored() {
        var ledger = WatchMarginLedger()
        XCTAssertEqual(ledger.apply(answer("stranger", .filed), now: t0), .ignored)
    }

    func testTheLedgerSurvivesARestart() throws {
        var ledger = ledgerWithOneSent()
        _ = ledger.apply(answer("m1", .rejected, status: .duplicate, reason: "no"), now: t0)
        ledger.record(transfer("m2"), fileName: "m2.m4a", now: t0)
        let data = try WatchContractCoding.encoder.encode(ledger)
        XCTAssertEqual(try WatchContractCoding.decoder.decode(WatchMarginLedger.self, from: data), ledger)
    }

    // MARK: The clock

    func testTheOffsetIsTheWatchMidpointMinusThePhoneTime() throws {
        // The Watch runs two minutes ahead; the round trip took two seconds.
        let sent = t0.addingTimeInterval(120)
        let stamp = try XCTUnwrap(WatchClockStamp.measure(sentAt: sent, phoneTime: t0.addingTimeInterval(1), receivedAt: sent.addingTimeInterval(2)))
        XCTAssertEqual(stamp.offset, 120, accuracy: 0.001)
        XCTAssertNil(WatchClockStamp.measure(sentAt: sent, phoneTime: t0, receivedAt: sent.addingTimeInterval(11)), "too slow to trust")
        XCTAssertNil(WatchClockStamp.measure(sentAt: sent, phoneTime: t0, receivedAt: sent.addingTimeInterval(-1)))
    }

    func testTheTransferCarriesItsRawTimeAndTheOffsetThroughTheMetadata() throws {
        var sent = transfer("m1", at: 120, session: "live-w")
        sent.clock = WatchClockStamp(offset: 120, measuredAt: t0.addingTimeInterval(100))
        sent.attempt = 3
        let read = try XCTUnwrap(WatchMarginTransfer(metadata: sent.metadata))
        XCTAssertEqual(read, sent)
        XCTAssertTrue(PropertyListSerialization.propertyList(sent.metadata, isValidFor: .binary), "WatchConnectivity takes it")
        // The build before slice 1b sent only four keys.
        let old = try XCTUnwrap(WatchMarginTransfer(metadata: ["kind": "watchMargin", "id": "x", "wallStart": 1_800_000_000.0, "duration": 1.5]))
        XCTAssertNil(old.sessionId)
        XCTAssertNil(old.clock)
        XCTAssertEqual(old.attempt, 1)
    }

    func testEnvelopesAndRepliesRoundTripAsPropertyLists() throws {
        let envelope = WatchEnvelope(seq: 7, sentAt: t0, clock: WatchClockStamp(offset: -0.4, measuredAt: t0), message: .sessionStart(
            WatchSessionInfo(id: "live-w", kind: .paper, title: "Paper book", owner: .watch, startedAt: t0)
        ))
        XCTAssertTrue(PropertyListSerialization.propertyList(envelope.dictionary, isValidFor: .binary))
        XCTAssertEqual(WatchEnvelope(dictionary: envelope.dictionary), envelope)
        for message: WatchMessage in [.hello(holding: ["a", "b"]), .sessionEnd(id: "s", endedAt: t0), .sessionResume(id: "s"), .withdraw(id: "a"), .marginDetails(transfer("m"))] {
            let wrapped = WatchEnvelope(seq: 1, sentAt: t0, clock: nil, message: message)
            XCTAssertEqual(WatchEnvelope(dictionary: wrapped.dictionary)?.message, message)
        }
        let reply = WatchPhoneReply(phoneTime: t0, board: WatchBoard(endNotes: ["a": "b"], phoneTime: t0), answers: [answer("m1", .filed)])
        XCTAssertEqual(WatchPhoneReply(dictionary: reply.dictionary), reply)
        XCTAssertNil(WatchEnvelope(dictionary: ["something": "else"]))
    }

    // MARK: The three states

    private func board(running: WatchSessionInfo? = nil, ended: WatchSessionInfo? = nil, notes: [String: String] = [:], at offset: TimeInterval = 0) -> WatchBoard {
        WatchBoard(running: running, recentlyEnded: ended, endNotes: notes, phoneTime: t0.addingTimeInterval(offset))
    }

    private func phoneMeeting(at offset: TimeInterval = 0) -> WatchSessionInfo {
        WatchSessionInfo(id: "live-p", kind: .meeting, title: "Budget meeting", owner: .phone, startedAt: t0.addingTimeInterval(offset), startPositionMs: 0)
    }

    func testHomeSaysWhichOfTheThreeStatesItIsIn() {
        var model = WatchSessionModel()
        XCTAssertEqual(model.home(now: t0, phoneReachable: true).line(now: t0), "No session")
        XCTAssertEqual(model.home(now: t0, phoneReachable: true).symbol, "circle")
        model.apply(board(running: phoneMeeting()), receivedAt: t0)
        let onPhone = model.home(now: t0.addingTimeInterval(760), phoneReachable: true)
        XCTAssertEqual(onPhone.line(now: t0.addingTimeInterval(760)), "Budget meeting · on iPhone · about 12:40")
        XCTAssertEqual(onPhone.symbol, "iphone")
        var mine = WatchSessionModel()
        _ = mine.start(kind: .other, id: "live-w", now: t0)
        let onWatch = mine.home(now: t0, phoneReachable: false)
        XCTAssertEqual(onWatch.place, .onWatch)
        XCTAssertEqual(onWatch.symbol, "applewatch")
        XCTAssertTrue(onWatch.line(now: t0).hasPrefix("Other · on Watch · "))
        XCTAssertEqual(mine.sessionIdForMargin(now: t0), "live-w")
        XCTAssertNil(WatchSessionModel().sessionIdForMargin(now: t0), "no session: the phone files it by time")
    }

    func testAnOldBoardWithThePhoneOutOfReachSaysAsOf() {
        var model = WatchSessionModel()
        model.apply(board(running: phoneMeeting()), receivedAt: t0)
        XCTAssertNil(model.home(now: t0.addingTimeInterval(120), phoneReachable: true).asOf)
        XCTAssertNil(model.home(now: t0.addingTimeInterval(59), phoneReachable: false).asOf)
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(61), phoneReachable: false).asOf, t0)
        XCTAssertTrue(model.home(now: t0.addingTimeInterval(61), phoneReachable: false).line(now: t0).contains("as of "))
    }

    func testASessionNobodyEndedStopsShowingAfterEightHours() {
        var model = WatchSessionModel()
        model.apply(board(running: phoneMeeting()), receivedAt: t0)
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(8 * 3_600 - 1), phoneReachable: false).place, .onPhone)
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(8 * 3_600), phoneReachable: false).place, .none)
    }

    func testAWatchSessionStaysOnWatchUntilThePhoneShowsIt() {
        var model = WatchSessionModel()
        let started = model.start(kind: .meeting, id: "live-w", now: t0.addingTimeInterval(10))
        XCTAssertEqual(started.owner, .watch)
        XCTAssertEqual(started.title, "Meeting")
        model.apply(board(at: 5), receivedAt: t0.addingTimeInterval(11)) // a board from before the phone heard of it
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(12), phoneReachable: true).place, .onWatch)
        var echoed = started
        echoed.owner = .watch
        model.apply(board(running: echoed, at: 12), receivedAt: t0.addingTimeInterval(13))
        XCTAssertNil(model.local)
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(14), phoneReachable: true).place, .onWatch, "owned by the Watch")
    }

    func testThePhoneEndingASessionTheWatchStartedIsShownInWords() {
        var model = WatchSessionModel()
        _ = model.start(kind: .other, id: "live-w", now: t0)
        let note = "Other ended at 10:20, when you started Budget meeting on iPhone"
        model.apply(board(running: phoneMeeting(at: 60), notes: ["live-w": note], at: 61), receivedAt: t0.addingTimeInterval(62))
        let home = model.home(now: t0.addingTimeInterval(63), phoneReachable: true)
        XCTAssertEqual(home.session?.id, "live-p")
        XCTAssertEqual(model.endNote, note)
        XCTAssertNil(model.local)
    }

    func testALaterPhoneStartEndsTheWatchSessionEvenBeforeThePhoneSaysSo() {
        var model = WatchSessionModel()
        _ = model.start(kind: .other, id: "live-w", now: t0)
        model.apply(board(running: phoneMeeting(at: 30), at: 31), receivedAt: t0.addingTimeInterval(32))
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(33), phoneReachable: true).session?.id, "live-p")
        XCTAssertTrue(model.endNote?.contains("when you started Budget meeting on iPhone") == true)
    }

    func testAnEarlierPhoneSessionDoesNotEndALaterWatchStart() {
        var model = WatchSessionModel()
        _ = model.start(kind: .other, id: "live-w", now: t0.addingTimeInterval(100))
        model.apply(board(running: phoneMeeting(at: 0), at: 101), receivedAt: t0.addingTimeInterval(102))
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(103), phoneReachable: true).session?.id, "live-w", "the later start wins")
    }

    func testEndThenResumeWithinTenMinutes() throws {
        var model = WatchSessionModel()
        model.apply(board(running: phoneMeeting()), receivedAt: t0)
        let ended = try XCTUnwrap(model.end(now: t0.addingTimeInterval(300)))
        XCTAssertEqual(ended.id, "live-p")
        // The old board still says running; the End made here wins until the phone catches up.
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(301), phoneReachable: true).place, .none)
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(301), phoneReachable: true).resumable?.id, "live-p")
        XCTAssertNil(model.home(now: t0.addingTimeInterval(300 + 601), phoneReachable: true).resumable, "ten minutes only")
        XCTAssertEqual(model.resume(now: t0.addingTimeInterval(400)), "live-p")
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(401), phoneReachable: true).place, .onPhone)
    }

    func testResumeOffersAnEndThePhoneMade() {
        var model = WatchSessionModel()
        var ended = phoneMeeting()
        ended.endedAt = t0.addingTimeInterval(100)
        model.apply(board(ended: ended, at: 101), receivedAt: t0.addingTimeInterval(102))
        XCTAssertEqual(model.home(now: t0.addingTimeInterval(200), phoneReachable: true).resumable?.id, "live-p")
    }

    func testAClockSkewOfTwoMinutesDoesNotMisplaceThePhonesTimes() {
        // The Watch runs 120 s ahead. The phone's session started at t0 by its clock, which is t0+120 on the Watch.
        var model = WatchSessionModel()
        model.clock = WatchClockStamp(offset: 120, measuredAt: t0)
        var ended = phoneMeeting()
        ended.endedAt = t0
        model.apply(board(ended: ended), receivedAt: t0.addingTimeInterval(120))
        XCTAssertNotNil(model.resumable(now: t0.addingTimeInterval(120 + 599)), "ten minutes by the phone's clock")
        XCTAssertNil(model.resumable(now: t0.addingTimeInterval(120 + 601)))
    }

    func testTheModelSurvivesARestart() throws {
        var model = WatchSessionModel()
        _ = model.start(kind: .audiobook, id: "live-w", now: t0)
        model.apply(board(running: phoneMeeting(at: -10)), receivedAt: t0)
        let data = try WatchContractCoding.encoder.encode(model)
        XCTAssertEqual(try WatchContractCoding.decoder.decode(WatchSessionModel.self, from: data), model)
    }
}
