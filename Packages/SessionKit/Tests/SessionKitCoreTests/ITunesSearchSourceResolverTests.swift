import Foundation
import XCTest
@testable import SessionKit

final class ITunesSearchSourceResolverTests: XCTestCase {
    private struct TestName: Decodable {
        var query: String
        var expectedTitle: String
        var expectedArtist: String
        var tier: String
    }

    private struct TestList: Decodable {
        var names: [TestName]
    }

    /// B1 M2 bar: the right show first for at least 45 of the 50 committed names,
    /// replayed from recorded iTunes Search responses (no live network).
    func testRightShowFirstForAtLeast45Of50Names() throws {
        let list = try JSONDecoder().decode(TestList.self, from: Data(contentsOf: SourceCatalogTests.path("Contracts/fixtures/podcast-search/test-names.json")))
        XCTAssertEqual(list.names.count, 50)
        XCTAssertEqual(Set(list.names.map(\.query)).count, 50)
        XCTAssertGreaterThanOrEqual(list.names.filter { $0.tier == "niche" }.count, 20, "mix popular and niche")

        var misses: [String] = []
        for name in list.names {
            let body = try Data(contentsOf: Self.recordedResponse(for: name.query))
            let top = try ITunesSearchSourceResolver.candidates(query: name.query, responseBody: body).first
            if !Self.matches(top, name) {
                misses.append("\(name.query) → \(top?.title ?? "nothing") (\(top?.author ?? ""))")
            }
        }
        print("iTunes search: \(50 - misses.count)/50 right first. Misses: \(misses)")
        XCTAssertGreaterThanOrEqual(50 - misses.count, 45, "misses: \(misses)")
    }

    func testANameIsNeverCertainAndOnlyAnExactTitleIsLikely() throws {
        let body = try Data(contentsOf: Self.recordedResponse(for: "radiolab"))
        let candidates = try ITunesSearchSourceResolver.candidates(query: "radiolab", responseBody: body)
        XCTAssertEqual(candidates.first?.title, "Radiolab")
        XCTAssertEqual(candidates.first?.confidence, .likely)
        XCTAssertFalse(candidates.contains { $0.confidence == .exact })
        XCTAssertTrue(candidates.dropFirst().allSatisfy { $0.confidence == .possible })

        let partial = try ITunesSearchSourceResolver.candidates(query: "joe rogan", responseBody: Data(contentsOf: Self.recordedResponse(for: "joe rogan")))
        XCTAssertEqual(partial.first?.confidence, .possible, "a query that isn't the whole title stays possible")
    }

    func testAShowWithNoPublicFeedIsShownButNotFollowable() throws {
        let body = Data(#"{"resultCount":2,"results":[{"collectionId":1,"collectionName":"Exclusive Show","artistName":"Studio"},{"collectionId":2,"collectionName":"Open Show","artistName":"Studio","feedUrl":"http://example.com/feed.xml"}]}"#.utf8)
        let candidates = try ITunesSearchSourceResolver.candidates(query: "exclusive show", responseBody: body)
        let exclusive = try XCTUnwrap(candidates.first { $0.title == "Exclusive Show" })
        XCTAssertFalse(exclusive.isFollowable)
        XCTAssertTrue(exclusive.reason.contains("No public feed"))
        XCTAssertEqual(candidates.first { $0.title == "Open Show" }?.feed?.url, "https://example.com/feed.xml", "http feeds are offered as https")
    }

    func testResolveUsesTheSearchURLAndReportsHTTPErrors() async throws {
        let seen = URLLog()
        let body = try Data(contentsOf: Self.recordedResponse(for: "radiolab"))
        let resolver = ITunesSearchSourceResolver { url, _ in
            await seen.append(url)
            return (200, body)
        }
        XCTAssertFalse(resolver.canResolve(.link("https://example.com")))
        XCTAssertFalse(resolver.canResolve(.query("  the  ")))
        let candidates = try await resolver.resolve(.query("radiolab"))
        XCTAssertEqual(candidates.first?.title, "Radiolab")
        let seenURLs = await seen.values
        let url = try XCTUnwrap(seenURLs.first)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "itunes.apple.com")
        XCTAssertTrue(items.contains(URLQueryItem(name: "term", value: "radiolab")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "media", value: "podcast")))

        let limited = ITunesSearchSourceResolver { _, _ in (403, Data()) }
        do {
            _ = try await limited.resolve(.query("radiolab"))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ITunesSearchError, .httpStatus(403))
        }
    }

    private actor URLLog {
        var values: [URL] = []
        func append(_ url: URL) { values.append(url) }
    }

    private static func matches(_ candidate: SourceCandidate?, _ name: TestName) -> Bool {
        guard let candidate else { return false }
        let title = normalized(candidate.title)
        let artist = normalized(candidate.author ?? "")
        return title.hasPrefix(normalized(name.expectedTitle)) && artist.contains(normalized(name.expectedArtist))
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func recordedResponse(for query: String) throws -> URL {
        let slug = query.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return try SourceCatalogTests.path("Contracts/fixtures/podcast-search/itunes-responses/\(slug).json")
    }
}
