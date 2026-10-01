import Foundation
import XCTest
@testable import SessionKit

final class SourceCatalogTests: XCTestCase {
    private static let fixture = "Contracts/fixtures/source-catalog/top-podcasts-small.json"
    private static let fixtureManifest = "Contracts/fixtures/source-catalog-manifest/top-podcasts-small.json"
    private static let publishedCatalog = "Site/onboarding/catalog/v1/catalog.json"
    private static let publishedManifest = "Site/onboarding/catalog/v1/manifest.json"

    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("source-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: The published snapshot meets the M1 bar

    func testPublishedSnapshotHasAHundredPodcastsAcrossEightSubjectsWithArtwork() throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: Self.path(Self.publishedCatalog)))
        let followable = catalog.entries.filter(\.isFollowable)
        let raw = try JSONDecoder().decode(SourceCatalog.self, from: Data(contentsOf: Self.path(Self.publishedCatalog)))
        XCTAssertEqual(catalog.entries.count, raw.entries.count, "validation must not drop any published entry")
        XCTAssertGreaterThanOrEqual(followable.count, 100)
        XCTAssertGreaterThanOrEqual(catalog.visibleSubjects.count, 8)
        XCTAssertTrue(followable.allSatisfy { $0.artworkURL?.hasPrefix("https://") == true }, "every drawer tile needs artwork")
        XCTAssertTrue(followable.allSatisfy { $0.kind == .podcastFeed && $0.contentKind == .podcast })
        let provenance = Set(catalog.provenance.map(\.id))
        XCTAssertTrue(followable.allSatisfy { Set($0.provenanceIds).isSubset(of: provenance) }, "every entry says where it came from")
        for subject in catalog.visibleSubjects {
            XCTAssertGreaterThanOrEqual(catalog.entries(forSubject: subject.id).count, 5, subject.id)
        }
    }

    func testPublishedManifestVerifiesThePublishedCatalog() throws {
        let manifest = try SourceCatalogVerifier.manifest(from: Data(contentsOf: Self.path(Self.publishedManifest)), policy: .production)
        let catalog = try SourceCatalogVerifier.catalog(from: Data(contentsOf: Self.path(Self.publishedCatalog)), manifest: manifest, policy: .production)
        XCTAssertEqual(catalog.catalogId, SourceCatalogPolicy.production.catalogId)
    }

    // MARK: Ordering

    func testSubjectOrderPutsStarterRowFirstThenPrimarySubjectByRank() throws {
        let catalog = try Self.fixtureCatalog()
        let science = catalog.entries(forSubject: "science")
        let starter = try XCTUnwrap(catalog.starterRows?.first { $0.subjectId == "science" })
        XCTAssertEqual(Array(science.prefix(starter.entryIds.count)).map(\.id), starter.entryIds)
        XCTAssertTrue(science.allSatisfy { $0.subjects.contains("science") })
        let rest = science.dropFirst(starter.entryIds.count)
        let primaryFirst = rest.map { $0.primarySubject == "science" }
        XCTAssertEqual(primaryFirst, primaryFirst.sorted { $0 && !$1 }, "shows whose primary subject this is come first")
        XCTAssertEqual(catalog.entries(forSubject: nil).count, catalog.entries.filter { $0.explicit != true }.count)
    }

    // MARK: Starter list: no shows marked explicit (#544)

    /// #544: the first-run list showed the 48 shows the catalog marks explicit, which would raise the
    /// App Store age rating. Loads the bundled catalog through the drawer's path (store, then
    /// `entries(forSubject:)`) and counts the shows against the raw file.
    func testStarterListFromTheBundledCatalogHidesShowsMarkedExplicit() async throws {
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.publishedCatalog), cacheDirectory: temporary, policy: .production) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let catalog = try await store.current()
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.path(Self.publishedCatalog))) as! [String: Any]
        let rawEntries = raw["entries"] as! [[String: Any]]
        let rawExplicit = rawEntries.filter { $0["explicit"] as? Bool == true }
        XCTAssertFalse(rawExplicit.isEmpty, "the bundled catalog marks some shows explicit")

        let starters = catalog.entries(forSubject: nil)
        XCTAssertEqual(starters.count, rawEntries.count - rawExplicit.count)
        XCTAssertGreaterThanOrEqual(starters.count, 100, "the M1 bar still holds")
        XCTAssertFalse(starters.contains { $0.explicit == true })
        for subject in catalog.visibleSubjects {
            let row = catalog.entries(forSubject: subject.id)
            XCTAssertFalse(row.isEmpty, subject.id)
            XCTAssertFalse(row.contains { $0.explicit == true }, subject.id)
        }

        // A show already followed keeps its catalog tags in Following.
        let explicitFeed = try XCTUnwrap(rawExplicit.first?["feedURL"] as? String)
        XCTAssertEqual(catalog.entry(matchingFeedURL: explicitFeed)?.explicit, true)
    }

    func testStarterListKeepsAShowWithNoExplicitFlag() throws {
        var catalog = try Self.fixtureCatalog()
        let unflagged = catalog.entries[0].id
        catalog.entries[0].explicit = nil
        let explicitIds = Set(catalog.entries.filter { $0.explicit == true }.map(\.id))
        XCTAssertFalse(explicitIds.isEmpty, "the fixture has a show marked explicit")
        let starters = catalog.entries(forSubject: nil).map(\.id)
        XCTAssertTrue(starters.contains(unflagged))
        XCTAssertTrue(explicitIds.isDisjoint(with: starters))
        // The fixture's comedy subject keeps its chip through its one clean show.
        XCTAssertTrue(catalog.visibleSubjects.contains { $0.id == "comedy" })
        XCTAssertEqual(catalog.entries(forSubject: "comedy").map(\.id), ["apple-1795483480"])
    }

    func testStarterListFromARefreshedCatalogHidesShowsMarkedExplicit() async throws {
        let (manifestData, catalogData) = try Self.remote(contentVersion: 2)
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { url, maximumBytes in
            url.lastPathComponent == "manifest.json" ? (200, manifestData) : (200, catalogData.prefix(maximumBytes))
        }
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .updated(contentVersion: 2))
        let catalog = try await store.current()
        XCTAssertTrue(catalog.entries.contains { $0.explicit == true }, "the server copy is unchanged")
        XCTAssertFalse(catalog.entries(forSubject: nil).contains { $0.explicit == true })
        XCTAssertFalse(catalog.entries(forSubject: "comedy").contains { $0.explicit == true })
    }

    func testEntryMatchingFeedURLFoldsSchemeAndHostCaseButNotPath() throws {
        let catalog = try Self.fixtureCatalog()
        let entry = try XCTUnwrap(catalog.entries.first)
        var components = try XCTUnwrap(URLComponents(string: entry.feedURL))
        components.scheme = "HTTP"
        components.host = components.host?.uppercased()
        let variant = try XCTUnwrap(components.string) + "/"
        XCTAssertEqual(catalog.entry(matchingFeedURL: variant)?.id, entry.id)
        // Feed paths are case-sensitive: a path differing only in case is another feed.
        let otherCase = entry.feedURL.replacingOccurrences(of: "Sl5CSM3S", with: "sl5csm3s")
        XCTAssertNotEqual(otherCase, entry.feedURL, "fixture's first entry is The Daily")
        XCTAssertNil(catalog.entry(matchingFeedURL: otherCase))
        XCTAssertNil(catalog.entry(matchingFeedURL: "https://example.com/not-in-catalog.xml"))
    }

    // MARK: Validation drops what must never be shown

    func testValidatorDropsHTTPDuplicateAndUnknownSubjectEntriesAndStaleStarterIds() throws {
        var catalog = try Self.fixtureCatalog()
        let good = catalog.entries[0]
        var plainHTTP = good
        plainHTTP.id = "plain-http"
        plainHTTP.feedURL = "http://example.com/feed.xml"
        var duplicateFeed = good
        duplicateFeed.id = "duplicate-feed"
        var unknownSubject = good
        unknownSubject.id = "unknown-subject"
        unknownSubject.feedURL = "https://example.com/other.xml"
        unknownSubject.subjects = ["cooking"]
        catalog.entries += [plainHTTP, duplicateFeed, unknownSubject]
        catalog.starterRows = [SourceCatalogStarterRow(subjectId: good.subjects[0], title: "Start", entryIds: ["plain-http", good.id], curatedBy: "owner")]

        let validated = try SourceCatalogValidator.validated(catalog)
        let ids = Set(validated.entries.map(\.id))
        XCTAssertFalse(ids.contains("plain-http"), "ATS would refuse it")
        XCTAssertFalse(ids.contains("duplicate-feed"))
        XCTAssertFalse(ids.contains("unknown-subject"))
        XCTAssertEqual(validated.starterRows?.first?.entryIds, [good.id])
    }

    func testValidatorKeepsPublicFeedsThatTheShareablePolicyWouldWithhold() throws {
        // A feed path ending in 32 hex digits looks like a secret to the packet policy.
        // Amperwave's public feeds are now exempt (#209), so this uses the same shape on
        // another host, which the policy still withholds. The catalog keeps it anyway.
        var catalog = try Self.fixtureCatalog()
        var hexPath = catalog.entries[0]
        hexPath.id = "hex-path"
        hexPath.feedURL = "https://feeds.example.com/podcast/496099a4061493caac75b71a6c26b8fb"
        catalog.entries.append(hexPath)
        XCTAssertNil(ShareableLinkPolicy.shareableLink(hexPath.feedURL))
        XCTAssertTrue(try SourceCatalogValidator.validated(catalog).entries.contains { $0.id == "hex-path" })
    }

    func testValidatorRejectsANewerSchemaVersionAndACatalogWithNothingFollowable() throws {
        var catalog = try Self.fixtureCatalog()
        catalog.schemaVersion = "source-catalog.v2"
        XCTAssertThrowsError(try SourceCatalogValidator.validated(catalog))
        catalog = try Self.fixtureCatalog()
        catalog.entries = catalog.entries.map { var entry = $0; entry.kind = .bridgedSite; return entry }
        XCTAssertThrowsError(try SourceCatalogValidator.validated(catalog)) { error in
            XCTAssertEqual(error as? SourceCatalogValidationError, .noUsableEntries)
        }
    }

    func testUnknownKindsAndFieldsDecodeSoANewerRemoteCatalogDoesNotBreakAnOlderApp() throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.path(Self.fixture))) as! [String: Any]
        var entries = object["entries"] as! [[String: Any]]
        entries[0]["kind"] = "some_future_kind"
        entries[0]["contentKind"] = "audiobook"
        entries[0]["futureField"] = ["nested": true]
        object["entries"] = entries
        object["futureTopLevel"] = 1
        let catalog = try SourceCatalogVerifier.decodeCatalog(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(catalog.entries[0].kind.rawValue, "some_future_kind")
        XCTAssertFalse(catalog.entries[0].isFollowable)
        XCTAssertFalse(catalog.entries(forSubject: nil).contains { $0.id == catalog.entries[0].id }, "the drawer skips what it can't follow")
    }

    // MARK: Store: bundled snapshot offline, remote refresh when newer

    func testStoreServesTheBundledSnapshotWhenOffline() async throws {
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let catalog = try await store.current()
        XCTAssertEqual(catalog.catalogId, "fixture-top-podcasts")
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .failed(.network))
        let after = try await store.current()
        XCTAssertEqual(after, catalog)
    }

    func testStoreTakesANewerVerifiedCatalogAndKeepsItAcrossLaunches() async throws {
        let (manifestData, catalogData) = try Self.remote(contentVersion: 2)
        let requested = RequestLog()
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { url, maximumBytes in
            await requested.append(url.lastPathComponent)
            return url.lastPathComponent == "manifest.json" ? (200, manifestData) : (200, catalogData.prefix(maximumBytes))
        }
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .updated(contentVersion: 2))
        let requestedFiles = await requested.values
        XCTAssertEqual(requestedFiles, ["manifest.json", "catalog.json"])
        let current = try await store.current()
        XCTAssertEqual(current.contentVersion, 2)

        let relaunched = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        let cached = try await relaunched.current()
        XCTAssertEqual(cached.contentVersion, 2, "the cached remote catalog survives a relaunch offline")
    }

    func testStoreDoesNotDownloadTheCatalogWhenTheManifestIsNotNewer() async throws {
        let (manifestData, _) = try Self.remote(contentVersion: 1)
        let requested = RequestLog()
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { url, _ in
            await requested.append(url.lastPathComponent)
            return (200, manifestData)
        }
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .unchanged(contentVersion: 1))
        let requestedFiles = await requested.values
        XCTAssertEqual(requestedFiles, ["manifest.json"])
    }

    func testStoreRejectsATamperedCatalogAndKeepsTheBundledOne() async throws {
        let (manifestData, catalogData) = try Self.remote(contentVersion: 2)
        var tampered = catalogData
        tampered[tampered.index(tampered.startIndex, offsetBy: 40)] ^= 0x01
        let tamperedBody = tampered
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { url, _ in
            url.lastPathComponent == "manifest.json" ? (200, manifestData) : (200, tamperedBody)
        }
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .failed(.checksumMismatch))
        let current = try await store.current()
        XCTAssertEqual(current.contentVersion, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("fixture-top-podcasts.json").path))
    }

    func testStoreRefusesACatalogURLOffTheTrustedHost() async throws {
        let (manifestData, _) = try Self.remote(contentVersion: 2, catalogURL: "https://evil.example/catalog.json")
        let store = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { _, _ in
            (200, manifestData)
        }
        let outcome = await store.refresh()
        XCTAssertEqual(outcome, .failed(.untrustedURL))
    }

    func testStoreRejectsAnOversizedManifestAndHTTPErrors() async throws {
        let big = Data(repeating: 0x20, count: Self.fixturePolicy.maximumManifestBytes + 1)
        let oversized = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { _, _ in (200, big) }
        let oversizedOutcome = await oversized.refresh()
        XCTAssertEqual(oversizedOutcome, .failed(.oversizedManifest))
        let missing = try SourceCatalogStore(bundledCatalogURL: Self.path(Self.fixture), cacheDirectory: temporary, policy: Self.fixturePolicy) { _, _ in (404, Data()) }
        let missingOutcome = await missing.refresh()
        XCTAssertEqual(missingOutcome, .failed(.httpStatus(404)))
    }

    func testFixtureManifestMatchesFixtureCatalog() throws {
        let manifest = try SourceCatalogVerifier.manifest(from: Data(contentsOf: Self.path(Self.fixtureManifest)), policy: Self.fixturePolicy)
        XCTAssertNoThrow(try SourceCatalogVerifier.catalog(from: Data(contentsOf: Self.path(Self.fixture)), manifest: manifest, policy: Self.fixturePolicy))
    }

    // MARK: Helpers

    private actor RequestLog {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    private static let fixturePolicy = SourceCatalogPolicy(
        manifestURL: URL(string: "https://spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/manifest.json")!,
        trustedHost: "spokenmargins.proximitytoprogress.com",
        catalogId: "fixture-top-podcasts"
    )

    private static func fixtureCatalog() throws -> SourceCatalog {
        try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: path(fixture)))
    }

    /// A remote manifest and catalog one content version on from the fixture.
    private static func remote(contentVersion: Int, catalogURL: String = "https://spokenmargins.proximitytoprogress.com/onboarding/catalog/v1/catalog.json") throws -> (Data, Data) {
        var catalog = try fixtureCatalog()
        catalog.contentVersion = contentVersion
        let catalogData = try JSONEncoder().encode(catalog)
        let manifest = SourceCatalogManifest(
            schemaVersion: SourceCatalogManifest.currentSchemaVersion,
            catalogId: catalog.catalogId,
            contentVersion: contentVersion,
            generatedAt: catalog.generatedAt,
            catalogURL: catalogURL,
            catalogByteCount: catalogData.count,
            catalogChecksumSHA256: SourceCatalogVerifier.sha256(catalogData),
            entryCount: catalog.entries.count
        )
        return (try JSONEncoder().encode(manifest), catalogData)
    }

    static func path(_ relative: String) throws -> URL {
        try repositoryRoot().appendingPathComponent(relative)
    }

    private static func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        return root
    }
}
