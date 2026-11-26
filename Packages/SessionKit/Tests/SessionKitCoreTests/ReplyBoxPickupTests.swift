#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// The quiet pickup of answers from the sender's reply boxes (#4675, `docs/design/reply-mailbox.md` piece 4 and its
/// "Device conditions" rows `network`, `relaunch`, `background`, `burst` and `store`), on a stand-in for the club routes
/// and a real SQLite store.
final class ReplyBoxPickupTests: XCTestCase {
    // MARK: Stand-ins

    /// The club list and fetch routes for reply boxes, in memory: read proof checked by its SHA-256, a wrong one and an
    /// unknown box answered alike, `410` for an ended box.
    final class BoxServer: @unchecked Sendable {
        enum Fault { case offline, status(Int, String) }
        private let lock = NSLock()
        private var boxes: [String: (readHash: String, posts: [Data], ended: Bool)] = [:]
        private var faults: [(suffix: String, fault: Fault, times: Int)] = []
        private var _requests: [ClubClient.Request] = []

        var requests: [ClubClient.Request] { lock.withLock { _requests } }
        var client: ClubClient { ClubClient(send: { [self] request, _ in try handle(request) }) }

        func make(_ box: ReplyBox) { lock.withLock { boxes[box.id] = (box.credentials.readHash, [], false) } }
        func post(_ packet: Data, to box: ReplyBox) {
            let sealed = try! box.sealAnswer(packet)
            lock.withLock { boxes[box.id]!.posts.append(sealed) }
        }
        func postRaw(_ bytes: Data, to box: ReplyBox) { lock.withLock { boxes[box.id]!.posts.append(bytes) } }
        func end(_ box: ReplyBox) { lock.withLock { boxes[box.id]!.ended = true } }
        /// The next `times` requests whose path ends with `suffix` fail this way.
        func fail(_ suffix: String, _ fault: Fault, times: Int = 1) { lock.withLock { faults.append((suffix, fault, times)) } }

        private func handle(_ request: ClubClient.Request) throws -> (status: Int, body: Data) {
            try lock.withLock {
                _requests.append(request)
                if let index = faults.firstIndex(where: { request.path.hasSuffix($0.suffix) && $0.times > 0 }) {
                    faults[index].times -= 1
                    switch faults[index].fault {
                    case .offline: throw URLError(.notConnectedToInternet)
                    case .status(let status, let code): return (status, Data(#"{"error":"\#(code)"}"#.utf8))
                    }
                }
                let parts = request.path.split(separator: "?").map(String.init)
                let segments = parts[0].split(separator: "/").map(String.init)
                guard segments.count >= 5, request.method == "GET", let box = boxes[segments[3]],
                      let bearer = request.bearer, let raw = Data(hexString: bearer),
                      ClubSealing.Credentials.hex(Data(SHA256.hash(data: raw))) == box.readHash else {
                    return (404, Data(#"{"error":"not_found"}"#.utf8))
                }
                if box.ended { return (410, Data(#"{"error":"expired_or_removed"}"#.utf8)) }
                if segments.count == 5 {
                    let after = Int(parts.last!.replacingOccurrences(of: "after=", with: "")) ?? 0
                    let entries = box.posts.indices.map { $0 + 1 }.filter { $0 > after }.map { #"{"seq":\#($0)}"# }
                    return (200, Data(#"{"posts":[\#(entries.joined(separator: ","))]}"#.utf8))
                }
                guard let number = Int(segments[5]), number >= 1, number <= box.posts.count else {
                    return (404, Data(#"{"error":"not_found"}"#.utf8))
                }
                return (200, box.posts[number - 1])
            }
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        func add(_ line: String) { lock.withLock { stored.append(line) } }
    }

    /// A packet the stand-in importer reads: where it lands, the parents it names, the typed name.
    struct TestPacket: Codable {
        var item: String
        var parents: [String] = []
        var sender: String?
        var needsReview = false
        var nonce = UUID().uuidString

        var data: Data { try! JSONEncoder().encode(self) }
    }

    /// The app's importer, in miniature: idempotent by digest (#468), placement from the packet, the admission rule
    /// from SessionKit. `gate` holds an import until the test releases it.
    actor Importer: ReplyBoxImporting {
        private(set) var library: [String: String] = [:]     // digest -> layer id
        private(set) var calls = 0
        var titles: [String: String] = ["item-1": "The Harbour", "item-2": "Second Item"]
        var answerNotNow = 0
        var gate: CheckedContinuation<Void, Never>?
        var holdNext = false
        private var entered: CheckedContinuation<Void, Never>?
        private var hasEntered = false

        func setNotNow(_ times: Int) { answerNotNow = times }
        func holdTheNextImport() { holdNext = true }
        func release() { gate?.resume(); gate = nil }
        func waitUntilHeld() async {
            if hasEntered { return }
            await withCheckedContinuation { entered = $0 }
        }

        func importAnswer(_ answer: ReplyBoxAnswer) async -> ReplyBoxImportOutcome {
            calls += 1
            if holdNext {
                holdNext = false
                hasEntered = true
                entered?.resume()
                entered = nil
                await withCheckedContinuation { gate = $0 }
            }
            if answerNotNow > 0 { answerNotNow -= 1; return .notNow }
            guard let packet = try? JSONDecoder().decode(TestPacket.self, from: answer.packet) else { return .dropped(.unreadable) }
            let placed = titles[packet.item] == nil ? nil : packet.item
            if let reason = ReplyBoxAdmission.check(
                record: answer.record, placedItemId: placed, parentPackageDigests: packet.parents,
                route: packet.needsReview ? .review : .openItem
            ) { return .dropped(reason) }
            let digest = ClubSealing.Credentials.hex(Data(SHA256.hash(data: answer.packet)))
            let fresh = library[digest] == nil
            let layer = library[digest] ?? "layer-\(library.count + 1)"
            library[digest] = layer
            return .imported(ReplyBoxImported(
                layerId: layer, senderLabel: packet.sender, itemTitle: titles[packet.item]!, newMarginCount: fresh ? 1 : 0
            ))
        }

        func removeLayer(_ id: String) { library = library.filter { $0.value != id } }
        func layerIsInLibrary(id: String) async -> Bool { library.values.contains(id) }
    }

    /// A store that fails the next cursor save, as a killed app never makes it.
    final class FailingSaves: ReplyBoxStoring, @unchecked Sendable {
        let inner: SQLiteSessionStore
        private let lock = NSLock()
        private var failures: Int
        init(_ inner: SQLiteSessionStore, failures: Int) { self.inner = inner; self.failures = failures }
        func loadReplyBoxes() throws -> [ReplyBoxRecord] { try inner.loadReplyBoxes() }
        func saveReplyBox(_ record: ReplyBoxRecord) throws { try inner.saveReplyBox(record) }
        func deleteReplyBox(id: String) throws { try inner.deleteReplyBox(id: id) }
        func updateReplyBox(id: String, _ change: (inout ReplyBoxRecord) throws -> Void) throws -> ReplyBoxRecord? {
            let fail = lock.withLock { () -> Bool in
                guard failures > 0 else { return false }
                failures -= 1
                return true
            }
            if fail { throw NSError(domain: "killed", code: 9) }
            return try inner.updateReplyBox(id: id, change)
        }
    }

    // MARK: Fixtures

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var path = ""

    override func setUp() {
        super.setUp()
        path = FileManager.default.temporaryDirectory.appending(path: "reply-pickup-\(UUID().uuidString).sqlite").path
    }

    private func record(_ box: ReplyBox, item: String = "item-1", daysAgo: Double = 1, lastChecked: Date? = nil) -> ReplyBoxRecord {
        ReplyBoxRecord(
            box: box, linkId: String(repeating: "a", count: 32), itemId: item, sharedPackageDigest: "sha256:shared",
            createdAt: start.addingTimeInterval(-daysAgo * 86_400),
            expiresAt: start.addingTimeInterval((30 - daysAgo) * 86_400), lastChecked: lastChecked
        )
    }

    private func setUpBox(
        server: BoxServer, store: SQLiteSessionStore, item: String = "item-1", lastChecked: Date? = nil
    ) throws -> ReplyBox {
        let box = ReplyBox.random()
        server.make(box)
        try store.saveReplyBox(record(box, item: item, lastChecked: lastChecked))
        return box
    }

    private func pickup(
        _ server: BoxServer, _ store: any ReplyBoxStoring, _ importer: Importer, clock: Clock, lines: Lines = Lines()
    ) -> ReplyBoxPickup {
        ReplyBoxPickup(client: server.client, store: { store }, importer: importer, now: { clock.now }, diagnostics: { lines.add($0) })
    }

    // MARK: Collecting

    func testEachAnswerIsImportedOnceAndTheCursorIsSavedAfterIt() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1", parents: ["sha256:shared"], sender: "Dana").data, to: box)
        server.post(TestPacket(item: "item-1", sender: "Dana").data, to: box)

        let result = await pickup(server, store, importer, clock: clock).check()

        XCTAssertEqual(result.status, .checked)
        XCTAssertEqual(result.arrivals.map(\.seq), [1, 2])
        XCTAssertEqual(result.arrivals.first?.itemTitle, "The Harbour")
        XCTAssertEqual(result.banner?.text, "Dana answered you on The Harbour")
        XCTAssertEqual(result.banner?.destination, .item(id: "item-1"))
        let saved = try XCTUnwrap(try store.loadReplyBox(id: box.id))
        XCTAssertEqual(saved.cursor, 2)
        XCTAssertEqual(saved.answers, [.init(seq: 1, layerId: "layer-1"), .init(seq: 2, layerId: "layer-2")])
        XCTAssertEqual(saved.lastChecked, start)
        // Reads carry only the read proof; nothing is posted.
        XCTAssertTrue(server.requests.allSatisfy { $0.method == "GET" && $0.bearer == box.credentials.readProof && $0.body == nil })
        XCTAssertEqual(server.requests.map(\.path), [
            "/api/v1/clubs/\(box.id)/posts?after=0", "/api/v1/clubs/\(box.id)/posts/1", "/api/v1/clubs/\(box.id)/posts/2",
        ], "the list, then one post at a time")
    }

    func testNoBoxesMeansNoRequestAndNoBanner() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path)
        let result = await pickup(server, store, Importer(), clock: Clock(start)).check()
        XCTAssertEqual(result.status, .checked)
        XCTAssertNil(result.banner)
        XCTAssertEqual(server.requests, [])
    }

    func testAnswersForAnotherItemOrParentOrNeedingReviewAreDroppedAndTheCursorMoves() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let lines = Lines()
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-2").data, to: box)
        server.post(TestPacket(item: "item-1", parents: ["sha256:forwarded"]).data, to: box)
        server.post(TestPacket(item: "item-1", needsReview: true).data, to: box)
        server.post(TestPacket(item: "gone").data, to: box)
        server.post(Data("not a packet".utf8), to: box)

        let result = await pickup(server, store, importer, clock: clock, lines: lines).check()

        XCTAssertEqual(result.droppedCount, 5)
        XCTAssertNil(result.banner)
        XCTAssertEqual(lines.all, [
            "reply_box.dropped reason=other_item", "reply_box.dropped reason=other_parent",
            "reply_box.dropped reason=needs_review", "reply_box.dropped reason=item_missing",
            "reply_box.dropped reason=unreadable",
        ])
        let saved = try XCTUnwrap(try store.loadReplyBox(id: box.id))
        XCTAssertEqual(saved.cursor, 5)
        XCTAssertEqual(saved.answers, [])
        let libraryCount = await importer.library.count
        XCTAssertEqual(libraryCount, 0)
    }

    func testAPostThatDoesNotOpenIsPassedOverAndTheNextOneArrives() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let lines = Lines()
        let box = try setUpBox(server: server, store: store)
        server.postRaw(try ReplyBox.random().sealAnswer(TestPacket(item: "item-1").data), to: box)
        server.post(TestPacket(item: "item-1", sender: "Ari").data, to: box)

        let result = await pickup(server, store, importer, clock: clock, lines: lines).check()

        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.arrivals.map(\.seq), [2])
        XCTAssertEqual(lines.all, ["reply_box.dropped reason=unopenable"])
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 2)
        let calls = await importer.calls
        XCTAssertEqual(calls, 1, "the importer never sees bytes that did not open")
    }

    func testAnEndedBoxIsMarkedAndNeverAskedAgain() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.end(box)
        let pickup = pickup(server, store, importer, clock: clock)

        let first = await pickup.check()
        XCTAssertEqual(first.endedBoxIds, [box.id])
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.ended, true)
        clock.advance(ReplyBoxPickup.throttle)
        _ = await pickup.check()
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: network

    func testOfflineShowsNothingLeavesTheCursorAndTheNextCheckFetches() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1", sender: "Dana").data, to: box)
        server.fail("after=0", .offline)
        let pickup = pickup(server, store, importer, clock: clock)

        let offline = await pickup.check()
        XCTAssertEqual(offline.stoppedBy, .offline)
        XCTAssertNil(offline.banner)
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 0)

        clock.advance(ReplyBoxPickup.throttle)
        let online = await pickup.check()
        XCTAssertNil(online.stoppedBy)
        XCTAssertEqual(online.arrivals.count, 1)
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 1)
    }

    func testOfflineMidwayKeepsWhatWasImportedAndStopsTheCheck() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let first = try setUpBox(server: server, store: store, lastChecked: start.addingTimeInterval(-500))
        let second = try setUpBox(server: server, store: store, lastChecked: start.addingTimeInterval(-100))
        server.post(TestPacket(item: "item-1").data, to: first)
        server.post(TestPacket(item: "item-1").data, to: first)
        server.post(TestPacket(item: "item-1").data, to: second)
        server.fail("/posts/2", .offline)

        let result = await pickup(server, store, importer, clock: clock).check()

        XCTAssertEqual(result.stoppedBy, .offline)
        XCTAssertEqual(result.arrivals.count, 1)
        XCTAssertEqual(try store.loadReplyBox(id: first.id)?.cursor, 1)
        XCTAssertEqual(try store.loadReplyBox(id: second.id)?.cursor, 0, "the check stopped before the next box")
        XCTAssertNotEqual(try store.loadReplyBox(id: first.id)?.lastChecked, start, "an unfinished box keeps its turn")
    }

    func testABusyServerStopsTheCheckQuietly() async throws {
        for (status, code) in [(429, "rate_limited"), (503, "busy"), (503, "disabled")] {
            path = FileManager.default.temporaryDirectory.appending(path: "reply-pickup-\(UUID().uuidString).sqlite").path
            let server = BoxServer(), store = try SQLiteSessionStore(path: path), clock = Clock(start)
            let box = try setUpBox(server: server, store: store)
            server.post(TestPacket(item: "item-1").data, to: box)
            server.fail("after=0", .status(status, code))
            let result = await pickup(server, store, Importer(), clock: clock).check()
            XCTAssertEqual(result.stoppedBy, .serverProblem, "\(status) \(code)")
            XCTAssertNil(result.banner)
            XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 0)
            XCTAssertEqual(try store.loadReplyBox(id: box.id)?.ended, false)
        }
    }

    func testAnUnknownBoxIsPassedOverAndTheOthersAreStillChecked() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), clock = Clock(start)
        let stranger = ReplyBox.random()
        try store.saveReplyBox(record(stranger, lastChecked: start.addingTimeInterval(-900)))  // never made on the server
        let box = try setUpBox(server: server, store: store, lastChecked: start.addingTimeInterval(-100))
        server.post(TestPacket(item: "item-1").data, to: box)
        let result = await pickup(server, store, Importer(), clock: clock).check()
        XCTAssertEqual(result.arrivals.count, 1)
        XCTAssertEqual(try store.loadReplyBox(id: stranger.id)?.ended, false, "a 404 is not taken as the end")
        XCTAssertEqual(try store.loadReplyBox(id: stranger.id)?.lastChecked, start)
    }

    // MARK: relaunch

    func testKilledBetweenTheImportAndTheCursorTheRelaunchImportsExactlyOnceAndSkipsNothing() async throws {
        let server = BoxServer(), importer = Importer(), clock = Clock(start)
        var box: ReplyBox!
        do {
            let store = try SQLiteSessionStore(path: path)
            box = try setUpBox(server: server, store: store)
            server.post(TestPacket(item: "item-1", sender: "Dana").data, to: box)
            server.post(TestPacket(item: "item-1", sender: "Dana").data, to: box)
            // The import of post 1 commits; the app dies before the cursor is saved.
            let killed = await pickup(server, FailingSaves(store, failures: 1), importer, clock: clock).check()
            XCTAssertEqual(killed.arrivals.count, 0, "the cursor didn't commit, so nothing is announced")
            XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 0)
        }
        clock.advance(ReplyBoxPickup.throttle)
        let relaunched = try SQLiteSessionStore(path: path)
        let result = await pickup(server, relaunched, importer, clock: clock).check()

        let library = await importer.library
        XCTAssertEqual(library.count, 2, "post 1 once, post 2 once")
        XCTAssertEqual(result.arrivals.map(\.seq), [2], "post 1 was already in: no second arrival")
        let saved = try XCTUnwrap(try relaunched.loadReplyBox(id: box.id))
        XCTAssertEqual(saved.cursor, 2)
        XCTAssertEqual(saved.answers.map(\.seq), [1, 2], "post 1's layer is still recorded for Report")
    }

    func testTheImporterSayingNotNowLeavesThatPostForTheNextCheck() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1").data, to: box)
        await importer.setNotNow(1)
        let pickup = pickup(server, store, importer, clock: clock)
        let first = await pickup.check()
        XCTAssertTrue(first.interrupted)
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 0)
        clock.advance(ReplyBoxPickup.throttle)
        let second = await pickup.check()
        XCTAssertEqual(second.arrivals.count, 1)
    }

    // MARK: background

    func testLeavingTheFrontStopsTheCheckAfterTheImportInHand() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1").data, to: box)
        server.post(TestPacket(item: "item-1").data, to: box)
        await importer.holdTheNextImport()
        let pickup = pickup(server, store, importer, clock: clock)

        let task = Task { await pickup.check() }
        await importer.waitUntilHeld()
        task.cancel()                       // the app left the front
        await importer.release()
        let result = await task.value

        XCTAssertTrue(result.interrupted)
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.cursor, 1, "the import in hand finished and its cursor saved")
        XCTAssertFalse(server.requests.contains { $0.path.hasSuffix("/posts/2") }, "nothing more is fetched")
        let calls = await importer.calls
        XCTAssertEqual(calls, 1)
    }

    func testACancelledTaskBeforeAnyRequestReadsNothing() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1").data, to: box)
        let pickup = pickup(server, store, Importer(), clock: clock)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await pickup.check()
        }
        let result = await task.value
        XCTAssertTrue(result.interrupted)
        XCTAssertEqual(server.requests, [])
    }

    // MARK: burst

    func testTwoComingsToTheFrontWithinTwoMinutesGiveOneCheck() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), clock = Clock(start)
        _ = try setUpBox(server: server, store: store)
        let pickup = pickup(server, store, Importer(), clock: clock)
        let first = await pickup.check(.becameActive)
        clock.advance(ReplyBoxPickup.throttle - 1)
        let second = await pickup.check(.becameActive)
        XCTAssertEqual(first.status, .checked)
        XCTAssertEqual(second.status, .throttled)
        XCTAssertEqual(server.requests.count, 1)
        let pulled = await pickup.check(.pullToRefresh)
        XCTAssertEqual(pulled.status, .checked, "pull-to-refresh always checks")
        clock.advance(ReplyBoxPickup.throttle)
        let later = await pickup.check(.becameActive)
        XCTAssertEqual(later.status, .checked)
        XCTAssertEqual(server.requests.count, 3)
    }

    func testACheckWhileOneIsRunningIsNotASecondCheck() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1").data, to: box)
        await importer.holdTheNextImport()
        let pickup = pickup(server, store, importer, clock: clock)
        let running = Task { await pickup.check() }
        await importer.waitUntilHeld()
        let overlapping = await pickup.check(.pullToRefresh)
        await importer.release()
        let result = await running.value
        XCTAssertEqual(overlapping.status, .alreadyRunning)
        XCTAssertEqual(result.arrivals.count, 1)
        let calls = await importer.calls
        XCTAssertEqual(calls, 1)
    }

    func testTwoFriendsPostingAtOnceBothArrive() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1", sender: "Dana").data, to: box)
        server.post(TestPacket(item: "item-1", sender: "Ari").data, to: box)
        let result = await pickup(server, store, Importer(), clock: clock).check()
        XCTAssertEqual(result.arrivals.map(\.senderLabel), ["Dana", "Ari"])
        XCTAssertEqual(result.banner?.text, "New answers from 2 friends")
        XCTAssertEqual(result.banner?.destination, .following)
    }

    // MARK: store

    func testACheckBeforeTheStoreIsOpenWaitsForItAndNeverReadsAnEmptyList() async throws {
        let server = BoxServer(), importer = Importer(), clock = Clock(start)
        let store = try SQLiteSessionStore(path: path)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1").data, to: box)
        let opened = StoreGate()
        let pickup = ReplyBoxPickup(client: server.client, store: { await opened.wait(); return store }, importer: importer, now: { clock.now })

        let task = Task { await pickup.check() }
        await opened.waitForWaiter()
        XCTAssertEqual(server.requests, [], "nothing is asked before the store is open")
        await opened.open()
        let result = await task.value
        XCTAssertEqual(result.arrivals.count, 1)
    }

    func testAStoreThatCannotOpenDropsNoBoxAndDoesNotSpendTheThrottle() async throws {
        let server = BoxServer(), clock = Clock(start)
        let store = try SQLiteSessionStore(path: path)
        let box = try setUpBox(server: server, store: store)
        let failing = ReplyBoxPickup(
            client: server.client, store: { throw NSError(domain: "not open", code: 1) }, importer: Importer(), now: { clock.now }
        )
        let result = await failing.check()
        XCTAssertEqual(result.status, .storeUnavailable)
        XCTAssertEqual(try store.loadReplyBoxes().map(\.boxId), [box.id])
        let again = await failing.check()
        XCTAssertEqual(again.status, .storeUnavailable, "not throttled")
    }

    actor StoreGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var waiterArrived: CheckedContinuation<Void, Never>?
        private var hasWaiter = false
        func wait() async {
            if isOpen { return }
            hasWaiter = true
            waiterArrived?.resume()
            waiterArrived = nil
            await withCheckedContinuation { waiters.append($0) }
        }
        func waitForWaiter() async {
            if hasWaiter { return }
            await withCheckedContinuation { waiterArrived = $0 }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    // MARK: Which boxes a check reads

    func testUpTo20BoxesTheOnesCheckedLongestAgoFirstAndOnlyReadableOnes() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), clock = Clock(start)
        var boxes: [ReplyBox] = []
        for index in 0..<25 {
            boxes.append(try setUpBox(server: server, store: store, lastChecked: index == 0 ? nil : start.addingTimeInterval(Double(-index * 60))))
        }
        // Past the read window, and closed then already checked: neither is asked about.
        let expired = ReplyBox.random()
        server.make(expired)
        try store.saveReplyBox(record(expired, daysAgo: 40))
        let closed = ReplyBox.random()
        server.make(closed)
        var closedRecord = record(closed).markingClosed(at: start.addingTimeInterval(-7200))
        closedRecord.lastChecked = start.addingTimeInterval(-3600)
        try store.saveReplyBox(closedRecord)

        _ = await pickup(server, store, Importer(), clock: clock).check()

        let listed = server.requests.map { String($0.path.split(separator: "/")[3]) }
        XCTAssertEqual(listed.count, ReplyBoxPickup.maximumBoxesPerCheck)
        let expected = [boxes[0]] + boxes[1...].reversed()  // never checked, then the oldest checks
        XCTAssertEqual(listed, Array(expected.prefix(20)).map(\.id))
        XCTAssertFalse(listed.contains(expired.id))
        XCTAssertFalse(listed.contains(closed.id))
    }

    func testRetentionDeletesAnEndedRecordOnlyOnceNoneOfItsAnswersIsInTheLibrary() async throws {
        let server = BoxServer(), store = try SQLiteSessionStore(path: path), importer = Importer(), clock = Clock(start)
        let box = try setUpBox(server: server, store: store)
        server.post(TestPacket(item: "item-1").data, to: box)
        let pickup = pickup(server, store, importer, clock: clock)
        _ = await pickup.check()
        XCTAssertEqual(try store.loadReplyBox(id: box.id)?.answers.count, 1)

        clock.advance(40 * 86_400)        // past expiresAt + 7 days
        let kept = await pickup.check()
        XCTAssertEqual(kept.deletedBoxIds, [])
        XCTAssertNotNil(try store.loadReplyBox(id: box.id), "its answer is still in the Library, so Report still works")

        await importer.removeLayer("layer-1")
        clock.advance(ReplyBoxPickup.throttle)
        let deleted = await pickup.check()
        XCTAssertEqual(deleted.deletedBoxIds, [box.id])
        XCTAssertNil(try store.loadReplyBox(id: box.id))
    }
}
