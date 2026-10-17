import XCTest
import SessionKit
import SessionKitFeeds
import SessionKitTestInputs

/// Host tests for the public podcast link resolver (moved from the app-hosted
/// SourceLinkImportTests, #318). Network access is always injected.
@MainActor
final class PublicPodcastLinkResolverTests: XCTestCase {
    private static let fixtures = TestInputs.packageURL("Tests/SessionKitTests/Fixtures")

    func testDescriptionChaptersAcceptLinkedParenthesesAndPreserveTitleColons() throws {
        let chapters = try XCTUnwrap(TimestampedDescriptionChapterParser.parse("""
        <p>Episode notes with unrelated <a href="https://example.com?t=99">links</a>.</p>
        <div>(<a href="https://example.com/watch?t=0">00:00:00</a>) &ndash; AI: the opening question</div>
        <div><a href="https://example.com/watch?t=942">(00:15:42)</a>&nbsp;— Evidence &amp; uncertainty</div>
        <p>[01:02:03](https://example.com/watch?t=3723) | What&#39;s next?</p>
        """))
        XCTAssertEqual(chapters.source, .timestampedDescription)
        XCTAssertEqual(chapters.chapters, [
            PublisherChapter(title: "AI: the opening question", startMs: 0),
            PublisherChapter(title: "Evidence & uncertainty", startMs: 942_000),
            PublisherChapter(title: "What's next?", startMs: 3_723_000)
        ])
    }

    func testDescriptionChaptersValidateTimesAndIgnoreProseAndURLOnlyLines() throws {
        let chapters = try XCTUnwrap(TimestampedDescriptionChapterParser.parse("""
        Released at 12:30 on Tuesday.
        00:60 Invalid seconds
        01:75:00 Invalid minutes
        [00:02) Mismatched brackets
        00:03garbage
        00:04 https://example.com
        <script>00:05 Script content</script>
        • [120:00] Long introduction
        00:00.250 - First thought
        00:00.250 - First thought
        00&#58;30&#160;– A second thought
        """))
        XCTAssertEqual(chapters.chapters.map(\.startMs), [250, 30_000, 7_200_000])
        XCTAssertEqual(chapters.chapters.map(\.title), ["First thought", "A second thought", "Long introduction"])
        XCTAssertNil(TimestampedDescriptionChapterParser.parse("00:00 Only one chapter"))
        XCTAssertNil(TimestampedDescriptionChapterParser.parse(String(repeating: "x", count: 1_000_001)))
    }

    func testFeedDescriptionChaptersSurviveAnEarlierShortSummary() throws {
        let feed = """
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><title>Show</title><item><title>Episode</title>
        <enclosure url="https://example.com/episode.mp3" type="audio/mpeg" />
        <description>A brief summary without chapters.</description>
        <content:encoded><![CDATA[<p>(00:00) – Opening</p><p>(12:30) – Discussion</p>]]></content:encoded>
        </item></channel></rss>
        """
        let request = LinkResolutionRequest(id: "description-fallback", inputURL: "https://example.com/feed.xml", sourceSurface: "paste", createdAt: Date())
        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(feed.utf8) }).resolve(request)
        let collections = try XCTUnwrap(result.selectedCandidate).publisherChapterCollections
        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.first?.source, .timestampedDescription)
        XCTAssertEqual(collections.first?.chapters.map(\.startMs), [0, 750_000])
    }

    func testExactAppleEpisodeRetainsSevenChaptersWhenFeedReturns403() async throws {
        // Shape and times from Apple episode 1000774870615; prose is synthetic.
        let times = ["00:00:00", "00:11:32", "00:26:12", "00:38:08", "00:53:48", "01:07:07", "01:16:02"]
        let description = times.enumerated().map { "(\($0.element)) – Topic \($0.offset + 1)" }.joined(separator: "\n")
        let data = try JSONSerialization.data(withJSONObject: ["results": [[
            "trackId": 1000774870615, "kind": "podcast-episode",
            "trackName": "Grant Sanderson – AI and the future of math",
            "collectionName": "Dwarkesh Podcast", "trackTimeMillis": 5619000,
            "feedUrl": "https://feed.example/forbidden.rss", "episodeUrl": "https://audio.example/episode.mp3",
            "description": description, "shortDescription": "Summary without chapters"
        ]]])
        let fetch: @Sendable (URL) throws -> Data = { url in
            guard url.host == "itunes.apple.com" else { throw URLError(.badServerResponse) }
            return data
        }
        let resolver = PublicPodcastLinkResolver(fetch: fetch, asynchronousFetch: { try fetch($0) })
        let request = LinkResolutionRequest(id: "exact-apple", inputURL: "https://podcasts.apple.com/us/podcast/dwarkesh-podcast/id1516093381?i=1000774870615", sourceSurface: "paste", createdAt: Date())
        let synchronous = try resolver.resolve(request)
        let asynchronous = try await resolver.resolveAsync(request)
        for result in [synchronous, asynchronous] {
            XCTAssertEqual(result.status, .playable)
            let candidate = try XCTUnwrap(result.selectedCandidate)
            XCTAssertEqual(candidate.durationMs, 5_619_000)
            XCTAssertEqual(candidate.publisherChapterCollections.first?.chapters.map(\.startMs), [0, 692000, 1572000, 2288000, 3228000, 4027000, 4562000])
            XCTAssertEqual(candidate.publisherChapterCollections.first?.source, .timestampedDescription)
        }
    }

    func testEpisodePageWithoutPlayMetadataResolvesThroughItsLinkedFeed() async throws {
        // Omny episode pages carry no inline play metadata but link the show feed (#157).
        let pageURL = "https://omny.fm/shows/odd-lots/hollywood-was-cooked-before-ai-and-now-its-only-getting-worse"
        let resolver = try omnyFixtureResolver()
        let request = LinkResolutionRequest(id: "omny-page", inputURL: pageURL, sourceSurface: "spoken_margins_package", createdAt: Date())
        for result in [try resolver.resolve(request), try await resolver.resolveAsync(request)] {
            XCTAssertEqual(result.status, .playable)
            let candidate = try XCTUnwrap(result.selectedCandidate)
            XCTAssertEqual(candidate.title, "Hollywood Was Cooked Before AI, and Now It's Only Getting Worse")
            XCTAssertTrue(candidate.audioURL?.contains("77d27e49-f26e-4c79-8913-b4cf01192cf5/audio.mp3") == true)
            XCTAssertEqual(candidate.sourceLink.url, "https://omny.fm/shows/odd-lots/playlists/podcast.rss")
        }
    }

    func testLinkedFeedIsNotTrustedForAPageItDoesNotList() async throws {
        let resolver = try omnyFixtureResolver()
        let request = LinkResolutionRequest(
            id: "omny-unlisted",
            inputURL: "https://omny.fm/shows/odd-lots/an-episode-missing-from-the-feed",
            sourceSurface: "paste",
            createdAt: Date()
        )
        let result = try await resolver.resolveAsync(request)
        XCTAssertNotEqual(result.status, .playable, "a nearby Hollywood episode must not be picked by title similarity")
        XCTAssertNil(result.candidates.compactMap(\.audioURL).first)
    }

    private func omnyFixtureResolver() throws -> PublicPodcastLinkResolver {
        let page = try Data(contentsOf: Self.fixtures.appending(path: "omny-episode-page.html"))
        let feed = try Data(contentsOf: Self.fixtures.appending(path: "omny-odd-lots-feed.xml"))
        let fetch: @Sendable (URL) throws -> Data = { url in
            if url.absoluteString == "https://omny.fm/shows/odd-lots/playlists/podcast.rss" { return feed }
            if url.host == "omny.fm", url.path.hasPrefix("/shows/odd-lots/") { return page }
            throw URLError(.badServerResponse)
        }
        return PublicPodcastLinkResolver(fetch: fetch, asynchronousFetch: { try fetch($0) })
    }

    func testPublicResolverAcceptsDirectAudioURL() throws {
        let request = LinkResolutionRequest(
            id: "request-direct",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data() }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, request.inputURL)
        XCTAssertEqual(result.originalLink.provider, "direct_audio")
    }

    func testPublicResolverRejectsInsecureHTTPBeforeFetching() throws {
        let request = LinkResolutionRequest(
            id: "request-http",
            inputURL: "http://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in throw URLError(.badURL) }).resolve(request)

        XCTAssertEqual(result.status, .unsupported)
        XCTAssertEqual(result.failureReason, "invalid_url")
    }

    func testPublicResolverAsyncAcceptsDirectAudioURL() async throws {
        let request = LinkResolutionRequest(
            id: "request-direct-async",
            inputURL: "https://cdn.example.com/audio.mp3",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try await PublicPodcastLinkResolver().resolveAsync(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, request.inputURL)
        XCTAssertEqual(result.originalLink.provider, "direct_audio")
    }

    func testPublicResolverExtractsRSSAudioEnclosure() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters">
          <channel>
            <title>Example Show</title>
            <item>
              <title>Episode One</title>
              <guid>episode-one</guid>
              <pubDate>Fri, 19 Jun 2026 12:00:00 GMT</pubDate>
              <itunes:duration>00:30:00</itunes:duration>
              <enclosure url="https://cdn.example.com/episode-one.mp3" type="audio/mpeg" length="1" />
              <podcast:transcript url="https://cdn.example.com/episode-one.vtt" type="text/vtt" language="en" rel="captions" />
              <podcast:chapters url="https://cdn.example.com/episode-one-chapters.json" type="application/json+chapters" />
              <psc:chapters version="1.2">
                <psc:chapter start="0" title="Podlove Intro" />
                <psc:chapter start="12:30.250" title="Podlove Topic" />
              </psc:chapters>
              <description><![CDATA[
                00:00 Description Intro<br />
                15:00 Description Topic
              ]]></description>
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-rss",
            inputURL: "https://feeds.example.com/show.xml",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let chapterJSON = """
        {
          "version": "1.2.0",
          "chapters": [
            { "startTime": 0, "title": "Publisher Intro" },
            { "startTime": 600.5, "title": "Publisher Topic" },
            { "startTime": 900, "title": "Silent Artwork", "toc": false }
          ]
        }
        """
        let result = try PublicPodcastLinkResolver(fetch: { url in
            url.path.hasSuffix("episode-one-chapters.json") ? Data(chapterJSON.utf8) : Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Episode One")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Example Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/episode-one.mp3")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 1_800_000)
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks, [
            SourceTranscriptLink(
                url: "https://cdn.example.com/episode-one.vtt",
                type: "text/vtt",
                language: "en",
                rel: "captions"
            )
        ])
        XCTAssertEqual(result.selectedCandidate?.chapterLinks, [
            SourceChapterLink(
                url: "https://cdn.example.com/episode-one-chapters.json",
                type: "application/json+chapters"
            )
        ])
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.map(\.source), [
            .podcasting20JSON,
            .podloveSimpleChapters,
            .timestampedDescription
        ])
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections[0].chapters, [
            PublisherChapter(title: "Publisher Intro", startMs: 0),
            PublisherChapter(title: "Publisher Topic", startMs: 600_500)
        ])
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections[1].chapters[1].startMs, 750_250)
    }

    func testPublicResolverAcceptsLegacyPodcastingNamespaceUsedByNoAgendaFeed() throws {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md">
          <channel>
            <title>No Agenda Show</title>
            <item>
              <title>1891 - "We Need Memes!"</title>
              <guid>http://1891.noagendanotes.com</guid>
              <enclosure url="https://op3.dev/e/example/NA-1891-Final.mp3" type="audio/mpeg" length="1" />
              <podcast:transcript url="https://mp3s.nashownotes.com/NA-1891-Captions.srt" type="application/srt" rel="captions" />
              <podcast:chapters url="https://chapters.example.com/NA-1891-Chapters.json" type="application/json" />
            </item>
          </channel>
        </rss>
        """
        let chapterJSON = """
        {"version":"1.2.0","chapters":[
          {"startTime":0,"title":"Show Open"},
          {"startTime":150.74,"title":"Producer Context"}
        ]}
        """
        let lookup = """
        {"resultCount":1,"results":[{
          "wrapperType":"track",
          "kind":"podcast",
          "trackId":269169796,
          "collectionName":"No Agenda Show",
          "feedUrl":"https://feeds.noagendaassets.com/noagenda.xml"
        }]}
        """
        let request = LinkResolutionRequest(
            id: "request-no-agenda-apple",
            inputURL: "https://podcasts.apple.com/us/podcast/1891-we-need-memes/id269169796?i=1000779583526",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "itunes.apple.com" { return Data(lookup.utf8) }
            if url.host == "feeds.noagendaassets.com" { return Data(feed.utf8) }
            if url.host == "chapters.example.com" { return Data(chapterJSON.utf8) }
            throw URLError(.badURL)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "1891 - \"We Need Memes!\"")
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks.first?.type, "application/srt")
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.source, .podcasting20JSON)
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.chapters[1].startMs, 150_740)
    }

    func testPublicResolverImportsStructuredPodcastEpisodePageWithPublisherChapters() throws {
        let metadata = #"{"type":"episode","code":"1891","title":"1891: We Need Memes!","src":"https://op3.dev/e/example/NA-1891-Final.mp3","duration":11215,"publishedAt":"2026-08-02","transcript":"https://mp3s.nashownotes.com/NA-1891-Captions.srt","chapters":"https://chapters.example.com/NA-1891-Chapters.json"}"#
        let encodedMetadata = metadata.replacingOccurrences(of: "\"", with: "&quot;")
        let page = """
        <!doctype html>
        <html><head><title>No Agenda 1891</title></head><body>
          <a data-play-metadata-value="\(encodedMetadata)">Play</a>
        </body></html>
        """
        let chapterJSON = """
        {"version":"1.2.0","chapters":[
          {"startTime":0,"title":"Show Open"},
          {"startTime":303.322,"title":"Press Malpractice"}
        ]}
        """
        let request = LinkResolutionRequest(
            id: "request-no-agenda-page",
            inputURL: "https://www.noagendashow.net/listen/1891",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "www.noagendashow.net" { return Data(page.utf8) }
            if url.host == "chapters.example.com" { return Data(chapterJSON.utf8) }
            throw URLError(.badURL)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "episode_page")
        XCTAssertEqual(result.selectedCandidate?.title, "1891: We Need Memes!")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 11_215_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://op3.dev/e/example/NA-1891-Final.mp3")
        XCTAssertEqual(result.selectedCandidate?.transcriptLinks.first?.type, "application/srt")
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.chapters[1].startMs, 303_322)
    }

    func testPublicResolverUsesAppleLookupAudioURL() throws {
        let lookup = """
        {
          "resultCount": 3,
          "results": [
            {
              "wrapperType": "track",
              "kind": "podcast",
              "trackId": 123456,
              "collectionName": "Apple Show",
              "feedUrl": "https://feeds.example.com/apple-show.xml"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackId": 111,
              "trackName": "Different Episode",
              "episodeUrl": "https://cdn.example.com/wrong-episode.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackId": 999,
              "trackName": "Apple Episode",
              "collectionName": "Apple Show",
              "episodeUrl": "https://cdn.example.com/apple-episode.mp3"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Apple Episode</title>
              <guid>https://podcasts.apple.com/us/podcast/show/id123456?i=999</guid>
              <enclosure url="https://cdn.example.com/apple-episode.mp3" type="audio/mpeg" />
              <psc:chapters><psc:chapter start="0" title="Publisher Opening" /></psc:chapters>
            </item>
          </channel>
        </rss>
        """

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.absoluteString == "https://feeds.example.com/apple-show.xml" {
                return Data(feed.utf8)
            }
            XCTAssertTrue(url.absoluteString.contains("itunes.apple.com/lookup"))
            XCTAssertTrue(url.absoluteString.contains("id=123456"))
            XCTAssertTrue(url.absoluteString.contains("entity=podcastEpisode"))
            XCTAssertTrue(url.absoluteString.contains("limit=200"))
            return Data(lookup.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/apple-episode.mp3")
        XCTAssertEqual(result.selectedCandidate?.publisherChapterCollections.first?.source, .podloveSimpleChapters)
    }

    func testPublicResolverAcceptsAppleLookupExtensionlessAudioURL() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "trackId": 999,
            "trackName": "Apple Episode",
            "collectionName": "Apple Show",
            "episodeUrl": "https://traffic.example.net/APPLEEPISODE123"
          }]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-apple-extensionless",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in Data(lookup.utf8) }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://traffic.example.net/APPLEEPISODE123")
    }

    func testPublicResolverRecoversCanonicalFeedForExistingAppleEpisode() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let episodeURL = try XCTUnwrap(URL(string: "https://podcasts.apple.com/us/podcast/show/id123456?i=999"))
        let resolver = PublicPodcastLinkResolver(fetch: { url in
            XCTAssertTrue(url.absoluteString.contains("itunes.apple.com/lookup"))
            return Data(lookup.utf8)
        })

        XCTAssertEqual(
            try resolver.canonicalFeedURL(for: episodeURL)?.absoluteString,
            "https://feeds.example.com/apple-show.xml"
        )
    }

    func testPublicResolverFallsBackToApplePageStreamWhenLookupIsEmpty() throws {
        let html = #"""
        <html>
          <head><title>Apple Page Episode - Apple Podcasts</title></head>
          <body>
            <script>
              {"title":"Apple Page Episode","collectionName":"Apple Page Show","streamUrl":"https:\/\/traffic.example.net\/page-episode.mp3","duration":1971}
            </script>
          </body>
        </html>
        """#
        let request = LinkResolutionRequest(
            id: "request-apple-page",
            inputURL: "https://podcasts.apple.com/us/podcast/show/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.absoluteString.contains("itunes.apple.com/lookup") {
                return Data(#"{"resultCount":0,"results":[]}"#.utf8)
            }
            XCTAssertTrue(url.absoluteString.contains("podcasts.apple.com"))
            return Data(html.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Apple Page Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Apple Page Show")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 1_971_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://traffic.example.net/page-episode.mp3")
    }

    func testPublicResolverFallsBackToFeedWhenEpisodeIsOutsideAppleLookupWindow() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/wrong-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Requested Old Episode</title>
              <enclosure url="https://cdn.example.com/requested-old-episode.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-apple-feed-fallback",
            inputURL: "https://podcasts.apple.com/us/podcast/requested-old-episode/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.host == "itunes.apple.com" {
                return Data(lookup.utf8)
            }
            XCTAssertEqual(url.absoluteString, "https://feeds.example.com/apple-show.xml")
            return Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Requested Old Episode")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/requested-old-episode.mp3")
    }

    func testPublicResolverUsesApplePageWhenShowSlugCannotIdentifyEpisodeInFeed() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 1528594034,
            "feedUrl": "https://feeds.example.com/hard-fork.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Hard Fork</title>
            <item>
              <title>OpenAI Models Go Rogue + Kimi K3 Freakout + A.I. Superforecasting</title>
              <enclosure url="https://cdn.example.com/feed-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/another.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let page = #"""
        <html>
          <head><title>OpenAI Models Go Rogue - Hard Fork - Apple Podcasts</title></head>
          <body>
            <script>
              {"title":"OpenAI Models Go Rogue + Kimi K3 Freakout + A.I. Superforecasting","streamUrl":"https:\/\/cdn.example.com\/apple-page-episode.mp3","duration":4094}
            </script>
          </body>
        </html>
        """#
        let request = LinkResolutionRequest(
            id: "request-apple-current-episode",
            inputURL: "https://podcasts.apple.com/us/podcast/hard-fork/id1528594034?i=1000778186885",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            switch url.host {
            case "itunes.apple.com":
                return Data(lookup.utf8)
            case "feeds.example.com":
                return Data(feed.utf8)
            case "podcasts.apple.com":
                return Data(page.utf8)
            default:
                XCTFail("Unexpected resolver URL: \(url)")
                return Data()
            }
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "apple_podcasts")
        XCTAssertEqual(result.selectedCandidate?.title, "OpenAI Models Go Rogue + Kimi K3 Freakout + A.I. Superforecasting")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 4_094_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/apple-page-episode.mp3")
    }

    func testAppleFeedFallbackNeverSelectsADifferentEpisode() throws {
        let lookup = """
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "track",
            "kind": "podcast",
            "trackId": 123456,
            "feedUrl": "https://feeds.example.com/apple-show.xml"
          }]
        }
        """
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Apple Show</title>
            <item>
              <title>Newest Episode</title>
              <enclosure url="https://cdn.example.com/newest-episode.mp3" type="audio/mpeg" />
            </item>
            <item>
              <title>Another Episode</title>
              <enclosure url="https://cdn.example.com/another-episode.mp3" type="audio/mpeg" />
            </item>
          </channel>
        </rss>
        """
        let request = LinkResolutionRequest(
            id: "request-apple-no-wrong-fallback",
            inputURL: "https://podcasts.apple.com/us/podcast/requested-missing-episode/id123456?i=999",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            url.host == "itunes.apple.com" ? Data(lookup.utf8) : Data(feed.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.failureReason, "rss_episode_ambiguous")
    }

    func testPublicResolverExplainsWhenSpotifyEpisodeHasNoAppleMatch() throws {
        let oEmbed = #"{"title":"Spotify Episode"}"#
        let request = LinkResolutionRequest(
            id: "request-spotify",
            inputURL: "https://open.spotify.com/episode/abc123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                return Data(oEmbed.utf8)
            }
            if url.host?.contains("spotify.com") == true {
                return Data()
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            return Data(#"{"resultCount":0,"results":[]}"#.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.candidates.first?.title, "Spotify Episode")
        XCTAssertEqual(result.failureReason, "spotify_episode_not_found_on_apple")
    }

    func testPublicResolverRequiresASpecificSpotifyEpisodeLink() throws {
        let request = LinkResolutionRequest(
            id: "request-spotify-show",
            inputURL: "https://open.spotify.com/show/show123",
            sourceSurface: "share_extension",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { _ in
            XCTFail("A Spotify show link should be rejected before network resolution")
            return Data()
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertEqual(result.originalLink.provider, "spotify")
        XCTAssertEqual(result.failureReason, "spotify_specific_episode_required")
    }

    func testPublicResolverNormalizesSpotifyEpisodeToExactAppleMatch() throws {
        let oEmbed = #"{"title":"The Shared Episode!"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "A Different Episode",
              "collectionName": "Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "The Shared Episode",
              "collectionName": "Shared Show",
              "trackViewUrl": "https://podcasts.apple.com/us/podcast/shared-show/id123?i=456",
              "episodeUrl": "https://cdn.example.com/shared.mp3",
              "trackTimeMillis": 123000,
              "releaseDate": "2026-07-01T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-apple-match",
            inputURL: "https://open.spotify.com/episode/shared123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                XCTAssertEqual(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                    request.inputURL
                )
                return Data(oEmbed.utf8)
            }
            if url.host?.contains("spotify.com") == true {
                return Data()
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "entity" })?.value, "podcastEpisode")
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.originalLink.provider, "spotify")
        XCTAssertEqual(result.selectedCandidate?.sourceLink.provider, "apple_podcasts")
        XCTAssertEqual(result.selectedCandidate?.title, "The Shared Episode")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "Shared Show")
        XCTAssertEqual(result.selectedCandidate?.durationMs, 123_000)
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/shared.mp3")
    }

    func testSpotifyMatchedAppleEpisodeResolvesCanonicalFeed() throws {
        let oEmbed = #"{"title":"The Shared Episode!"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "A Different Episode",
              "collectionName": "Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "kind": "podcast-episode",
              "trackName": "The Shared Episode",
              "collectionName": "Shared Show",
              "trackViewUrl": "https://podcasts.apple.com/us/podcast/shared-show/id123?i=456",
              "episodeUrl": "https://cdn.example.com/shared.mp3",
              "trackTimeMillis": 123000,
              "releaseDate": "2026-07-01T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-apple-match",
            inputURL: "https://open.spotify.com/episode/shared123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let feed = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                XCTAssertEqual(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                    request.inputURL
                )
                return Data(oEmbed.utf8)
            }
            if url.host?.contains("spotify.com") == true {
                return Data()
            }
            if url.path == "/lookup" {
                return Data(#"{"results":[{"feedUrl":"https://example.com/show.rss"}]}"#.utf8)
            }
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "entity" })?.value, "podcastEpisode")
            return Data(appleSearch.utf8)
        }).canonicalFeedURL(for: try XCTUnwrap(URL(string: request.inputURL)))

        XCTAssertEqual(feed?.absoluteString, "https://example.com/show.rss")
    }

    func testPublicResolverDoesNotGuessBetweenAmbiguousSpotifyAppleMatches() throws {
        let oEmbed = #"{"title":"Trailer"}"#
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "trackName": "Trailer",
              "collectionName": "Show One",
              "episodeUrl": "https://cdn.example.com/show-one.mp3"
            },
            {
              "wrapperType": "podcastEpisode",
              "trackName": "Trailer",
              "collectionName": "Show Two",
              "episodeUrl": "https://cdn.example.com/show-two.mp3"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-ambiguous",
            inputURL: "https://open.spotify.com/episode/trailer123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" { return Data(oEmbed.utf8) }
            if url.host?.contains("spotify.com") == true { return Data() }
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.failureReason, "spotify_episode_match_ambiguous")
    }

    func testPublicResolverUsesShowDateAndDurationToDisambiguateSpotifyEpisode() throws {
        let oEmbed = """
        {
          "title": "A Shared Episode",
          "showTitle": "The Correct Show",
          "releaseDate": "2026-07-02T00:00:00Z",
          "durationMs": 3600000
        }
        """
        let appleSearch = """
        {
          "resultCount": 2,
          "results": [
            {
              "wrapperType": "podcastEpisode",
              "trackName": "A Shared Episode",
              "collectionName": "The Wrong Show",
              "episodeUrl": "https://cdn.example.com/wrong.mp3",
              "trackTimeMillis": 2400000,
              "releaseDate": "2025-01-01T00:00:00Z"
            },
            {
              "wrapperType": "podcastEpisode",
              "trackName": "A Shared Episode",
              "collectionName": "The Correct Show",
              "trackViewUrl": "https://podcasts.apple.com/correct",
              "episodeUrl": "https://cdn.example.com/correct.mp3",
              "trackTimeMillis": 3601000,
              "releaseDate": "2026-07-02T12:00:00Z"
            }
          ]
        }
        """
        let request = LinkResolutionRequest(
            id: "request-spotify-evidence",
            inputURL: "https://open.spotify.com/episode/evidence123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" { return Data(oEmbed.utf8) }
            if url.host?.contains("spotify.com") == true { return Data() }
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.showTitle, "The Correct Show")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/correct.mp3")
        XCTAssertGreaterThanOrEqual(result.selectedCandidate?.confidence ?? 0, 0.78)
    }

    func testPublicResolverRetriesSpotifyEpisodeNumberTitleWithoutPrefix() throws {
        let oEmbed = #"{"title":"895: Label Maker!"}"#
        let spotifyEmbedPage = #"""
        <html><body>
          <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"episode","name":"895: Label Maker!","title":"895: Label Maker!","subtitle":"This American Life","releaseDate":{"isoString":"2026-08-17T00:00:00Z"},"duration":3464385}}}}}}</script>
        </body></html>
        """#
        let appleMatch = #"""
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "kind": "podcast-episode",
            "trackId": 1000783492833,
            "trackName": "Label Maker!",
            "collectionName": "This American Life",
            "trackViewUrl": "https://podcasts.apple.com/us/podcast/this-american-life/id201671138?i=1000783492833",
            "episodeUrl": "https://cdn.example.com/label-maker.mp3",
            "trackTimeMillis": 3576000,
            "releaseDate": "2026-08-17T00:00:00Z"
          }]
        }
        """#
        let request = LinkResolutionRequest(
            id: "request-spotify-numbered-title",
            inputURL: "https://open.spotify.com/episode/labelmaker123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" {
                return Data(oEmbed.utf8)
            }
            if url.path == "/embed/episode/labelmaker123" {
                return Data(spotifyEmbedPage.utf8)
            }
            let searchTerm = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "term" })?
                .value
            switch searchTerm {
            case "895: Label Maker!":
                return Data(#"{"resultCount":0,"results":[]}"#.utf8)
            case "Label Maker!":
                return Data(appleMatch.utf8)
            default:
                XCTFail("Unexpected resolver URL: \(url)")
                return Data()
            }
        }).resolve(request)

        XCTAssertEqual(result.status, .playable)
        XCTAssertEqual(result.selectedCandidate?.title, "Label Maker!")
        XCTAssertEqual(result.selectedCandidate?.showTitle, "This American Life")
        XCTAssertEqual(result.selectedCandidate?.audioURL, "https://cdn.example.com/label-maker.mp3")
        XCTAssertGreaterThanOrEqual(result.selectedCandidate?.confidence ?? 0, 0.78)
    }

    func testPublicResolverDoesNotAutoSelectExactTitleFromConflictingShow() throws {
        let oEmbed = #"{"title":"Shared Episode","showTitle":"Expected Show"}"#
        let appleSearch = #"""
        {
          "resultCount": 1,
          "results": [{
            "wrapperType": "podcastEpisode",
            "trackName": "Shared Episode",
            "collectionName": "Different Show",
            "episodeUrl": "https://cdn.example.com/different-show.mp3"
          }]
        }
        """#
        let request = LinkResolutionRequest(
            id: "request-spotify-conflicting-show",
            inputURL: "https://open.spotify.com/episode/conflict123",
            sourceSurface: "paste",
            createdAt: Date(timeIntervalSince1970: 1)
        )

        let result = try PublicPodcastLinkResolver(fetch: { url in
            if url.path == "/oembed" { return Data(oEmbed.utf8) }
            if url.host?.contains("spotify.com") == true { return Data() }
            return Data(appleSearch.utf8)
        }).resolve(request)

        XCTAssertEqual(result.status, .needsReview)
        XCTAssertNil(result.selectedCandidate)
        XCTAssertEqual(result.candidates.map(\.showTitle), ["Different Show"])
        XCTAssertEqual(result.failureReason, "spotify_episode_match_ambiguous")
    }
}
