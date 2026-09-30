import Foundation
import XCTest
@testable import SessionKit

/// Recorded responses per URL; anything unrecorded behaves like an unreachable server.
private final class RecordedServer: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: (Int, Data)] = [:]
    private var requested: [URL] = []

    func respond(_ url: URL, status: Int = 200, _ body: Data) {
        lock.withLock { responses[url] = (status, body) }
    }

    func goOffline() { lock.withLock { responses = [:] } }

    var requests: [URL] { lock.withLock { requested } }

    func fetch(_ url: URL, _ maximumBytes: Int) async throws -> (status: Int, body: Data) {
        try lock.withLock {
            requested.append(url)
            guard let (status, body) = responses[url] else { throw URLError(.notConnectedToInternet) }
            // Like the app's fetch: a body over the cap is an error.
            guard body.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return (status, body)
        }
    }
}

final class BridgeManifestStoreTests: XCTestCase {
    private let policy = BridgeManifestPolicy.production
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private var temporary: URL!
    private var server: RecordedServer!

    static let manifestJSON = Data(#"""
    {
      "schema": "spokenmargins.bridge-manifest",
      "version": 1,
      "generatedAt": "2026-09-28T12:00:00Z",
      "futureField": {"ignored": true},
      "sources": [
        {
          "id": "example-essays",
          "title": "Example Essays",
          "homepage": "https://essays.example.org/",
          "match": { "hosts": ["essays.example.org"], "pathPrefixes": ["/p/"] },
          "status": "active",
          "checkedAt": "2026-09-28T11:40:00Z",
          "updatedAt": "2026-09-27T10:00:00Z",
          "items": [
            { "url": "https://essays.example.org/p/on-margins", "title": "On margins", "publishedAt": "2026-09-27T09:00:00Z", "firstSeenAt": "2026-09-27T10:00:00Z" },
            { "url": "https://tracker.example.net/p/x", "title": "Off the source's hosts", "firstSeenAt": "2026-09-27T10:00:00Z" },
            { "url": "http://essays.example.org/p/plain", "title": "Plain http", "firstSeenAt": "2026-09-27T10:00:00Z" }
          ],
          "recipe": { "version": 1, "extract": "selectors", "content": ["article .post-body"], "remove": [".subscribe-box"], "title": "h1.post-title",
                      "published": { "selector": "time[datetime]", "attribute": "datetime" } }
        },
        {
          "id": "lab-notes",
          "title": "Lab Notes",
          "homepage": "https://www.lab.example.com/notes",
          "match": { "hosts": ["www.lab.example.com", "lab.example.com"] },
          "status": "active",
          "checkedAt": "2026-09-28T11:45:00Z",
          "updatedAt": "2026-09-26T08:15:00Z",
          "items": [ { "url": "https://www.lab.example.com/notes/field-report", "title": "Field report", "firstSeenAt": "2026-09-26T08:15:00Z" } ],
          "recipe": { "version": 2, "extract": "some-future-mode", "content": ["main"] }
        },
        {
          "id": "watches-us",
          "title": "Lists our own domain as a host",
          "homepage": "https://blog.example.com/",
          "match": { "hosts": ["blog.example.com", "spokenmargins.proximitytoprogress.com"] },
          "status": "active",
          "checkedAt": "2026-09-28T11:45:00Z",
          "updatedAt": "2026-09-26T08:15:00Z",
          "items": [],
          "recipe": { "version": 1, "extract": "readable" }
        },
        {
          "id": "injected-selector",
          "title": "Selector that would break out of a script string",
          "homepage": "https://news.example.com/",
          "match": { "hosts": ["news.example.com"] },
          "status": "someday",
          "checkedAt": "2026-09-28T11:45:00Z",
          "updatedAt": "2026-09-26T08:15:00Z",
          "items": [],
          "recipe": { "version": 1, "extract": "selectors", "content": ["h1`);fetch(`x"] }
        }
      ]
    }
    """#.utf8)

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        server = RecordedServer()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    private func store(build: Int = 40) -> BridgeManifestStore {
        let server = self.server!
        return BridgeManifestStore(cacheDirectory: temporary, appBuild: build, policy: policy) { url, maximumBytes in
            try await server.fetch(url, maximumBytes)
        }
    }

    private func serveConfig(_ data: Data = ServerConfigTests.configJSON(), status: Int = 200) {
        server.respond(policy.configURL, status: status, data)
    }

    private func serveManifest(_ data: Data = BridgeManifestStoreTests.manifestJSON) {
        server.respond(policy.manifestURL, data)
    }

    // MARK: The server unreachable

    func testWithTheServerUnreachableFromFirstLaunchTheBridgeIsOffAndNothingThrows() async {
        let store = store()
        let outcome = await store.refresh(now: start)
        XCTAssertEqual(outcome, .off(.noConfig))
        let snapshot = await store.current(now: start)
        XCTAssertEqual(snapshot.state, .off(.noConfig))
        XCTAssertNil(snapshot.manifest)
        XCTAssertFalse(snapshot.isUpdating)
        XCTAssertEqual(server.requests, [policy.configURL], "no manifest request while the bridge is off")
    }

    func testAnOutageKeepsTheCachedBridgeForAWeekThenSwitchesItOff() async {
        serveConfig()
        serveManifest()
        let store = store()
        guard case .updated = await store.refresh(now: start) else { return XCTFail("first refresh should update") }
        server.goOffline()

        let dayLater = start.addingTimeInterval(24 * 3_600)
        guard case .failed(.network) = await store.refresh(now: dayLater) else { return XCTFail("manifest fetch should fail offline") }
        let stillOn = await store.current(now: dayLater)
        XCTAssertTrue(stillOn.isUpdating, "a short outage keeps the last verified manifest")

        let eightDaysLater = start.addingTimeInterval(8 * 24 * 3_600)
        let outcome = await store.refresh(now: eightDaysLater)
        XCTAssertEqual(outcome, .off(.staleConfig))
        let off = await store.current(now: eightDaysLater)
        XCTAssertNil(off.manifest)
        XCTAssertFalse(off.isUpdating)
    }

    func testAServerErrorIsAnOutageButA404MeansTheConfigIsGone() async {
        serveConfig()
        serveManifest()
        let store = store()
        _ = await store.refresh(now: start)
        serveConfig(Data("oops".utf8), status: 503)
        let afterError = await store.refresh(now: start.addingTimeInterval(60))
        XCTAssertEqual(afterError, .unchanged, "503 keeps the held config; the manifest is re-checked")
        serveConfig(Data(), status: 404)
        let afterGone = await store.refresh(now: start.addingTimeInterval(120))
        XCTAssertEqual(afterGone, .off(.noConfig))
    }

    // MARK: The kill switch

    func testSwitchingTheBridgeOffStopsServingTheManifestAndStopsFetchingIt() async {
        serveConfig()
        serveManifest()
        let store = store()
        _ = await store.refresh(now: start)
        serveConfig(ServerConfigTests.configJSON(serial: 4, bridge: #"{"enabled":false}"#))
        let before = server.requests.count
        let outcome = await store.refresh(now: start.addingTimeInterval(60))
        XCTAssertEqual(outcome, .off(.switchedOff))
        XCTAssertEqual(Array(server.requests.dropFirst(before)), [policy.configURL], "the manifest is not fetched when off")
        let snapshot = await store.current(now: start.addingTimeInterval(60))
        XCTAssertNil(snapshot.manifest, "the cached manifest is not served while off")
    }

    func testAMalformedConfigSwitchesTheBridgeOff() async {
        serveConfig()
        serveManifest()
        let store = store()
        _ = await store.refresh(now: start)
        serveConfig(Data("<html>maintenance</html>".utf8))
        let outcome = await store.refresh(now: start.addingTimeInterval(60))
        XCTAssertEqual(outcome, .off(.malformedConfig))
    }

    func testAnOversizedConfigIsMalformedNotAnOutage() async {
        serveConfig(ServerConfigTests.configJSON(extra: #","padding":"\#(String(repeating: "x", count: 20_000))""#))
        let outcome = await store().refresh(now: start)
        XCTAssertEqual(outcome, .off(.malformedConfig))
    }

    func testMinimumBuildSwitchesOffOlderBuildsOnly() async {
        serveConfig(ServerConfigTests.configJSON(bridge: #"{"enabled":true,"minimumBuild":41}"#))
        serveManifest()
        let old = await store(build: 40).refresh(now: start)
        XCTAssertEqual(old, .off(.buildTooOld(minimumBuild: 41)))
        try? FileManager.default.removeItem(at: temporary)
        guard case .updated = await store(build: 41).refresh(now: start) else { return XCTFail("build 41 should update") }
    }

    func testTheCacheSurvivesARelaunchAndACorruptCacheFailsClosed() async throws {
        serveConfig()
        serveManifest()
        _ = await store().refresh(now: start)
        server.goOffline()
        let relaunched = await store().current(now: start.addingTimeInterval(60))
        XCTAssertTrue(relaunched.isUpdating)
        XCTAssertEqual(relaunched.manifest?.sources.map(\.id), ["example-essays", "lab-notes", "injected-selector"])

        try Data("not json".utf8).write(to: temporary.appendingPathComponent("server-config.json"))
        let corrupt = await store().current(now: start.addingTimeInterval(60))
        XCTAssertEqual(corrupt.state, .off(.malformedConfig))
    }

    // MARK: The manifest

    func testABadManifestKeepsTheOneAlreadyVerified() async {
        serveConfig()
        serveManifest()
        let store = store()
        _ = await store.refresh(now: start)
        serveManifest(Data(#"{"schema":"spokenmargins.bridge-manifest","version":2,"sources":[]}"#.utf8))
        let outcome = await store.refresh(now: start.addingTimeInterval(60))
        XCTAssertEqual(outcome, .failed(.malformedManifest))
        let snapshot = await store.current(now: start.addingTimeInterval(60))
        XCTAssertEqual(snapshot.manifest?.sources.count, 3)
        let same = await store.refresh(now: start.addingTimeInterval(120))
        XCTAssertEqual(same, .failed(.malformedManifest))
    }

    func testTheManifestIsFetchedOnlyFromThePinnedHost() async {
        serveConfig()
        serveManifest()
        var untrusted = policy
        untrusted.manifestURL = URL(string: "https://elsewhere.example.com/bridge/v1/manifest.json")!
        let server = self.server!
        let store = BridgeManifestStore(cacheDirectory: temporary, appBuild: 40, policy: untrusted) { url, max in try await server.fetch(url, max) }
        let outcome = await store.refresh(now: start)
        XCTAssertEqual(outcome, .failed(.untrustedURL))
        XCTAssertFalse(server.requests.contains(untrusted.manifestURL))
    }

    func testSanitizingDropsWhatThePhoneMustNotActOn() throws {
        let manifest = try BridgeManifestVerifier.manifest(from: Self.manifestJSON)
        XCTAssertNil(manifest.source(id: "watches-us"), "a source listing our own domain as a host is dropped")

        let essays = try XCTUnwrap(manifest.source(id: "example-essays"))
        XCTAssertEqual(essays.items.map(\.url), ["https://essays.example.org/p/on-margins"], "off-host and plain-http items are dropped")
        XCTAssertEqual(essays.recipe.extract, .selectors)

        let lab = try XCTUnwrap(manifest.source(id: "lab-notes"))
        XCTAssertEqual(lab.recipe, .readable, "a newer recipe version falls back to the bundled extractor")

        let injected = try XCTUnwrap(manifest.source(id: "injected-selector"))
        XCTAssertEqual(injected.recipe, .readable, "a selector with script-breaking characters is never used")
        XCTAssertEqual(injected.status, .paused, "an unknown status is shown but not updated")
    }

    func testMatchingASharedLinkIsLocal() throws {
        let manifest = try BridgeManifestVerifier.manifest(from: Self.manifestJSON)
        XCTAssertEqual(manifest.source(matching: URL(string: "https://Essays.Example.org/p/new-post")!)?.id, "example-essays")
        XCTAssertNil(manifest.source(matching: URL(string: "https://essays.example.org/about")!), "outside the path prefixes")
        XCTAssertNil(manifest.source(matching: URL(string: "http://essays.example.org/p/new-post")!), "https only")
        XCTAssertEqual(manifest.source(matching: URL(string: "https://lab.example.com/anything")!)?.id, "lab-notes")
        XCTAssertNil(manifest.source(matching: URL(string: "https://unknown.example.org/p/x")!))
    }

    func testAnOversizedManifestIsRefused() {
        XCTAssertThrowsError(try BridgeManifestVerifier.manifest(from: Data(count: BridgeManifestVerifier.maximumBytes + 1))) { error in
            XCTAssertEqual(error as? BridgeManifestError, .oversized)
        }
    }
}
