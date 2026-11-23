import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #4341: following a Zotero list end to end on the host, over a real SQLite store and a transport that answers with the
/// real replies saved under Contracts/fixtures/feeds (Zotero's public "Test Items Library", group 2205533, collection
/// "APA, 6th edition" DMKBHP6P, fetched with `Zotero-API-Version: 3` and no key).
final class PaperSourceFollowingTests: XCTestCase {
    static let groupLink = "https://www.zotero.org/groups/2205533/test_items_library/collections/DMKBHP6P"
    static let source = PaperSource.zoteroGroup(groupID: 2205533, collectionKey: "DMKBHP6P")
    static let knownKey = "P9NiFoyLeZu2bZNvKnownKey"

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TestInputs.url(.contracts, "fixtures/feeds/\(name).json"))
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    /// Answers each request from a table keyed by path (and `start` for pages); records every request it saw.
    final class FakeZotero: @unchecked Sendable {
        var replies: [String: PaperFetchReply] = [:]
        var failure: Error?
        var requests: [URLRequest] = []
        private let lock = NSLock()

        func key(_ url: URL) -> String {
            let start = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "start" }?.value
            let type = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itemType" }?.value
            return url.path + (type.map { "?itemType=\($0)" } ?? "") + (start.map { "#\($0)" } ?? "")
        }

        var transport: PaperTransport {
            { [self] request in
                let (failure, reply) = lock.withLock { () -> (Error?, PaperFetchReply?) in
                    requests.append(request)
                    return (self.failure, replies[key(request.url!)])
                }
                if let failure { throw failure }
                return reply ?? PaperFetchReply(status: 404, data: Data("Not found".utf8))
            }
        }
    }

    private func realZotero() throws -> FakeZotero {
        let fake = FakeZotero()
        fake.replies["/groups/2205533/collections/DMKBHP6P/items/top#0"] = PaperFetchReply(
            status: 200, data: try fixture("zotero-group-collection"), totalResults: 25)
        fake.replies["/groups/2205533/collections/DMKBHP6P/items?itemType=attachment#0"] = PaperFetchReply(
            status: 200, data: try fixture("zotero-group-attachments"))
        fake.replies["/groups/2205533/collections/DMKBHP6P"] = PaperFetchReply(status: 200, data: try fixture("zotero-api/collection-record"))
        fake.replies["/groups/2205533"] = PaperFetchReply(status: 200, data: try fixture("zotero-api/group-record"))
        return fake
    }

    private var lastStorePath = ""

    private func store() throws -> SQLiteSessionStore {
        lastStorePath = FileManager.default.temporaryDirectory.appending(path: "papers-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: lastStorePath)
    }

    // MARK: Following

    func testFollowingAPublicCollectionStoresItsNameAndPapers() async throws {
        let fake = try realZotero()
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        let outcome = await following.follow(pasted: "  \(Self.groupLink) ", apiKey: nil, zoteroConnected: false, now: date(0))
        guard case .followed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.id, "zotero:group:2205533:collection:DMKBHP6P")
        XCTAssertEqual(record.title, "APA, 6th edition", "the collection's own name")
        XCTAssertEqual(record.link, Self.groupLink)
        XCTAssertEqual(record.entries.count, 24, "the paper with no title is left out")
        XCTAssertEqual(record.totalCount, 25)
        XCTAssertEqual(try store.loadPaperSources(), [record])
        XCTAssertEqual(PaperSourceRow(record: record).detail, "Zotero · 25 papers", "first follow: the whole count, nothing new")
        XCTAssertEqual(fake.requests.filter { $0.url!.path.hasSuffix("/items/top") }.count, 1, "one page: Zotero said 25 in all")
        XCTAssertTrue(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: "Zotero-API-Version") == "3" })
        XCTAssertTrue(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader) == nil }, "a public group gets no key")
    }

    func testAWholeGroupLibraryIsNamedAfterTheGroup() async throws {
        let fake = try realZotero()
        fake.replies["/groups/2205533/items/top#0"] = PaperFetchReply(status: 200, data: try fixture("zotero-group-collection"), totalResults: 25)
        let following = PaperSourceFollowing(store: try store(), fetcher: PaperSourceFetcher(transport: fake.transport))
        let outcome = await following.follow(pasted: "https://www.zotero.org/groups/2205533/test_items_library/library", apiKey: nil,
                                             zoteroConnected: false, now: date(0))
        guard case .followed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.title, "Test Items Library")
    }

    func testFollowingTheSameListTwiceKeepsOneRecord() async throws {
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: try realZotero().transport))
        _ = await following.follow(pasted: Self.groupLink, apiKey: nil, zoteroConnected: false, now: date(0))
        let again = await following.follow(pasted: "https://api.zotero.org/groups/2205533/collections/DMKBHP6P/items/top", apiKey: nil,
                                           zoteroConnected: false, now: date(5))
        guard case .alreadyFollowing(let record) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(record.followedAt, date(0))
        XCTAssertEqual(try store.loadPaperSources().count, 1)
    }

    func testLinksThatAreNotPapersGoToTodaysFollowAndRejectedOnesSayWhy() async throws {
        let store = try store()
        let fake = try realZotero()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        for link in ["https://example.com/feed.xml", "https://pubmed.ncbi.nlm.nih.gov/rss/search/1abcDEF/?limit=15", "not a link"] {
            let outcome = await following.follow(pasted: link, apiKey: nil, zoteroConnected: false, now: date(0))
            XCTAssertEqual(outcome, .notAPaperLink, link)
        }
        let user = await following.follow(pasted: "https://www.zotero.org/someone/collections/ABCD2345", apiKey: nil, zoteroConnected: false, now: date(0))
        XCTAssertEqual(user, .rejected("That Zotero library is private. Connect your library in Settings to follow it."))
        let connected = await following.follow(pasted: "https://www.zotero.org/someone/library", apiKey: Self.knownKey, zoteroConnected: true, now: date(0))
        XCTAssertEqual(connected, .rejected("That Zotero library is private. Follow it from Your collections."))
        let search = await following.follow(pasted: "https://pubmed.ncbi.nlm.nih.gov/?term=sleep", apiKey: nil, zoteroConnected: false, now: date(0))
        XCTAssertEqual(search, .rejected("That's a PubMed search page. Use its Create RSS link instead."))
        XCTAssertEqual(try store.loadPaperSources(), [])
        XCTAssertTrue(fake.requests.isEmpty, "nothing was fetched for any of them")
    }

    // MARK: The network row of the Design

    func testEachFailureGivesItsMessageAndStoresNothing() async throws {
        let cases: [(status: Int?, error: Error?, message: String)] = [
            (nil, URLError(.notConnectedToInternet), "You're offline. Try again when you're connected."),
            (nil, URLError(.timedOut), "Zotero couldn't be reached. Try again later."),
            (403, nil, "That Zotero library is private. Connect your library in Settings to follow it."),
            (404, nil, "Zotero couldn't find that collection. Check the link."),
            (429, nil, "Zotero is busy. Try again in a few minutes."),
            (503, nil, "Zotero is busy. Try again in a few minutes."),
            (500, nil, "Zotero couldn't be reached. Try again later."),
        ]
        for row in cases {
            let fake = FakeZotero()
            fake.failure = row.error
            if let status = row.status {
                fake.replies["/groups/2205533/collections/DMKBHP6P/items/top#0"] = PaperFetchReply(status: status, data: Data("{}".utf8))
            }
            let store = try store()
            let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
            let outcome = await following.follow(pasted: Self.groupLink, apiKey: nil, zoteroConnected: false, now: date(0))
            XCTAssertEqual(outcome, .rejected(row.message), "\(row)")
            XCTAssertEqual(try store.loadPaperSources(), [], "\(row)")
        }
    }

    func testAPageThatIsNotZoterosJSONIsUnreachableNotAnEmptyList() async throws {
        let fake = FakeZotero()
        fake.replies["/groups/2205533/collections/DMKBHP6P/items/top#0"] = PaperFetchReply(status: 200, data: Data("<html>Sign in</html>".utf8))
        do {
            _ = try await PaperSourceFetcher(transport: fake.transport).fetch(Self.source, apiKey: nil)
            XCTFail("an HTML page is not a list")
        } catch {
            XCTAssertEqual(error, .unreachable)
        }
    }

    func testAFailedAttachmentsPageOrNameLeavesThePapers() async throws {
        let fake = try realZotero()
        fake.replies["/groups/2205533/collections/DMKBHP6P/items?itemType=attachment#0"] = PaperFetchReply(status: 500, data: Data())
        fake.replies["/groups/2205533/collections/DMKBHP6P"] = PaperFetchReply(status: 500, data: Data())
        let snapshot = try await PaperSourceFetcher(transport: fake.transport).fetch(Self.source, apiKey: nil)
        XCTAssertEqual(snapshot.entries.count, 24)
        XCTAssertNil(snapshot.title)
        XCTAssertNil(snapshot.entries.first { $0.id.hasSuffix("JA3W6QNM") }?.storedPDFAttachmentKey, "no attachments, no stored file")
    }

    func testALongListIsReadAHundredAtATimeAndStopsAt500() async throws {
        // Paging only: the rows are the real fixture's, given new keys so that each page holds different papers.
        let real = try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture("zotero-group-collection")) as? [[String: Any]])
        func page(_ number: Int) throws -> Data {
            let rows = (0..<100).map { index -> [String: Any] in
                var row = real[index % 24]
                let key = String(format: "K%03d%04d", number, index)
                row["key"] = key
                var data = row["data"] as? [String: Any] ?? [:]
                data["key"] = key
                data["title"] = "Paper \(key)"
                data["dateAdded"] = String(format: "2020-01-%02dT00:00:00Z", 28 - number)
                row["data"] = data
                return row
            }
            return try JSONSerialization.data(withJSONObject: rows)
        }
        let fake = FakeZotero()
        for number in 0..<7 {
            fake.replies["/groups/2205533/collections/DMKBHP6P/items/top#\(number * 100)"] = PaperFetchReply(
                status: 200, data: try page(number), totalResults: 1_000)
        }
        let snapshot = try await PaperSourceFetcher(transport: fake.transport).fetch(Self.source, apiKey: nil)
        XCTAssertEqual(fake.requests.filter { $0.url!.path.hasSuffix("/items/top") }.count, 5)
        XCTAssertEqual(snapshot.entries.count, 500)
        XCTAssertEqual(snapshot.totalCount, 1_000)
        XCTAssertTrue(snapshot.entries.first!.id.contains("K000"), "the newest page first")
    }

    // MARK: Refresh, opening, Quiet, unfollow

    func testANewPaperCountsAsNewUntilTheListIsOpened() async throws {
        let fake = try realZotero()
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        // Followed before the newest paper joined: two of the fixture's papers carry a dateAdded after this.
        let followedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2018-11-08T20:39:22Z"))
        guard case .followed(let record) = await following.follow(pasted: Self.groupLink, apiKey: nil, zoteroConnected: false, now: followedAt)
        else { return XCTFail() }
        let joinedAfter = record.entries.filter { ($0.dateJoined ?? .distantPast) > followedAt }.count
        XCTAssertGreaterThan(joinedAfter, 0)
        XCTAssertEqual(PaperSourceRow(record: record).newCount, joinedAfter)
        XCTAssertEqual(PaperSourceRow(record: record).detail, "Zotero · \(joinedAfter) new \(joinedAfter == 1 ? "paper" : "papers")")
        let opened = try XCTUnwrap(try following.markOpened(id: record.id, now: date(0)))
        XCTAssertEqual(PaperSourceRow(record: opened).detail, "Zotero · 25 papers")
        // A refresh after the opening keeps the opening, and Quiet set meanwhile.
        try following.setQuiet(id: record.id, true)
        guard case .success(let refreshed) = await following.refresh(record, apiKey: nil, now: date(10)) else { return XCTFail() }
        XCTAssertEqual(refreshed.lastOpenedAt, date(0))
        XCTAssertTrue(refreshed.isQuiet)
        XCTAssertEqual(refreshed.lastRefreshedAt, date(10))
        XCTAssertEqual(PaperSourceRow(record: refreshed).newCount, 0, "a Quiet list counts nothing new")
    }

    func testAFailedRefreshLeavesTheStoredListAsItWas() async throws {
        let fake = try realZotero()
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        guard case .followed(let record) = await following.follow(pasted: Self.groupLink, apiKey: nil, zoteroConnected: false, now: date(0))
        else { return XCTFail() }
        fake.failure = URLError(.notConnectedToInternet)
        let result = await following.refresh(record, apiKey: nil, now: date(10))
        XCTAssertEqual(result, .failure(.offline))
        XCTAssertEqual(try store.loadPaperSources(), [record], "the last snapshot stays")
    }

    func testRefreshOfAnUnfollowedListDoesNotBringItBack() async throws {
        let fake = try realZotero()
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        guard case .followed(let record) = await following.follow(pasted: Self.groupLink, apiKey: nil, zoteroConnected: false, now: date(0))
        else { return XCTFail() }
        try following.unfollow(id: record.id)
        _ = await following.refresh(record, apiKey: nil, now: date(10))
        XCTAssertEqual(try store.loadPaperSources(), [])
    }

    func testUnfollowAndUndo() async throws {
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: try realZotero().transport))
        guard case .followed(let record) = await following.follow(pasted: Self.groupLink, apiKey: nil, zoteroConnected: false, now: date(0))
        else { return XCTFail() }
        let removed = try XCTUnwrap(try following.unfollow(id: record.id))
        XCTAssertEqual(try store.loadPaperSources(), [])
        try following.restore(removed)
        XCTAssertEqual(try store.loadPaperSources(), [record])
        XCTAssertEqual(try SQLiteSessionStore(path: lastStorePath).loadPaperSources(), [record], "and after a relaunch")
    }

    func testWhichListsAreDue() {
        func record(_ source: PaperSource, refreshed: Double?) -> PaperSourceRecord {
            PaperSourceRecord(source: source, link: "", title: "t", followedAt: date(0), lastRefreshedAt: refreshed.map(date))
        }
        let fresh = record(Self.source, refreshed: 100)
        let stale = record(.zoteroGroup(groupID: 1, collectionKey: nil), refreshed: 100 - PaperSourceFollowing.refreshInterval)
        let never = record(.zoteroGroup(groupID: 2, collectionKey: nil), refreshed: nil)
        let own = record(.zoteroUser(userID: 3, collectionKey: nil), refreshed: nil)
        let future = record(.zoteroGroup(groupID: 4, collectionKey: nil), refreshed: 9_999)
        let all = [fresh, stale, never, own, future]
        XCTAssertEqual(PaperSourceFollowing.due(all, keyConnected: false, now: date(100), pulled: false).map(\.id),
                       [stale.id, never.id, future.id], "a clock set back counts as due")
        XCTAssertEqual(PaperSourceFollowing.due(all, keyConnected: true, now: date(100), pulled: false).map(\.id),
                       [stale.id, never.id, own.id, future.id])
        XCTAssertEqual(PaperSourceFollowing.due(all, keyConnected: false, now: date(100), pulled: true).count, 4, "a pull reads all but the keyless own library")
    }

    // MARK: The listener's own library and the key

    private func ownLibrary() throws -> FakeZotero {
        let fake = FakeZotero()
        // The same real JSON, served at the listener's own library's addresses.
        fake.replies["/users/42/collections/DMKBHP6P/items/top#0"] = PaperFetchReply(status: 200, data: try fixture("zotero-group-collection"), totalResults: 25)
        fake.replies["/users/42/collections/DMKBHP6P/items?itemType=attachment#0"] = PaperFetchReply(status: 200, data: try fixture("zotero-group-attachments"))
        fake.replies["/users/42/collections/DMKBHP6P"] = PaperFetchReply(status: 200, data: try fixture("zotero-api/collection-record"))
        fake.replies["/users/42/collections#0"] = PaperFetchReply(status: 200, data: try fixture("zotero-api/group-collections"))
        return fake
    }

    func testOwnLibraryRequestsCarryTheKeyInAHeaderAndStoredPDFsBecomeReachable() async throws {
        let fake = try ownLibrary()
        let following = PaperSourceFollowing(store: try store(), fetcher: PaperSourceFetcher(transport: fake.transport))
        let source = PaperSource.zoteroUser(userID: 42, collectionKey: "DMKBHP6P")
        let outcome = await following.follow(source: source, link: source.pageURL().absoluteString, apiKey: Self.knownKey,
                                             zoteroConnected: true, now: date(0))
        guard case .followed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(fake.requests.allSatisfy { $0.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader) == Self.knownKey })
        XCTAssertTrue(fake.requests.allSatisfy { !($0.url!.absoluteString.contains(Self.knownKey)) }, "never in an address")
        let thesis = try XCTUnwrap(record.entries.first { $0.id == "zotero:user:42:JA3W6QNM" })
        XCTAssertEqual(thesis.status, .pdf, "a stored file of the listener's own library can be fetched")
        XCTAssertEqual(PaperEntryImportRoute.route(for: thesis, existingItemId: nil), .storedPDF(attachmentKey: "5B74JAMI"))
    }

    func testARevokedKeySaysSoAndConnectChecksTheKey() async throws {
        let fake = try ownLibrary()
        fake.replies["/users/42/collections#0"] = PaperFetchReply(status: 403, data: Data("Invalid key".utf8))
        do {
            _ = try await PaperSourceFetcher(transport: fake.transport).collections(userID: 42, apiKey: Self.knownKey)
            XCTFail("a refused key is an error")
        } catch {
            XCTAssertEqual(error, .keyRefused)
            XCTAssertEqual(error.message(zoteroConnected: true), "Zotero didn't accept that key.")
        }
    }

    func testYourCollectionsAreTheLibrarysCollectionsByName() async throws {
        let fake = try ownLibrary()
        let (name, collections) = try await PaperSourceFetcher(transport: fake.transport).collections(userID: 42, apiKey: Self.knownKey)
        XCTAssertEqual(name, "Test Items Library", "the library's own name, from its records")
        XCTAssertEqual(collections.count, 12)
        XCTAssertEqual(collections.first?.name, "AMA, 11th edition")
        XCTAssertEqual(collections.first { $0.key == "QW4JGG9G" }?.itemCount, 71)
        XCTAssertEqual(collections.map(\.name), collections.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertTrue(collections.allSatisfy { $0.parentKey == nil }, "top-level collections answer `false`, read as none")
    }

    /// Slice 3 of the issue: the key never enters a log line or a diagnostics export. Everything this code hands back
    /// (records, problems, messages, the text a log would print of them) is searched for a known key.
    func testTheKeyNeverAppearsInAnythingThisCodeReturns() async throws {
        let fake = try ownLibrary()
        let store = try store()
        let following = PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: fake.transport))
        let source = PaperSource.zoteroUser(userID: 42, collectionKey: "DMKBHP6P")
        var texts: [String] = []
        let followed = await following.follow(source: source, link: source.pageURL().absoluteString, apiKey: Self.knownKey, zoteroConnected: true, now: date(0))
        texts.append(String(describing: followed))
        guard case .followed(let record) = followed else { return XCTFail() }
        texts.append(String(decoding: try JSONEncoder().encode(record), as: UTF8.self))
        for status in [403, 404, 429, 500] {
            fake.replies["/users/42/collections/DMKBHP6P/items/top#0"] = PaperFetchReply(status: status, data: Data("Invalid key \(Self.knownKey)".utf8))
            let result = await following.refresh(record, apiKey: Self.knownKey, now: date(1))
            texts.append(String(describing: result))
            if case .failure(let problem) = result {
                texts.append(problem.message(zoteroConnected: true))
                texts.append(problem.localizedDescription)
            }
        }
        fake.failure = URLError(.timedOut)
        texts.append(String(describing: await following.refresh(record, apiKey: Self.knownKey, now: date(2))))
        texts += try store.loadPaperSources().map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        for text in texts { XCTAssertFalse(text.contains(Self.knownKey), text) }
        XCTAssertEqual(fake.requests.compactMap { $0.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader) }.count, fake.requests.count)
    }

    func testTheKeyGoesOnlyToZoterosAPIHostAndIsDroppedOnARedirectAway() throws {
        let own = ZoteroPaperAPI.request(ZoteroPaperAPI.fileURL(userID: 42, attachmentKey: "5B74JAMI"), apiKey: Self.knownKey)
        XCTAssertEqual(own.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader), Self.knownKey)
        for address in [
            "https://api.zotero.org/groups/1/items/top",
            "http://api.zotero.org/users/42/items",
            "https://api.zotero.org.evil.example/users/42/items",
            "https://example.com/users/42/items",
        ] {
            let request = ZoteroPaperAPI.request(URL(string: address)!, apiKey: Self.knownKey)
            XCTAssertNil(request.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader), address)
        }
        var away = own
        away.url = URL(string: "https://zoterofilestorage.s3.amazonaws.com/abc?signature=1")
        let followed = try XCTUnwrap(ZoteroPaperAPI.redirectRequest(away))
        XCTAssertNil(followed.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader), "the key never leaves Zotero's API host")
        var insecure = own
        insecure.url = URL(string: "http://example.com/file.pdf")
        XCTAssertNil(ZoteroPaperAPI.redirectRequest(insecure), "a hop off https is refused")
        let stays = try XCTUnwrap(ZoteroPaperAPI.redirectRequest(own))
        XCTAssertEqual(stays.value(forHTTPHeaderField: ZoteroPaperAPI.keyHeader), Self.knownKey)
    }
}
