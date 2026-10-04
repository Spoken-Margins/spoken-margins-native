import XCTest
import SessionKit
import SessionKitFeeds
import SessionKitPersistence
@testable import SpokenMarginsApp

/// #463: the OPML import screen's model, over the real follow path (`FollowedSourceCoordinator.followFeed`,
/// the same call the drawer and the app make) and a real SQLite store, with feeds served by a URLProtocol.
@MainActor
final class OPMLImportTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private var coordinator: FollowedSourceCoordinator!
    private var refreshCount = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("opml-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OPMLFeedsURLProtocol.self]
        coordinator = FollowedSourceCoordinator(repository: store, session: URLSession(configuration: configuration))
        OPMLFeedsURLProtocol.reset()
        refreshCount = 0
    }

    override func tearDown() async throws {
        coordinator = nil
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeImporter() -> OPMLImportModel {
        OPMLImportModel(
            subscriptions: { [store] in (try? store?.loadFeedSubscriptions()) ?? [] },
            follow: { [coordinator] feedURL in _ = try await coordinator!.followFeed(urlString: feedURL) },
            didFollow: { [weak self] in self?.refreshCount += 1 }
        )
    }

    /// The already-followed show, muted, with one inbox entry dismissed: re-import must leave all of that alone.
    private func followMutedShowWithADismissedEntry() async throws -> FeedSubscription {
        let subscription = try await coordinator.followFeed(urlString: "https://feeds.example.com/followed.xml")
        try await coordinator.setMuted(subscriptionId: subscription.id, muted: true)
        let entry = try XCTUnwrap(try store.loadFeedEntries(subscriptionId: subscription.id).first)
        try await coordinator.setEntryState(id: entry.id, state: .dismissed)
        return subscription
    }

    private func preview(_ importer: OPMLImportModel) throws -> OPMLImportPreview {
        guard case .preview(let preview) = importer.phase else {
            XCTFail("Expected a preview, got \(importer.phase)")
            throw CancellationError()
        }
        return preview
    }

    func testImportFollowsOnlyTickedFeedsAndReimportAddsNothing() async throws {
        let followed = try await followMutedShowWithADismissedEntry()
        let entriesBefore = try store.loadFeedEntries(subscriptionId: followed.id)

        let importer = makeImporter()
        importer.load(data: Data(Self.mixedOPML.utf8))
        let first = try preview(importer)
        XCTAssertEqual(first.toFollow.map(\.title), ["Pod One", "Pod Two", "Pod Three", "A Blog"])
        XCTAssertEqual(first.alreadyFollowed.map(\.title), ["Followed Show"])
        XCTAssertEqual(first.duplicatesInFile.map(\.title), ["Pod One again"])
        XCTAssertEqual(first.unusableOutlineCount, 1)
        XCTAssertEqual(importer.selected.count, 4, "every new feed is ticked by default")

        importer.setSelected(try XCTUnwrap(first.toFollow.first { $0.title == "Pod Two" }), false)
        await importer.followSelected()

        guard case .finished(let result) = importer.phase else { return XCTFail("\(importer.phase)") }
        XCTAssertEqual(result.followed.map(\.title), ["Pod One", "Pod Three", "A Blog"])
        XCTAssertTrue(result.failed.isEmpty)
        let subscriptions = try store.loadFeedSubscriptions()
        XCTAssertEqual(subscriptions.count, 4, "the followed show plus exactly 3")
        XCTAssertEqual(Set(subscriptions.map(\.source.canonicalURL)), [
            "https://feeds.example.com/followed.xml", "https://feeds.example.com/pod1.xml",
            "https://feeds.example.com/pod3.xml", "https://feeds.example.com/blog.xml",
        ])
        XCTAssertEqual(subscriptions.first { $0.source.canonicalURL.hasSuffix("/blog.xml") }?.source.kind, .articleFeed)
        XCTAssertEqual(refreshCount, 1, "one refresh after the import, not one per feed")

        // Again, ticking the one left out: it follows, and nothing else changes.
        let second = makeImporter()
        second.load(data: Data(Self.mixedOPML.utf8))
        XCTAssertEqual(try preview(second).toFollow.map(\.title), ["Pod Two"])
        await second.followSelected()

        // A third time everything is already followed and nothing is added.
        let third = makeImporter()
        third.load(data: Data(Self.mixedOPML.utf8))
        let last = try preview(third)
        XCTAssertTrue(last.toFollow.isEmpty)
        XCTAssertEqual(last.alreadyFollowed.count, 5)
        await third.followSelected()
        XCTAssertEqual(try store.loadFeedSubscriptions().count, 5)

        let show = try XCTUnwrap(try store.loadFeedSubscriptions().first { $0.id == followed.id })
        XCTAssertEqual(show.state, .muted, "re-import leaves a muted show muted")
        XCTAssertEqual(try store.loadFeedEntries(subscriptionId: followed.id), entriesBefore, "and its inbox entries as they were")

        XCTAssertEqual(try store.listItems(includeDeleted: true).count, 0, "nothing is added to the Library")
        XCTAssertTrue(try store.loadAudioPreparationJobs().isEmpty, "nothing is prepared")
        XCTAssertTrue(try store.loadPreparedAudioManifests().isEmpty)
        XCTAssertFalse(OPMLFeedsURLProtocol.requestedPaths.contains { $0.hasSuffix(".mp3") }, "nothing is downloaded")
    }

    func testCancelAtThePreviewFollowsNothing() async throws {
        let importer = makeImporter()
        importer.load(data: Data(Self.mixedOPML.utf8))
        _ = try preview(importer)
        importer.cancel()
        XCTAssertEqual(importer.phase, .choosing)
        await importer.followSelected()
        XCTAssertTrue(try store.loadFeedSubscriptions().isEmpty)
        XCTAssertTrue(OPMLFeedsURLProtocol.requestedPaths.isEmpty, "not one feed was fetched")
        XCTAssertEqual(refreshCount, 0)
    }

    func testAFeedThatFailsIsListedWithItsReasonAndTheRestStillFollow() async throws {
        let importer = makeImporter()
        importer.load(data: Data(Self.brokenFeedOPML.utf8))
        await importer.followSelected()
        guard case .finished(let result) = importer.phase else { return XCTFail("\(importer.phase)") }
        XCTAssertEqual(result.followed.map(\.title), ["Pod One", "Pod Three"])
        XCTAssertEqual(result.failed.map(\.candidate.title), ["Gone"])
        XCTAssertFalse(result.failed[0].reason.isEmpty)
        XCTAssertEqual(try store.loadFeedSubscriptions().count, 2)
    }

    func testAFileThatIsNotOPMLSaysSoAndChangesNothing() async throws {
        let importer = makeImporter()
        importer.load(data: Data("<html><body>Not a subscription list</body></html>".utf8))
        guard case .failed(let message) = importer.phase else { return XCTFail("\(importer.phase)") }
        XCTAssertTrue(message.contains("isn't an OPML file"), message)
        XCTAssertTrue(try store.loadFeedSubscriptions().isEmpty)
    }

    /// 3 podcasts, 1 blog, 1 repeat, 1 outline with no feed link, 1 show already followed.
    static let mixedOPML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0">
      <head><title>My old app</title></head>
      <body>
        <outline text="Podcasts">
          <outline type="rss" text="Pod One" xmlUrl="https://feeds.example.com/pod1.xml"/>
          <outline type="rss" text="Pod Two" xmlUrl="https://feeds.example.com/pod2.xml"/>
          <outline type="rss" text="Pod Three" xmlUrl="https://feeds.example.com/pod3.xml"/>
          <outline type="rss" text="Followed Show" xmlUrl="https://feeds.example.com/followed.xml"/>
        </outline>
        <outline type="rss" text="A Blog" xmlUrl="https://feeds.example.com/blog.xml"/>
        <outline type="rss" text="Pod One again" xmlUrl="https://feeds.example.com/pod1.xml/"/>
        <outline type="rss" text="Broken, no link"/>
      </body>
    </opml>
    """

    static let brokenFeedOPML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="2.0"><head><title>Some gone</title></head><body>
      <outline type="rss" text="Pod One" xmlUrl="https://feeds.example.com/pod1.xml"/>
      <outline type="rss" text="Gone" xmlUrl="https://feeds.example.com/gone.xml"/>
      <outline type="rss" text="Pod Three" xmlUrl="https://feeds.example.com/pod3.xml"/>
    </body></opml>
    """
}

/// Serves small RSS feeds on feeds.example.com. /blog.xml has no enclosures; /gone.xml is a 404.
private final class OPMLFeedsURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []

    static func reset() { lock.withLock { paths = [] } }
    static var requestedPaths: [String] { lock.withLock { paths } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "feeds.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        Self.lock.withLock { Self.paths.append(path) }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".xml", with: "")
        let status = name == "gone" ? 404 : 200
        let items = (1...3).map { number in
            let enclosure = name == "blog" ? "" : #"<enclosure url="https://cdn.example.com/\#(name)-\#(number).mp3" type="audio/mpeg" length="1000"/>"#
            return """
            <item><title>\(name) episode \(number)</title><link>https://example.com/\(name)/\(number)</link>
            <guid>\(name)-\(number)</guid><pubDate>Tue, 0\(number) Sep 2026 12:00:00 GMT</pubDate>\(enclosure)</item>
            """
        }.joined()
        let body = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>\(name)</title><link>https://example.com/\(name)</link>\(items)</channel></rss>
        """.utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/rss+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
