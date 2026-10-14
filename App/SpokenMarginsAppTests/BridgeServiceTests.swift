import XCTest
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class BridgeServiceTests: XCTestCase {
    func testUnavailableStoreFailsClosed() async {
        let service = BridgeService(store: nil)
        let snapshot = await service.current()
        XCTAssertEqual(snapshot.state, .off(.noConfig))
        XCTAssertNil(snapshot.manifest)
        let outcome = await service.refresh()
        XCTAssertEqual(outcome, .off(.noConfig))
    }

    func testUnreachableServerDoesNotEscapeIntoTheApp() async {
        let cache = FileManager.default.temporaryDirectory.appending(path: "bridge-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = BridgeManifestStore(cacheDirectory: cache, appBuild: 30) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let service = BridgeService(store: store)
        let outcome = await service.refresh()
        XCTAssertEqual(outcome, .off(.noConfig))
        let snapshot = await service.current()
        XCTAssertFalse(snapshot.isUpdating)
        XCTAssertNil(snapshot.manifest)
    }

    // MARK: Delegation (APM-15)

    /// Both tests above expect `.off(.noConfig)`, which is also what the service returns by itself when it
    /// has no store. These give it a store that has something to say, so a service that ignored its store
    /// (or its `now`) is seen.

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let policy = BridgeManifestPolicy.production

    private let configJSON = Data(#"{"schema":"spokenmargins.server-config","version":1,"serial":3,"checkAfterSeconds":21600,"services":{"attest":{"enabled":true},"bridge":{"enabled":true}}}"#.utf8)

    private let manifestJSON = Data(#"""
    {
      "schema": "spokenmargins.bridge-manifest",
      "version": 1,
      "generatedAt": "2026-09-28T12:00:00Z",
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
            { "url": "https://essays.example.org/p/on-margins", "title": "On margins", "firstSeenAt": "2026-09-27T10:00:00Z" }
          ],
          "recipe": { "version": 1, "extract": "readable" }
        }
      ]
    }
    """#.utf8)

    /// Serves the config and manifest, or behaves like an unreachable server once taken offline.
    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var online = true
        private var responses: [URL: Data] = [:]
        init(_ responses: [URL: Data]) { self.responses = responses }
        func goOffline() { lock.withLock { online = false } }
        func fetch(_ url: URL, _ maximumBytes: Int) async throws -> (status: Int, body: Data) {
            try lock.withLock {
                guard online, let body = responses[url] else { throw URLError(.notConnectedToInternet) }
                return (200, body)
            }
        }
    }

    private func makeService(_ server: Server) -> (BridgeService, URL) {
        let cache = FileManager.default.temporaryDirectory.appending(path: "bridge-app-\(UUID().uuidString)")
        let store = BridgeManifestStore(cacheDirectory: cache, appBuild: 30, policy: policy) { url, maximumBytes in
            try await server.fetch(url, maximumBytes)
        }
        return (BridgeService(store: store), cache)
    }

    func testRefreshAndCurrentReportWhatTheStoreFetched() async {
        let server = Server([policy.configURL: configJSON, policy.manifestURL: manifestJSON])
        let (service, cache) = makeService(server)
        defer { try? FileManager.default.removeItem(at: cache) }

        let outcome = await service.refresh(now: start)
        XCTAssertEqual(outcome, .updated(sourceCount: 1))
        let snapshot = await service.current(now: start)
        XCTAssertEqual(snapshot.state, .on)
        XCTAssertTrue(snapshot.isUpdating)
        XCTAssertEqual(snapshot.manifest?.sources.map(\.id), ["example-essays"])
    }

    func testTheServicePassesItsClockToTheStore() async {
        let server = Server([policy.configURL: configJSON, policy.manifestURL: manifestJSON])
        let (service, cache) = makeService(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = await service.refresh(now: start)

        // The wall clock is long past the config's one-week limit; the clock handed in decides.
        let dayLater = await service.current(now: start.addingTimeInterval(24 * 3_600))
        XCTAssertTrue(dayLater.isUpdating, "a day after the fetch the bridge is still on")
        let monthLater = await service.current(now: start.addingTimeInterval(30 * 24 * 3_600))
        XCTAssertFalse(monthLater.isUpdating, "past the config's age limit it is off")
        XCTAssertNil(monthLater.manifest, "and the cached manifest is not served")
    }

    func testAnOutageAfterARefreshKeepsServingTheCachedManifest() async {
        let server = Server([policy.configURL: configJSON, policy.manifestURL: manifestJSON])
        let (service, cache) = makeService(server)
        defer { try? FileManager.default.removeItem(at: cache) }
        _ = await service.refresh(now: start)
        server.goOffline()

        let outcome = await service.refresh(now: start.addingTimeInterval(3_600))
        XCTAssertEqual(outcome, .failed(.network))
        let snapshot = await service.current(now: start.addingTimeInterval(3_600))
        XCTAssertTrue(snapshot.isUpdating, "the cached bridge keeps working through an outage")
        XCTAssertEqual(snapshot.manifest?.sources.count, 1)
    }
}
