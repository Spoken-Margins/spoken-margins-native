import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

final class SourceResolutionTests: XCTestCase {
    func testEveryResolutionFixtureDecodesAndRoundTrips() throws {
        let resolutions = try Self.fixtureResolutions()
        XCTAssertGreaterThanOrEqual(resolutions.count, 5)
        for resolution in resolutions {
            XCTAssertEqual(resolution.schemaVersion, SourceResolution.currentSchemaVersion)
            let again = try JSONDecoder().decode(SourceResolution.self, from: JSONEncoder().encode(resolution))
            XCTAssertEqual(again, resolution)
        }
    }

    func testAFeedWithASecretIsPrivateEvenWhenTheResolverSaysOtherwise() throws {
        let secret = "https://www.patreon.com/rss/show?auth=Zx81kq0P2mNw7rT4yB6vC9dF3hJ5lA1s"
        XCTAssertTrue(SourceCandidateFeed(url: secret, isPrivate: false).isPrivate)
        let json = Data(#"{"url":"\#(secret)","isPrivate":false}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(SourceCandidateFeed.self, from: json).isPrivate, "decoding can't lower privacy either")
        XCTAssertFalse(SourceCandidateFeed(url: "https://feeds.simplecast.com/Sl5CSM3S").isPrivate)
        XCTAssertTrue(SourceCandidateFeed(url: "https://feeds.simplecast.com/Sl5CSM3S", isPrivate: true).isPrivate, "a resolver may always mark a feed private")
    }

    func testOnlyExactCandidatesFollowWithoutConfirmation() throws {
        let resolutions = try Self.fixtureResolutions()
        let candidates = resolutions.flatMap(\.candidates)
        XCTAssertTrue(candidates.contains { $0.confidence == .exact && !$0.needsConfirmation })
        XCTAssertTrue(candidates.filter { $0.confidence != .exact }.allSatisfy(\.needsConfirmation))
        let youtube = try XCTUnwrap(candidates.first { $0.resolverId == "youtube_podcast_match" })
        XCTAssertFalse(youtube.isFollowable, "a channel with no podcast feed is shown, not followed")
    }

    func testRegistryRecordsAThrowingResolverAsAFailureAndKeepsTheOthers() async throws {
        struct Offline: SourceResolver {
            let id = "offline"
            func canResolve(_ input: SourceResolutionInput) -> Bool { true }
            func resolve(_ input: SourceResolutionInput) async throws -> [SourceCandidate] { throw URLError(.notConnectedToInternet) }
        }
        let stub = StubSourceResolver(resolutions: try Self.fixtureResolutions())
        let input = SourceResolutionInput.query("radiolab")
        let registry = SourceResolverRegistry(resolvers: [Offline(), stub])
        let results = await registry.resolve(input)
        XCTAssertEqual(results.map(\.resolverId), ["offline", "stub"])
        XCTAssertNotNil(results[0].failure)
        XCTAssertEqual(results[1].candidates.first?.title, "Radiolab")
    }

    func testMergeCollapsesTheSameFeedToTheMostConfidentAndKeepsPrivacySticky() throws {
        func candidate(_ id: String, _ feed: String, _ confidence: SourceCandidateConfidence, score: Double? = nil, isPrivate: Bool = false) -> SourceCandidate {
            SourceCandidate(id: id, kind: .podcastFeed, contentKind: .podcast, title: id, feed: SourceCandidateFeed(url: feed, isPrivate: isPrivate), confidence: confidence, score: score, reason: "test", resolverId: id)
        }
        let input = SourceResolutionInput.query("x")
        let merged = SourceResolverRegistry.merge([
            SourceResolution(input: input, resolverId: "a", candidates: [
                candidate("a-possible", "https://example.com/feed.xml", .possible, isPrivate: true),
                candidate("a-other", "https://example.com/other.xml", .likely, score: 0.2),
            ]),
            SourceResolution(input: input, resolverId: "b", candidates: [
                candidate("b-exact", "HTTPS://EXAMPLE.com/feed.xml/", .exact),
                candidate("b-other-2", "https://example.com/third.xml", .likely, score: 0.9),
            ]),
        ])
        XCTAssertEqual(merged.map(\.id), ["b-exact", "b-other-2", "a-other"])
        XCTAssertEqual(merged[0].feed?.isPrivate, true, "a feed any resolver saw as private stays private")
    }

    func testCatalogResolverMatchesAppleLinksExactlyAndNamesOnlyAsLikely() async throws {
        let catalog = try SourceCatalogVerifier.decodeCatalog(Data(contentsOf: TestInputs.url(.site, "onboarding/catalog/v1/catalog.json")))
        let resolver = CatalogSourceResolver(catalog: catalog)

        let link = SourceResolutionInput.classify(" https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=1000 ")
        XCTAssertEqual(link, .link("https://podcasts.apple.com/us/podcast/the-daily/id1200361736?i=1000"))
        XCTAssertTrue(resolver.canResolve(link))
        let byLink = try await resolver.resolve(link)
        XCTAssertEqual(byLink.map(\.title), ["The Daily"])
        XCTAssertEqual(byLink.first?.confidence, .exact)

        let byName = try await resolver.resolve(.classify("the daily"))
        let top = try XCTUnwrap(SourceResolverRegistry.merge([SourceResolution(input: .query("the daily"), resolverId: resolver.id, candidates: byName)]).first)
        XCTAssertEqual(top.title, "The Daily")
        XCTAssertEqual(top.confidence, .likely, "a name alone never makes a follow certain")

        XCTAssertFalse(resolver.canResolve(.link("https://example.com/article")))
        let none = try await resolver.resolve(.query("zzzz no such show"))
        XCTAssertTrue(none.isEmpty)
    }

    private static func fixtureResolutions() throws -> [SourceResolution] {
        let directory = try TestInputs.url(.contracts, "fixtures/source-resolution")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(SourceResolution.self, from: Data(contentsOf: $0)) }
    }
}
