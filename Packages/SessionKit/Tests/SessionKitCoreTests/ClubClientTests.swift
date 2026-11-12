#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit

/// The club mailbox calls (#1799). The server here is a Swift stand-in for the real one's wire table
/// (`docs/design/club-mailbox.md` section 5), which the Go server's own tests pin; the phone-side rules under test are
/// what the phone sends, what it does with each answer, and that a club of ten ends with every packet once.
final class ClubClientTests: XCTestCase {
    // MARK: Make and join

    func testACreatorMakesAClubAndAJoinerReadsItsNameFromTheLinkAlone() async throws {
        let server = FakeClubServer()
        let creator = ClubInvite.random()
        try await server.client.create(creator, header: header("Tuesday Night Book Club", label: "Dana"))

        // The joiner has only the link a friend sent.
        let joiner = try invite(fromLink: creator.url())
        let opened = try await server.client.header(of: joiner)
        XCTAssertEqual(opened.name, "Tuesday Night Book Club")
        XCTAssertEqual(opened.creatorLabel, "Dana")
    }

    func testTheCreateRequestCarriesTheIdTheHashesAndTheSealedHeaderAndNoSecret() async throws {
        let server = FakeClubServer()
        let creator = ClubInvite.random()
        try await server.client.create(creator, header: header("Secret Society"))

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/clubs")
        XCTAssertNil(request.bearer, "no credential and no install identity on a create")
        let body = try XCTUnwrap(request.body)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Set(fields.keys), ["id", "readHash", "postHash", "header"])
        XCTAssertEqual(fields["id"], creator.id)
        XCTAssertEqual(fields["readHash"], creator.credentials.readHash)
        XCTAssertEqual(fields["postHash"], creator.credentials.postHash)
        let text = String(decoding: body, as: UTF8.self)
        for secret in [creator.key.fragment, creator.credentials.readProof, creator.credentials.postProof,
                       ClubSealing.Credentials.hex(creator.credentials.sealKey), "Secret Society"] {
            XCTAssertFalse(text.contains(secret), "the server must not get \(secret.prefix(6))…")
        }
    }

    func testARetriedCreateIsTheSameSuccess() async throws {
        let server = FakeClubServer()
        let creator = ClubInvite.random()
        try await server.client.create(creator, header: header("Club"))
        try await server.client.create(creator, header: header("Club"))
        XCTAssertEqual(server.statuses, [201, 200])
    }

    // MARK: Post and read

    func testPostsCarryOnlyThePostProofAndReadsOnlyTheReadProof() async throws {
        let server = FakeClubServer()
        let creator = try await newClub(on: server)
        try await server.client.post(Data("one".utf8), to: creator)
        _ = try await server.client.fetchNew(for: creator, after: .init())

        let post = try XCTUnwrap(server.requests.first { $0.method == "POST" && $0.path.hasSuffix("/posts") })
        XCTAssertEqual(post.bearer, creator.credentials.postProof)
        XCTAssertEqual(post.contentType, "application/octet-stream")
        XCTAssertNil(post.body.flatMap { $0.range(of: Data("one".utf8)) }, "the post goes up sealed")
        for read in server.requests.filter({ $0.method == "GET" }) {
            XCTAssertEqual(read.bearer, creator.credentials.readProof)
        }
        XCTAssertEqual(server.requests.map(\.path).filter { $0.contains("/posts?after=") }, ["/api/v1/clubs/\(creator.id)/posts?after=0"])
    }

    func testAPostReturnsTheNumberTheServerGaveIt() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        let first = try await server.client.post(Data("a".utf8), to: club)
        let second = try await server.client.post(Data("b".utf8), to: club)
        XCTAssertEqual([first, second], [1, 2])
    }

    func testTenMembersEndWithTheSameThirtyPacketsOnceEach() async throws {
        let server = FakeClubServer()
        let creator = try await newClub(on: server)
        // Nine join with only the link.
        let members = [creator] + (1..<10).map { _ in try! invite(fromLink: creator.url()) }
        var cursors = Array(repeating: ClubClient.Cursor(), count: members.count)
        var heard: [[Data]] = Array(repeating: [], count: members.count)

        func catchUp(_ member: Int) async throws {
            let fetched = try await server.client.fetchNew(for: members[member], after: cursors[member])
            XCTAssertNil(fetched.stoppedBy)
            XCTAssertEqual(fetched.skipped, [])
            heard[member] += fetched.posts.map(\.packet)
            cursors[member] = fetched.cursor
        }

        // Each posts three packets, with reads in between, so members see the club at different moments.
        for round in 0..<3 {
            for member in members.indices {
                try await server.client.post(Data("member \(member), packet \(round)".utf8), to: members[member])
                try await catchUp((member + 3) % members.count)
            }
        }
        for member in members.indices { try await catchUp(member) }

        let expected = Set((0..<10).flatMap { member in (0..<3).map { Data("member \(member), packet \($0)".utf8) } })
        XCTAssertEqual(expected.count, 30)
        for member in members.indices {
            XCTAssertEqual(heard[member].count, 30, "member \(member) hears every post once")
            XCTAssertEqual(Set(heard[member]), expected, "member \(member)")
            XCTAssertEqual(cursors[member].lastPost, 30)
        }
        // A phone that asks again with an up-to-date cursor gets nothing and moves nothing.
        let again = try await server.client.fetchNew(for: members[4], after: cursors[4])
        XCTAssertEqual(again, ClubClient.Fetched(posts: [], skipped: [], cursor: .init(lastPost: 30), stoppedBy: nil))
    }

    func testAPhoneThatWasAwayReadsFromItsCursorOn() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        for number in 1...5 { try await server.client.post(Data("p\(number)".utf8), to: club) }
        let fetched = try await server.client.fetchNew(for: club, after: .init(lastPost: 3))
        XCTAssertEqual(fetched.posts.map(\.number), [4, 5])
        XCTAssertEqual(fetched.posts.map(\.packet), [Data("p4".utf8), Data("p5".utf8)])
        XCTAssertEqual(fetched.cursor.lastPost, 5)
    }

    // MARK: One bad post never blocks a club

    func testAPostThatDoesNotOpenIsSkippedAndTheCursorMovesPast() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        let other = ClubInvite.random()
        try await server.client.post(Data("good one".utf8), to: club)
        server.plant(sealedFor: other, packet: Data("someone else's".utf8), in: club)        // 2: another club's bytes
        server.plant(raw: Data("plain, not sealed at all".utf8), in: club)                    // 3: not sealed
        server.plant(raw: Data(), in: club)                                                   // 4: empty
        try await server.client.post(Data("good two".utf8), to: club)                         // 5
        var flipped = try ClubSealing.seal(Data("flipped".utf8), as: .post, in: club.credentials)
        flipped[flipped.count - 1] ^= 1
        server.plant(raw: flipped, in: club)                                                  // 6: a flipped byte
        let asHeader = try ClubSealing.seal(Data("{}".utf8), as: .header, in: club.credentials)
        server.plant(raw: asHeader, in: club)                                                 // 7: the header's part
        try await server.client.post(Data("good three".utf8), to: club)                       // 8

        let fetched = try await server.client.fetchNew(for: club, after: .init())
        XCTAssertEqual(fetched.posts.map(\.packet), ["good one", "good two", "good three"].map { Data($0.utf8) })
        XCTAssertEqual(fetched.posts.map(\.number), [1, 5, 8])
        XCTAssertEqual(fetched.skipped, [2, 3, 4, 6, 7])
        XCTAssertEqual(fetched.cursor.lastPost, 8)
        XCTAssertNil(fetched.stoppedBy)
    }

    func testBadPostsAtTheEndStillMoveTheCursorSoTheyAreNotFetchedAgain() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        try await server.client.post(Data("good".utf8), to: club)
        server.plant(raw: Data("junk".utf8), in: club)
        server.plant(raw: Data("more junk".utf8), in: club)

        let first = try await server.client.fetchNew(for: club, after: .init())
        XCTAssertEqual(first.posts.map(\.number), [1])
        XCTAssertEqual(first.skipped, [2, 3])
        XCTAssertEqual(first.cursor.lastPost, 3)

        let fetchesBefore = server.requests.filter { $0.path.hasSuffix("/posts/2") || $0.path.hasSuffix("/posts/3") }.count
        let second = try await server.client.fetchNew(for: club, after: first.cursor)
        XCTAssertEqual(second, ClubClient.Fetched(posts: [], skipped: [], cursor: .init(lastPost: 3), stoppedBy: nil))
        XCTAssertEqual(server.requests.filter { $0.path.hasSuffix("/posts/2") || $0.path.hasSuffix("/posts/3") }.count, fetchesBefore)
    }

    func testAHostileListCannotCarryTheCursorPastEveryRealPost() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        for number in 1...3 { try await server.client.post(Data("p\(number)".utf8), to: club) }
        server.listTransform = { _ in [1, 2, 3, Int.max, 5_000, ClubClient.maximumJump + 1] }
        let fetched = try await server.client.fetchNew(for: club, after: .init())
        XCTAssertEqual(fetched.posts.map(\.number), [1, 2, 3])
        XCTAssertEqual(fetched.cursor.lastPost, 3, "later posts are still fetched next time")
        XCTAssertFalse(server.requests.contains { $0.path.hasSuffix("/posts/\(Int.max)") || $0.path.hasSuffix("/posts/5000") })
        // The edge: exactly maximumJump past the cursor is believed.
        server.listTransform = { _ in [3 + ClubClient.maximumJump] }
        let edge = try await server.client.fetchNew(for: club, after: .init(lastPost: 3))
        XCTAssertEqual(edge.skipped, [3 + ClubClient.maximumJump])
    }

    func testADamagedSavedCursorStartsOverInsteadOfAskingForANegativeNumber() throws {
        for (json, expected) in [(#"{"lastPost":-4}"#, 0), (#"{"lastPost":0}"#, 0), (#"{"lastPost":12}"#, 12)] {
            let cursor = try JSONDecoder().decode(ClubClient.Cursor.self, from: Data(json.utf8))
            XCTAssertEqual(cursor.lastPost, expected, json)
        }
        let round = try JSONDecoder().decode(ClubClient.Cursor.self, from: JSONEncoder().encode(ClubClient.Cursor(lastPost: 7)))
        XCTAssertEqual(round, ClubClient.Cursor(lastPost: 7))
    }

    func testACancelledRunThrowsAndLeavesTheCursorWhereItWas() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        for number in 1...3 { try await server.client.post(Data("p\(number)".utf8), to: club) }
        server.failOnPath = ("/posts/2", .failure(CancellationError()))
        do {
            _ = try await server.client.fetchNew(for: club, after: .init())
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testNothingSecretPrintsEvenByAccident() throws {
        let invite = ClubInvite.random()
        let request = ClubClient.Request(method: "GET", path: "/api/v1/clubs/\(invite.id)/posts", bearer: invite.credentials.readProof, body: Data("secret body".utf8), contentType: nil)
        let secrets = [invite.key.fragment, invite.credentials.readProof, invite.credentials.postProof,
                       ClubSealing.Credentials.hex(invite.credentials.sealKey), "secret body"]
        for text in ["\(invite)", "\(invite.credentials)", "\(request)", String(reflecting: invite), String(reflecting: invite.credentials), String(reflecting: request)] {
            for secret in secrets { XCTAssertFalse(text.contains(secret), "\(text) leaked a secret") }
        }
    }

    func testAServerThatRepeatsOrReordersTheListCannotMakeAPostCountTwice() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        for number in 1...4 { try await server.client.post(Data("p\(number)".utf8), to: club) }
        server.listTransform = { numbers in [4, 2, 2, 1, 3, 3, 0, -5, 1] }
        let fetched = try await server.client.fetchNew(for: club, after: .init(lastPost: 1))
        XCTAssertEqual(fetched.posts.map(\.number), [2, 3, 4])
        XCTAssertEqual(server.requests.filter { $0.path.hasSuffix("/posts/2") }.count, 1)
        XCTAssertEqual(fetched.cursor.lastPost, 4)
    }

    func testAPostTakenDownBetweenTheListAndTheFetchIsPassedOver() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        for number in 1...3 { try await server.client.post(Data("p\(number)".utf8), to: club) }
        server.removeAfterListing = [2]
        let fetched = try await server.client.fetchNew(for: club, after: .init())
        XCTAssertEqual(fetched.posts.map(\.number), [1, 3])
        XCTAssertEqual(fetched.skipped, [2])
        XCTAssertEqual(fetched.cursor.lastPost, 3)
    }

    // MARK: A failed call partway loses nothing

    func testAFailurePartwayReturnsWhatWasReadAndTheCursorResumesWithoutLossOrRepeat() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        for number in 1...5 { try await server.client.post(Data("p\(number)".utf8), to: club) }
        server.failOnPath = ("/posts/4", .failure(URLError(.networkConnectionLost)))

        let first = try await server.client.fetchNew(for: club, after: .init())
        XCTAssertEqual(first.posts.map(\.number), [1, 2, 3])
        XCTAssertEqual(first.cursor.lastPost, 3)
        XCTAssertEqual(first.stoppedBy, .offline)

        server.failOnPath = nil
        let second = try await server.client.fetchNew(for: club, after: first.cursor)
        XCTAssertEqual(second.posts.map(\.number), [4, 5])
        XCTAssertNil(second.stoppedBy)
        XCTAssertEqual(second.cursor.lastPost, 5)
    }

    func testAnAnswerThatIsNotAListIsUnexpectedAndMovesNothing() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        server.failOnPath = ("/posts?after=0", .answer(200, Data("<html>captive portal</html>".utf8)))
        await assertFails(.unexpected) { _ = try await server.client.fetchNew(for: club, after: .init()) }
    }

    // MARK: What each answer means

    func testEveryAnswerHasOnePlainMeaning() async throws {
        let club = ClubInvite.random()
        func error(_ code: String) -> Data { Data(#"{"error":"\#(code)"}"#.utf8) }
        let table: [(Int, Data, ClubClient.Failure)] = [
            (404, error("not_found"), .notFound),
            (410, error("expired_or_removed"), .gone),
            (409, error("club_full"), .clubFull),
            (413, error("too_large"), .tooLarge),
            (429, error("rate_limited"), .serverProblem),
            (500, error("internal"), .serverProblem),
            (503, error("disabled"), .serverProblem),
            (503, error("busy"), .serverProblem),
            (503, error("full"), .serverProblem),
            (409, error("id_in_use"), .unexpected),
            (400, error("bad_packet"), .unexpected),
            (400, error("bad_request"), .unexpected),
            (401, Data(), .unexpected),
            (418, Data("<html>".utf8), .unexpected),
            (302, Data(), .unexpected),
            (200, Data("not json".utf8), .unexpected)
        ]
        for (status, body, expected) in table {
            let client = ClubClient(send: { _, _ in (status, body) })
            await assertFails(expected, "post \(status) \(String(decoding: body, as: UTF8.self))") { try await client.post(Data("x".utf8), to: club) }
            if status != 200 {
                await assertFails(expected, "fetch \(status)") { _ = try await client.fetchNew(for: club, after: .init()) }
                await assertFails(expected, "header \(status)") { _ = try await client.header(of: club) }
                await assertFails(expected, "create \(status)") { try await client.create(club, header: ClubHeader(name: "x")!) }
            }
        }
        // A post that the server accepted but answered oddly does not count as posted.
        let odd = ClubClient(send: { _, _ in (201, Data(#"{"seq":0}"#.utf8)) })
        await assertFails(.unexpected) { try await odd.post(Data("x".utf8), to: club) }
    }

    func testNetworkErrorsAreOfflineOrUnexpectedAndRetryIsOfferedOnlyWhenItCouldHelp() async throws {
        let club = ClubInvite.random()
        let offline: [URLError.Code] = [.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
        for code in offline {
            let client = ClubClient(send: { _, _ in throw URLError(code) })
            await assertFails(.offline, "\(code)") { try await client.post(Data("x".utf8), to: club) }
        }
        let secure = ClubClient(send: { _, _ in throw URLError(.serverCertificateUntrusted) })
        await assertFails(.unexpected) { try await secure.post(Data("x".utf8), to: club) }
        let other = ClubClient(send: { _, _ in struct Odd: Error {}; throw Odd() })
        await assertFails(.unexpected) { try await other.post(Data("x".utf8), to: club) }

        XCTAssertEqual(
            [ClubClient.Failure.offline, .serverProblem].map(\.isRetryable), [true, true])
        XCTAssertEqual(
            [ClubClient.Failure.notFound, .gone, .clubFull, .tooLarge, .unexpected, .incompleteOrDamaged].map(\.isRetryable),
            Array(repeating: false, count: 6))
    }

    func testACancelledCallStaysACancellation() async throws {
        let club = ClubInvite.random()
        for thrown in [CancellationError() as Error, URLError(.cancelled)] {
            let client = ClubClient(send: { _, _ in throw thrown })
            do {
                try await client.post(Data("x".utf8), to: club)
                XCTFail("expected a cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }
    }

    func testAWrongLinkAndAnEndedClubAreToldApart() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        await assertFails(.notFound) { _ = try await server.client.header(of: ClubInvite.random()) }
        server.end(club)
        await assertFails(.gone) { _ = try await server.client.fetchNew(for: club, after: .init()) }
        await assertFails(.gone) { try await server.client.post(Data("late".utf8), to: club) }
        // Someone who only has the id, or the wrong key for it, is told nothing more than "not found".
        await assertFails(.notFound) { _ = try await server.client.header(of: ClubInvite.random()) }
    }

    func testAHeaderThatDoesNotOpenIsDamagedNotAGuess() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        server.replaceHeader(of: club, with: Data("SMLINK\u{1}\u{3}".utf8) + Data(repeating: 7, count: 40))
        await assertFails(.incompleteOrDamaged) { _ = try await server.client.header(of: club) }
    }

    // MARK: Caps

    func testAPostOverTheServersCapIsRefusedBeforeAnythingIsSent() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        let before = server.requests.count
        // The server refuses a sealed body over 20 MiB, so the phone's largest packet is 20 MiB less the sealing overhead.
        XCTAssertEqual(ClubClient.maximumPostBytes, 20 << 20)
        let tooBig = Data(count: ClubClient.maximumPostBytes - ClubSealing.overheadByteCount + 1)
        await assertFails(.tooLarge) { try await server.client.post(tooBig, to: club) }
        XCTAssertEqual(server.requests.count, before)
        // Exactly at the cap goes up, and the server (which enforces the same cap) takes it.
        let exact = Data(count: ClubClient.maximumPostBytes - ClubSealing.overheadByteCount)
        let number = try await server.client.post(exact, to: club)
        XCTAssertEqual(number, 1)
        XCTAssertEqual(server.requests.last?.body?.count, 20 << 20)
    }

    func testAFullClubSaysSoAndKeepsWhatItHas() async throws {
        let server = FakeClubServer(postCap: 2)
        let club = try await newClub(on: server)
        try await server.client.post(Data("1".utf8), to: club)
        try await server.client.post(Data("2".utf8), to: club)
        await assertFails(.clubFull) { try await server.client.post(Data("3".utf8), to: club) }
        let fetched = try await server.client.fetchNew(for: club, after: .init())
        XCTAssertEqual(fetched.posts.count, 2)
    }

    func testReadsAskForNoMoreThanTheirCap() async throws {
        let server = FakeClubServer()
        let club = try await newClub(on: server)
        try await server.client.post(Data("a".utf8), to: club)
        _ = try await server.client.header(of: club)
        _ = try await server.client.fetchNew(for: club, after: .init())
        let caps = server.caps
        XCTAssertTrue(caps.allSatisfy { $0 <= ClubClient.maximumPostBytes })
        XCTAssertTrue(caps.contains(ClubClient.maximumHeaderBytes))
        XCTAssertTrue(caps.contains(ClubClient.maximumPostBytes))
    }

    // MARK: Helpers

    private func header(_ name: String, label: String? = nil) -> ClubHeader { ClubHeader(name: name, creatorLabel: label)! }

    private func newClub(on server: FakeClubServer) async throws -> ClubInvite {
        let club = ClubInvite.random()
        try await server.client.create(club, header: header("A club"))
        return club
    }

    private func invite(fromLink url: URL) throws -> ClubInvite {
        guard case .invite(let invite) = ClubInvite.parse(url) else {
            XCTFail("not an invite: \(url)")
            throw ClubClient.Failure.incompleteOrDamaged
        }
        return invite
    }

    private func assertFails(
        _ expected: ClubClient.Failure,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClubClient.Failure, expected, message, file: file, line: line)
        }
    }
}

/// The club server's four calls as the design's table gives them, held in memory: proofs checked by SHA-256 before
/// anything else, a wrong proof and an unknown club answered alike, post numbers handed out on arrival.
final class FakeClubServer: @unchecked Sendable {
    enum Scripted {
        case failure(Error)
        case answer(Int, Data)
    }

    private struct Club {
        var readHash: String
        var postHash: String
        var items: [Data]          // item 0 is the header
        var removed: Set<Int> = []
        var ended = false
    }

    private let lock = NSLock()
    private var clubs: [String: Club] = [:]
    private let postCap: Int
    private var _requests: [ClubClient.Request] = []
    private var _statuses: [Int] = []
    private var _caps: [Int] = []

    /// Rewrites the numbers a list answer names.
    var listTransform: (([Int]) -> [Int])?
    /// Post numbers removed right after a list answer names them.
    var removeAfterListing: Set<Int> = []
    /// A request whose path ends with this gets the scripted answer instead.
    var failOnPath: (String, Scripted)?

    init(postCap: Int = 200) {
        self.postCap = postCap
    }

    var client: ClubClient {
        ClubClient(send: { [self] request, maximum in try await handle(request, maximum) })
    }

    var requests: [ClubClient.Request] { lock.withLock { _requests } }
    var statuses: [Int] { lock.withLock { _statuses } }
    var caps: [Int] { lock.withLock { _caps } }

    func plant(sealedFor other: ClubInvite, packet: Data, in invite: ClubInvite) {
        let sealed = try! ClubSealing.seal(packet, as: .post, in: other.credentials)
        plant(raw: sealed, in: invite)
    }

    func plant(raw: Data, in invite: ClubInvite) {
        lock.withLock { clubs[invite.id]!.items.append(raw) }
    }

    func end(_ invite: ClubInvite) { lock.withLock { clubs[invite.id]!.ended = true } }

    func replaceHeader(of invite: ClubInvite, with bytes: Data) { lock.withLock { clubs[invite.id]!.items[0] = bytes } }

    private func handle(_ request: ClubClient.Request, _ maximum: Int) async throws -> (status: Int, body: Data) {
        let scripted: Scripted? = lock.withLock {
            _requests.append(request)
            _caps.append(maximum)
            if let (suffix, answer) = failOnPath, request.path.hasSuffix(suffix) { return answer }
            return nil
        }
        if let scripted {
            switch scripted {
            case .failure(let error): throw error
            case .answer(let status, let body): return record(status, body)
            }
        }
        return lock.withLock { respond(request) }
    }

    private func record(_ status: Int, _ body: Data) -> (status: Int, body: Data) {
        lock.withLock { _statuses.append(status) }
        return (status, body)
    }

    private func error(_ status: Int, _ code: String) -> (status: Int, body: Data) {
        _statuses.append(status)
        return (status, Data(#"{"error":"\#(code)"}"#.utf8))
    }

    private func ok(_ status: Int, _ body: Data) -> (status: Int, body: Data) {
        _statuses.append(status)
        return (status, body)
    }

    /// Called with the lock held.
    private func respond(_ request: ClubClient.Request) -> (status: Int, body: Data) {
        let parts = request.path.split(separator: "?", maxSplits: 1).map(String.init)
        let segments = parts[0].split(separator: "/").map(String.init)      // api v1 clubs [id [posts [n]]]
        guard segments.count >= 3, segments[0] == "api", segments[1] == "v1", segments[2] == "clubs" else {
            return error(404, "not_found")
        }
        if segments.count == 3 {
            guard request.method == "POST", let body = request.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  let id = json["id"], let readHash = json["readHash"], let postHash = json["postHash"],
                  let header = json["header"].flatMap({ Data(base64Encoded: $0) }),
                  header.starts(with: Data("SMLINK".utf8) + [1, 3]) else { return error(400, "bad_request") }
            if let existing = clubs[id] {
                return existing.readHash == readHash && existing.postHash == postHash ? ok(200, Data(#"{"id":"\#(id)"}"#.utf8)) : error(409, "id_in_use")
            }
            clubs[id] = Club(readHash: readHash, postHash: postHash, items: [header])
            return ok(201, Data(#"{"id":"\#(id)"}"#.utf8))
        }
        // Everything under a club checks the proof first, and a wrong one is the same 404 as an unknown club.
        let id = segments[3]
        let kind = request.method == "POST" ? "post" : "read"
        guard var club = clubs[id], let bearer = request.bearer,
              let raw = Data(hexString: bearer), raw.count == 32,
              ClubSealing.Credentials.hex(Data(SHA256.hash(data: raw))) == (kind == "post" ? club.postHash : club.readHash) else {
            return error(404, "not_found")
        }
        if club.ended { return error(410, "expired_or_removed") }
        defer { clubs[id] = club }
        switch (request.method, segments.count) {
        case ("POST", 5):
            guard club.items.count - 1 < postCap else { return error(409, "club_full") }
            guard let body = request.body, body.starts(with: Data("SMLINK".utf8) + [1, 2]), body.count >= 36 else {
                return error(400, "bad_packet")
            }
            guard body.count <= 20 << 20 else { return error(413, "too_large") }
            club.items.append(body)
            return ok(201, Data(#"{"seq":\#(club.items.count - 1)}"#.utf8))
        case ("GET", 5):
            let after = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: "after=", with: "")) ?? 0 : 0
            var numbers = club.items.indices.filter { $0 > after && !club.removed.contains($0) }
            if let listTransform { numbers = listTransform(numbers) }
            let entries = numbers.map { #"{"seq":\#($0),"size":\#($0 >= 0 && $0 < club.items.count ? club.items[$0].count : 0)}"# }
            club.removed.formUnion(removeAfterListing)
            return ok(200, Data(#"{"posts":[\#(entries.joined(separator: ","))]}"#.utf8))
        case ("GET", 6):
            guard let number = Int(segments[5]), number >= 0, number < club.items.count, !club.removed.contains(number) else {
                return error(404, "not_found")
            }
            return ok(200, club.items[number])
        default:
            return error(404, "not_found")
        }
    }
}
