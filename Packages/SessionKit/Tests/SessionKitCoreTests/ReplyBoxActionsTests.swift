import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The sender's taps on an answer that came through a reply box (#4675, `docs/design/reply-mailbox.md` screens D and E),
/// the report sheet's rules, and the quiet import's decision (piece 7), on a stand-in transport and a real SQLite store.
final class ReplyBoxActionsTests: XCTestCase {
    /// The close, report and report-reason routes, answering what each test sets, and recording what was sent.
    final class Routes: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (status: Int, body: String)] = [:]
        private var offline: Set<String> = []
        private var sent: [ClubClient.Request] = []

        var requests: [ClubClient.Request] { lock.withLock { sent } }
        func answer(_ suffix: String, _ status: Int, _ body: String = "{}") { lock.withLock { answers[suffix] = (status, body) } }
        func goOffline(_ suffix: String) { lock.withLock { _ = offline.insert(suffix) } }

        var send: ClubClient.Send {
            { [self] request, _ in
                try lock.withLock {
                    sent.append(request)
                    let route = request.path.split(separator: "/").suffix(from: 4).joined(separator: "/")
                    if offline.contains(route) { throw URLError(.notConnectedToInternet) }
                    let answer = answers[route] ?? (500, #"{"error":"internal"}"#)
                    return (answer.status, Data(answer.body.utf8))
                }
            }
        }
    }

    private func date(_ days: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + days * 86_400) }

    private func makeStore(_ records: [ReplyBoxRecord]) throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appending(path: "reply-actions-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        for record in records { try store.saveReplyBox(record) }
        return store
    }

    private func record(item: String = "item-1", closed: Bool = false) -> ReplyBoxRecord {
        ReplyBoxRecord(
            box: .random(), linkId: "0123456789abcdef0123456789abcdef", itemId: item, sharedPackageDigest: "sha256:shared",
            createdAt: date(0), expiresAt: date(30), cursor: 2, closed: closed, closedAt: closed ? date(1) : nil,
            answers: [.init(seq: 2, layerId: "layer-answer")]
        )
    }

    private func actions(_ routes: Routes, _ store: SQLiteSessionStore) -> ReplyBoxActions {
        let fixed = date(5)
        return ReplyBoxActions(send: routes.send, store: { store }, host: "example.test", now: { fixed })
    }

    // MARK: Which layers carry card D

    func testOnlyALayerThatCameThroughABoxFindsItsBoxAndPost() {
        let box = record()
        XCTAssertEqual(ReplyBoxActions.answer(carrying: "layer-answer", in: [box])?.seq, 2)
        XCTAssertEqual(ReplyBoxActions.answer(carrying: "layer-answer", in: [box])?.record.boxId, box.boxId)
        XCTAssertNil(ReplyBoxActions.answer(carrying: "layer-from-a-file", in: [box]))
        XCTAssertNil(ReplyBoxActions.answer(carrying: "layer-answer", in: []))
    }

    // MARK: Stop answers

    func testStopClosesWithTheReadProofAndSavesTheRecordClosed() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.answer("close", 204)
        let result = await actions(routes, store).stop(boxId: box.boxId)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(routes.requests.map(\.path), ["/api/v1/clubs/\(box.boxId)/close"])
        XCTAssertEqual(routes.requests.first?.bearer, box.box?.credentials.readProof)
        let saved = try XCTUnwrap(try store.loadReplyBoxes().first)
        XCTAssertTrue(saved.closed)
        XCTAssertEqual(saved.closedAt, date(5))
    }

    func testABoxThatHasAlreadyEndedCountsAsStopped() async throws {
        for status in [404, 410] {
            let box = record()
            let store = try makeStore([box])
            let routes = Routes()
            routes.answer("close", status)
            let result = await actions(routes, store).stop(boxId: box.boxId)
            XCTAssertEqual(result, .stopped, "status \(status)")
            XCTAssertEqual(try store.loadReplyBoxes().first?.closed, true)
        }
    }

    func testAStopThatFailsSavesNothing() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.goOffline("close")
        let offline = await actions(routes, store).stop(boxId: box.boxId)
        XCTAssertEqual(offline, .failed)
        let busy = Routes()
        busy.answer("close", 503, #"{"error":"busy"}"#)
        let refused = await actions(busy, store).stop(boxId: box.boxId)
        XCTAssertEqual(refused, .failed)
        XCTAssertEqual(try store.loadReplyBoxes().first?.closed, false)
        let missing = await actions(routes, store).stop(boxId: "ffffffffffffffffffffffffffffffff")
        XCTAssertEqual(missing, .failed)
    }

    // MARK: Report this answer

    func testReportWithTheToggleFilesHidesAndCloses() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":false,"ref":"R-12"}"#)
        routes.answer("close", 204)
        let result = await actions(routes, store).report(
            boxId: box.boxId, seq: 2, category: .harassment, reason: " rude ", alsoStop: true)
        XCTAssertEqual(result, .filed(reference: "R-12", reasonOutstanding: false, closeFailed: false))
        XCTAssertTrue(result.hidesAnswer)
        XCTAssertEqual(routes.requests.map { String($0.path.split(separator: "/").last!) }, ["report", "close"])
        let form = String(decoding: try XCTUnwrap(routes.requests.first?.body), as: UTF8.self)
        XCTAssertEqual(form, "category=harassment&post=2&reason=rude")
        XCTAssertEqual(try store.loadReplyBoxes().first?.closed, true)
    }

    func testAFailingCloseStillReportsAndSaysSo() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":false,"ref":"R-7"}"#)
        routes.goOffline("close")
        let result = await actions(routes, store).report(boxId: box.boxId, seq: 2, category: .other, reason: nil, alsoStop: true)
        XCTAssertEqual(result, .filed(reference: "R-7", reasonOutstanding: false, closeFailed: true))
        XCTAssertTrue(result.hidesAnswer, "the report stands, so the answer is hidden")
        XCTAssertEqual(try store.loadReplyBoxes().first?.closed, false)
        var sheet = ReplyReportForm()
        sheet.category = .other
        _ = sheet.beginSending()
        XCTAssertEqual(sheet.finishReport(result)?.banner,
                       "Report sent. Reference R-7. Couldn't stop answers. Try again from the card.")
    }

    func testWithTheToggleOffNothingIsClosed() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":false,"ref":"R-1"}"#)
        let result = await actions(routes, store).report(boxId: box.boxId, seq: 2, category: .copyright, reason: nil, alsoStop: false)
        XCTAssertEqual(result, .filed(reference: "R-1", reasonOutstanding: false, closeFailed: false))
        XCTAssertEqual(routes.requests.count, 1)
        XCTAssertEqual(try store.loadReplyBoxes().first?.closed, false)
    }

    func testAnAbuseReportCarriesTheBoxLinkOnTheHost() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":false,"ref":"R-2"}"#)
        routes.answer("close", 200)
        _ = await actions(routes, store).report(boxId: box.boxId, seq: 2, category: .abuseMaterial, reason: nil, alsoStop: true)
        let form = String(decoding: try XCTUnwrap(routes.requests.first?.body), as: UTF8.self)
        XCTAssertTrue(form.contains("link=https%3A%2F%2Fexample.test%2Fc%2F\(box.boxId)%23"), form)
    }

    func testAnEndedBoxHidesOnlyAndAFailureKeepsEverything() async throws {
        let box = record()
        let store = try makeStore([box])
        let ended = Routes()
        ended.answer("report", 404, #"{"error":"not_found"}"#)
        let gone = await actions(ended, store).report(boxId: box.boxId, seq: 2, category: .other, reason: nil, alsoStop: true)
        XCTAssertEqual(gone, .boxEnded)
        XCTAssertTrue(gone.hidesAnswer)
        XCTAssertEqual(ended.requests.count, 1, "no close for an ended box")
        XCTAssertEqual(try store.loadReplyBoxes().first?.ended, true)

        let other = record()
        let otherStore = try makeStore([other])
        let offline = Routes()
        offline.goOffline("report")
        let failed = await actions(offline, otherStore).report(boxId: other.boxId, seq: 2, category: .other, reason: nil, alsoStop: true)
        XCTAssertEqual(failed, .failed)
        XCTAssertFalse(failed.hidesAnswer)
        XCTAssertEqual(try otherStore.loadReplyBoxes().first, other, "nothing saved")
    }

    func testAReasonOwedKeepsTheSheetOpenUntilTheReasonGoesIn() async throws {
        let box = record()
        let store = try makeStore([box])
        let routes = Routes()
        routes.answer("report", 200, #"{"filed":true,"reasonOutstanding":true,"ref":"R-9"}"#)
        routes.answer("close", 204)
        routes.answer("report/reason", 500)
        let actions = actions(routes, store)

        var sheet = ReplyReportForm()
        XCTAssertFalse(sheet.canSend, "no category yet")
        sheet.category = .harassment
        XCTAssertTrue(sheet.alsoStop, "on by default")
        XCTAssertEqual(sheet.beginSending(), .editing)
        XCTAssertFalse(sheet.canSend, "one send at a time")
        let result = await actions.report(boxId: box.boxId, seq: 2, category: .harassment, reason: nil, alsoStop: sheet.alsoStop)
        XCTAssertNil(sheet.finishReport(result), "stays open")
        XCTAssertEqual(sheet.footer, "Please say what happened, then send again.")
        XCTAssertFalse(sheet.canSend, "a reason is needed now")
        sheet.reason = "They keep sending this"
        XCTAssertEqual(sheet.beginSending(), .reasonOwed(reference: "R-9", closeFailed: false))
        let first = await actions.sendReason(boxId: box.boxId, reference: "R-9", reason: sheet.reason)
        XCTAssertFalse(first)
        XCTAssertNil(sheet.finishReason(succeeded: first, reference: "R-9", closeFailed: false))
        XCTAssertEqual(sheet.footer, ReplyArrivalWords.reportFailed)

        routes.answer("report/reason", 200, #"{"ok":true}"#)
        _ = sheet.beginSending()
        let second = await actions.sendReason(boxId: box.boxId, reference: "R-9", reason: sheet.reason)
        XCTAssertTrue(second)
        XCTAssertEqual(sheet.finishReason(succeeded: second, reference: "R-9", closeFailed: false),
                       .init(banner: "Report sent. Reference R-9.", hidesAnswer: true))
        let reasonForm = String(decoding: try XCTUnwrap(routes.requests.last?.body), as: UTF8.self)
        XCTAssertEqual(reasonForm, "ref=R-9&reason=They%20keep%20sending%20this")
    }

    func testTheSheetFailureFooterAndCancelRules() {
        var sheet = ReplyReportForm()
        sheet.category = .other
        XCTAssertNil(sheet.cancelled(), "nothing filed: Cancel just closes")
        _ = sheet.beginSending()
        XCTAssertNil(sheet.finishReport(.failed))
        XCTAssertEqual(sheet.footer, "Couldn't send the report. Check your connection and try again.")
        XCTAssertTrue(sheet.canSend, "the listener can try again")
        _ = sheet.beginSending()
        XCTAssertNil(sheet.footer, "a new send clears the failure")
        XCTAssertNil(sheet.finishReport(.filed(reference: "R-3", reasonOutstanding: true, closeFailed: true)))
        XCTAssertEqual(sheet.cancelled(), .init(
            banner: "Report sent. Reference R-3. Couldn't stop answers. Try again from the card.", hidesAnswer: true),
            "a filed report stands when the reason is not given")
        var ended = ReplyReportForm()
        ended.category = .other
        _ = ended.beginSending()
        XCTAssertEqual(ended.finishReport(.boxEnded), .init(banner: ReplyArrivalWords.reportBoxEnded, hidesAnswer: true))
    }

    // MARK: Quiet import decision

    func testTheQuietImportKeepsOnlyAnswersToTheSharedItem() {
        let box = record()
        func decide(
            earlier: ReplyBoxQuietImport.EarlierImport? = nil, matching: String? = "item-1", map: Bool = false,
            needsItem: Bool = false, parents: [String] = []
        ) -> ReplyBoxQuietImport.Decision {
            ReplyBoxQuietImport.decide(
                record: box, earlier: earlier, matchingItemId: matching, isListeningMap: map,
                requiresRecipientItem: needsItem, parentPackageDigests: parents)
        }
        XCTAssertEqual(decide(), .importOnto(itemId: "item-1"))
        XCTAssertEqual(decide(parents: ["sha256:shared", "sha256:shared"]), .importOnto(itemId: "item-1"))
        XCTAssertEqual(decide(matching: "item-2"), .drop(.otherItem), "another item's packet is dropped")
        XCTAssertEqual(decide(matching: nil, needsItem: true), .drop(.itemMissing))
        XCTAssertEqual(decide(parents: ["sha256:shared", "sha256:other"]), .drop(.otherParent))
        XCTAssertEqual(decide(map: true), .drop(.needsReview), "a Listening Map would need the review sheet")
        XCTAssertEqual(decide(earlier: .init(layerId: "layer-old", itemId: "item-1")), .alreadyIn(layerId: "layer-old"))
        XCTAssertEqual(decide(earlier: .init(layerId: "layer-old", itemId: "item-2")), .drop(.otherItem))
    }
}
