import Foundation
import XCTest
import SessionKit
@testable import SessionKitFeeds

/// #452: pick the episode a shared podcast Margin belongs to from a feed the recipient pastes.
final class SharedEpisodeFeedMatcherTests: XCTestCase {
    // MARK: Duration from the feed

    func testITunesDurationIsReadInClockAndSecondsForms() throws {
        let parsed = try FeedParser().parse(data: Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>T</title>
        <item><title>Clock</title><guid>a</guid><enclosure url="https://example.com/a.mp3" type="audio/mpeg"/><itunes:duration>1:02:03</itunes:duration></item>
        <item><title>Minutes</title><guid>b</guid><enclosure url="https://example.com/b.mp3" type="audio/mpeg"/><itunes:duration>45:30</itunes:duration></item>
        <item><title>Seconds</title><guid>c</guid><enclosure url="https://example.com/c.mp3" type="audio/mpeg"/><itunes:duration>3723</itunes:duration></item>
        <item><title>Missing</title><guid>d</guid><enclosure url="https://example.com/d.mp3" type="audio/mpeg"/></item>
        <item><title>Garbage</title><guid>e</guid><enclosure url="https://example.com/e.mp3" type="audio/mpeg"/><itunes:duration>about an hour</itunes:duration></item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(parsed.items.map(\.durationMs), [3_723_000, 2_730_000, 3_723_000, nil, nil])
    }

    // MARK: Private source

    func testPrivatePodcastSourceIsRecognisedFromTheManifestAlone() {
        let privatePodcast = manifest(SharedItemIdentity(itemType: .podcast, title: "Bonus 12", durationMs: 1_800_000), .recipientSupplied)
        XCTAssertTrue(SharedEpisodeFeedMatcher.isPrivatePodcastSource(privatePodcast))

        let publicPodcast = manifest(SharedItemIdentity(
            itemType: .podcast,
            canonicalURL: "https://example.com/show/12",
            title: "Episode 12",
            enclosureURL: "https://cdn.example.com/12.mp3"
        ), .reference)
        XCTAssertFalse(SharedEpisodeFeedMatcher.isPrivatePodcastSource(publicPodcast))

        let publicEnclosureOnly = manifest(SharedItemIdentity(
            itemType: .podcast,
            title: "Episode 12",
            enclosureURL: "https://cdn.example.com/12.mp3"
        ), .recipientSupplied)
        XCTAssertFalse(SharedEpisodeFeedMatcher.isPrivatePodcastSource(publicEnclosureOnly), "an episode link means the recipient can reach it")

        let article = manifest(SharedItemIdentity(itemType: .text, title: "An essay"), .recipientSupplied)
        XCTAssertFalse(SharedEpisodeFeedMatcher.isPrivatePodcastSource(article))
    }

    // MARK: Matching

    func testMatchesByGUIDWhenThePacketHasOne() {
        let shared = SharedItemIdentity(itemType: .podcast, title: "A different title", episodeGUID: "guid-2")
        XCTAssertEqual(SharedEpisodeFeedMatcher.match(shared, in: feed).matchedID, "guid-2")
    }

    func testMatchesByTitleDayAndDurationWithoutAGUID() {
        let shared = SharedItemIdentity(
            itemType: .podcast,
            title: "  bonus: THE Long Interview!  ",
            publishedAt: "2026-09-10T08:00:00Z",
            durationMs: 3_500_000
        )
        XCTAssertEqual(SharedEpisodeFeedMatcher.match(shared, in: feed).matchedID, "guid-2")
    }

    func testNoMatchWhenTitleDayOrDurationDisagree() {
        let otherTitle = SharedItemIdentity(itemType: .podcast, title: "Not in this feed", publishedAt: "2026-09-10")
        XCTAssertEqual(SharedEpisodeFeedMatcher.match(otherTitle, in: feed), .none)

        let otherDay = SharedItemIdentity(itemType: .podcast, title: "Bonus: The Long Interview", publishedAt: "2026-09-11T08:00:00Z")
        XCTAssertEqual(SharedEpisodeFeedMatcher.match(otherDay, in: feed), .none)

        let otherLength = SharedItemIdentity(
            itemType: .podcast,
            title: "Bonus: The Long Interview",
            publishedAt: "2026-09-10",
            durationMs: 1_200_000
        )
        XCTAssertEqual(SharedEpisodeFeedMatcher.match(otherLength, in: feed), .none, "20 minutes against an hour is another episode")

        let unknownGUID = SharedItemIdentity(itemType: .podcast, title: "Nothing like it", episodeGUID: "guid-404")
        XCTAssertEqual(SharedEpisodeFeedMatcher.match(unknownGUID, in: feed), .none)
    }

    func testTwoSameTitledEpisodesOnTheSameDayAreSeveralNeverAGuess() {
        let shared = SharedItemIdentity(itemType: .podcast, title: "Live Q&A", publishedAt: "2026-09-20T12:00:00Z")
        guard case .several(let candidates) = SharedEpisodeFeedMatcher.match(shared, in: feed) else {
            return XCTFail("expected several candidates")
        }
        XCTAssertEqual(candidates.map(\.id), ["guid-3", "guid-4"])
    }

    // MARK: Fixtures

    private var feed: ParsedFeed {
        let parsed = try? FeedParser().parse(data: Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Private show</title>
        <item><title>Episode 1</title><guid>guid-1</guid><pubDate>Mon, 01 Sep 2026 10:00:00 +0000</pubDate>
          <enclosure url="https://private.example.com/1.mp3?token=x" type="audio/mpeg"/><itunes:duration>30:00</itunes:duration></item>
        <item><title>Bonus: The Long Interview</title><guid>guid-2</guid><pubDate>Wed, 10 Sep 2026 06:30:00 +0000</pubDate>
          <enclosure url="https://private.example.com/2.mp3?token=x" type="audio/mpeg"/><itunes:duration>01:00:00</itunes:duration></item>
        <item><title>Live Q&amp;A</title><guid>guid-3</guid><pubDate>Sun, 20 Sep 2026 09:00:00 +0000</pubDate>
          <enclosure url="https://private.example.com/3.mp3?token=x" type="audio/mpeg"/></item>
        <item><title>Live Q&amp;A</title><guid>guid-4</guid><pubDate>Sun, 20 Sep 2026 18:00:00 +0000</pubDate>
          <enclosure url="https://private.example.com/4.mp3?token=x" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8))
        XCTAssertEqual(parsed?.items.count, 4)
        return parsed ?? ParsedFeed(format: .rss, title: "", homePageURL: nil, feedURL: nil, items: [])
    }

    private func manifest(_ item: SharedItemIdentity, _ transport: SharedItemTransportKind) -> SpokenMarginsPackageManifest {
        SpokenMarginsPackageManifest(
            packageId: "pkg",
            createdAt: Date(timeIntervalSince1970: 0),
            item: item,
            itemTransport: SharedItemTransport(kind: transport),
            artifacts: []
        )
    }
}

private extension SharedEpisodeFeedMatcher.Match {
    var matchedID: String? {
        if case .matched(let item) = self { return item.id }
        return nil
    }
}
