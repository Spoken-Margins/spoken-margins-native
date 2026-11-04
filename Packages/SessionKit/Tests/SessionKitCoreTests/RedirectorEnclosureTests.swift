import XCTest
import SessionKit
import SessionKitFeeds

/// Hacker Public Radio's enclosures are redirectors (`ccdn.php?filename=/eps/hpr4763/hpr4763.mp3`): the
/// feed labels them `audio/mpeg`, but the path ends in `.php`, so Play now ended in "not a playable
/// podcast/audio file" (#3345). The feed's own label decides; the address's shape only decides for a link
/// nobody labelled. Every case runs through both entry points, since the app calls `resolveAsync`.
final class RedirectorEnclosureTests: XCTestCase {
    private let html = "<html><head><title>An episode</title></head><body>No audio here</body></html>"

    private func resolve(_ link: String, declaredAudio: Bool, body: String? = nil) async throws -> [LinkResolutionResult] {
        let page = body ?? html
        let fetch: @Sendable (URL) throws -> Data = { _ in Data(page.utf8) }
        let resolver = PublicPodcastLinkResolver(fetch: fetch, asynchronousFetch: { try fetch($0) })
        let request = LinkResolutionRequest(id: "r", inputURL: link, sourceSurface: "followed_source",
                                            createdAt: Date(timeIntervalSince1970: 1), declaredAudio: declaredAudio)
        return [try resolver.resolve(request), try await resolver.resolveAsync(request)]
    }

    func testFeedDeclaredEnclosuresPlayWhateverTheirAddressLooksLike() async throws {
        let enclosures = [
            "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4763/hpr4763.mp3", // the report
            "https://example.com/download.php?id=42",                                       // no file name anywhere
            "https://example.com/dl?episode=42&format=m4a",                                 // query string only
            "https://cdn.example.com/a1b2c3d4",                                             // extension-less CDN
            "https://cdn.example.com/EPISODE.MP3",                                          // upper case
            "https://dts.podtrac.com/redirect.mp3/traffic.libsyn.com/show/ep.mp3?dest-id=1", // tracking prefix
            "https://chtbl.com/track/ABC123/cdn.example.com/ep",                            // tracking prefix, no extension
            "https://example.com/ep.m4a?token=a.b.c",
        ]
        for link in enclosures {
            for result in try await resolve(link, declaredAudio: true) {
                XCTAssertEqual(result.status, .playable, link)
                XCTAssertEqual(result.selectedCandidate?.audioURL, link, "\(link): the enclosure is played as given, not rewritten")
            }
        }
    }

    func testUnlabelledLinksStillNeedAnAudioFileInTheAddress() async throws {
        let audio = [
            "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4763/hpr4763.mp3",
            "https://example.com/dl.php?file=ep.M4A&x=1",
            "https://example.com/ep.MP3",
            "https://example.com/dl?file=%2Feps%2Fep.flac",
        ]
        for link in audio {
            for result in try await resolve(link, declaredAudio: false) {
                XCTAssertEqual(result.status, .playable, link)
            }
        }
        let notAudio = [
            "https://example.com/download.php?id=42",
            "https://example.com/episodes/12?next=/about",
            "https://example.com/post?title=mp3-players-reviewed",
            "https://cdn.example.com/a1b2c3d4",
        ]
        for link in notAudio {
            for result in try await resolve(link, declaredAudio: false) {
                XCTAssertEqual(result.status, .needsReview, "\(link): a page with no audio is still not playable")
                XCTAssertEqual(result.failureReason, "audio_enclosure_not_found", link)
            }
        }
    }

    func testRequestsSavedBeforeTheFlagStillDecode() throws {
        let json = #"{"id":"r","inputURL":"https://example.com/a","sourceSurface":"paste","createdAt":0}"#
        let request = try JSONDecoder().decode(LinkResolutionRequest.self, from: Data(json.utf8))
        XCTAssertFalse(request.declaredAudio)
        let round = try JSONDecoder().decode(LinkResolutionRequest.self, from: JSONEncoder().encode(
            LinkResolutionRequest(id: "r", inputURL: "https://example.com/a", sourceSurface: "paste", createdAt: Date(timeIntervalSince1970: 0), declaredAudio: true)))
        XCTAssertTrue(round.declaredAudio)
    }

    /// The whole chain for the reported show: the feed's enclosure, as the parser stores it, routes as
    /// declared audio, and that import resolves as playable. A page fallback is never declared.
    func testFollowedRedirectorEpisodeRoutesAsDeclaredAudioAndResolves() async throws {
        let feed = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Hacker Public Radio</title>
        <item><title>HPR4763</title><link>https://hackerpublicradio.org/eps/hpr4763/index.html</link><guid>hpr4763</guid>
        <enclosure url="https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4763/hpr4763.mp3" length="4040244" type="audio/mpeg"/></item>
        <item><title>HPR4762</title><link>https://hackerpublicradio.org/eps/hpr4762/index.html</link><guid>hpr4762</guid>
        <enclosure url="https://hub.hackerpublicradio.org/ccdn.php?id=4762" length="1" type="audio/x-m4a"/></item>
        </channel></rss>
        """
        let items = try FeedParser().parse(data: Data(feed.utf8)).items
        XCTAssertEqual(items.count, 2)
        for item in items {
            let audio = try XCTUnwrap(item.audioURL, item.title)
            let entry = FeedEntry(id: item.title, subscriptionId: "s", canonicalURL: item.url, audioURL: audio, title: item.title)
            let route = FollowedEntryImportRoute.route(for: entry, subscriptionKind: .podcastFeed, audio: FollowedEntryAudio.stored(in: entry))
            XCTAssertEqual(route, .episode(audioURL: audio, declaredAudio: true), item.title)
            guard case .episode(let url, let declared) = route else { return XCTFail() }
            for result in try await resolve(url, declaredAudio: declared) {
                XCTAssertEqual(result.status, .playable, item.title)
            }
        }
        let gone = FeedEntry(id: "gone", subscriptionId: "s", canonicalURL: "https://hackerpublicradio.org/eps/hpr1/index.html", title: "Gone")
        XCTAssertEqual(
            FollowedEntryImportRoute.route(for: gone, subscriptionKind: .podcastFeed, audio: .unknown),
            .episode(audioURL: gone.canonicalURL, declaredAudio: false)
        )
    }
}
