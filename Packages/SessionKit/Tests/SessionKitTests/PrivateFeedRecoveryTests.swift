import Foundation
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitSharing
import XCTest
import ZIPFoundation

/// #454: a friend who gets Margins from a private podcast feed pastes their own feed link and the app
/// adds the episode. These pin the host-side half: the packet's words find the episode the friend's
/// feed lists, and the feed link itself ends up in nothing the friend later shares.
final class PrivateFeedRecoveryTests: XCTestCase {
    // MARK: A packet with no link or GUID finds its episode by its words

    private let packet = SharedItemIdentity(
        itemType: .podcast,
        title: "Episode 12: The Private One",
        showTitle: "Members Only Show",
        publishedAt: "2026-09-01T00:00:00Z",
        durationMs: 3_600_000
    )

    private func local(
        title: String = "Episode 12: The Private One",
        show: String? = "Members Only Show",
        published: String? = "2026-09-01T00:00:00Z",
        duration: Int? = 3_600_000,
        type: SharedItemType = .podcast
    ) -> SharedItemIdentity {
        SharedItemIdentity(itemType: type, title: title, showTitle: show, publishedAt: published, durationMs: duration)
    }

    func testTheSameTitleMatchesHoweverTheTwoFeedsSpellIt() {
        let spellings = [
            "Episode 12: The Private One",
            "episode 12 the private one",
            "  EPISODE 12 — The Private One!  ",
            "Episode\u{00A0}12:   The   Private One",
            "Ｅｐｉｓｏｄｅ 12: The Private One",
            "Épisode 12: The Private One"
        ]
        for title in spellings {
            XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(packet, local(title: title)), title)
        }
    }

    func testADifferentTitleNeverMatches() {
        let others = [
            "Episode 13: The Private One",
            "Episode 12: The Private One (Bonus)",
            "Episode 12",
            "The Private One",
            "",
            "   "
        ]
        for title in others {
            XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(packet, local(title: title)), "'\(title)'")
        }
        let untitled = SharedItemIdentity(itemType: .podcast, title: "  ", showTitle: "Members Only Show", publishedAt: "2026-09-01T00:00:00Z")
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(untitled, local(title: "  ")), "two blank titles name nothing")
    }

    func testTheShowOrTheDayMustBackTheTitleAndNeitherMayDisagree() {
        let cases: [(name: String, local: SharedItemIdentity, matches: Bool)] = [
            ("show only", local(published: nil), true),
            ("day only", local(show: nil), true),
            ("neither", local(show: nil, published: nil), false),
            ("blank show and no day", local(show: "  ", published: nil), false),
            ("another show", local(show: "Another Show"), false),
            ("same show, another day", local(published: "2026-09-02T00:00:00Z"), false),
            ("no show, another day", local(show: nil, published: "2026-09-02T00:00:00Z"), false),
            ("show differs even when the day agrees", local(show: "Another Show", published: "2026-09-01T00:00:00Z"), false),
            ("same instant written in another zone", local(show: nil, published: "2026-08-31T20:00:00-04:00"), true),
            ("RSS date", local(show: nil, published: "Tue, 01 Sep 2026 10:00:00 +0000"), true),
            ("a bare date", local(show: nil, published: "2026-09-01"), true),
            ("a day that cannot be read neither agrees nor disagrees", local(published: "last Tuesday"), true),
            ("show spelled in capitals", local(show: " MEMBERS only show "), true)
        ]
        for item in cases {
            XCTAssertEqual(ImportedItemResolver.canRepresentSameWork(packet, item.local), item.matches, item.name)
        }
        let entities = SharedItemIdentity(itemType: .podcast, title: "E", showTitle: "News &amp; Views")
        let decoded = SharedItemIdentity(itemType: .podcast, title: "E", showTitle: "News & Views")
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(entities, decoded), "the two import paths clean a show title differently")
    }

    func testALengthMoreThanTwentyPercentApartIsAnotherCut() {
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(packet, local(duration: 3_780_000)), "5% apart is different ad fill")
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(packet, local(duration: nil)), "an unknown length keeps the match")
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(packet, local(duration: 4_800_000)), "25% apart")
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(packet, local(duration: 120_000)), "a trailer")
    }

    func testOnlyAPacketWithNoLinkAndNoGUIDIsMatchedByItsWords() {
        // A GUID or a link on the packet is checked on its own, as before; the words never stand in for them.
        let withGUID = SharedItemIdentity(itemType: .podcast, title: packet.title, showTitle: packet.showTitle, episodeGUID: "ep-12")
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(withGUID, local()))
        let withPage = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/12", title: packet.title, showTitle: packet.showTitle)
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(withPage, local()))
        let withAudio = SharedItemIdentity(itemType: .podcast, title: packet.title, showTitle: packet.showTitle, enclosureURL: "https://cdn.example.com/12.mp3")
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(withAudio, local()))
        let withFeed = SharedItemIdentity(
            itemType: .podcast, title: packet.title, showTitle: packet.showTitle,
            source: SharedSourceIdentity(sourceType: .podcastFeed, canonicalURL: "https://feeds.example.com/show.xml"))
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(withFeed, local()))
        let blankLinks = SharedItemIdentity(itemType: .podcast, canonicalURL: " ", title: packet.title, showTitle: packet.showTitle, episodeGUID: "")
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(blankLinks, local()))
    }

    func testOnlyAPodcastIsMatchedByItsWords() {
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(packet, local(type: .text)))
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(packet, local(type: .other)))
        let article = SharedItemIdentity(itemType: .text, title: packet.title, showTitle: packet.showTitle)
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(article, local()))
    }

    // MARK: From a private feed packet to the episode in the friend's own feed

    private let senderFeedSecret = "FEEDsecretSender1a2b3c4d"
    private let recipientFeedSecret = "FEEDsecretFriend9z8y7x6w"
    private let senderEnclosureSecret = "ENCLOSUREsecretSender5e6f7g8h"
    private let recipientEnclosureSecret = "ENCLOSUREsecretFriend1i2j3k4l"

    private func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
    }

    private func enclosure(post: Int, secret: String) -> String {
        "https://c10.patreonusercontent.com/4/patreon-media/p/post/\(post)/a1/episode.mp3?token-time=1790000000&token-hash=\(secret)"
    }

    /// The packet the sender's app writes for episode 12 of a Patreon-style feed: every link and the
    /// link-shaped GUID are withheld, so only the words are left.
    private func senderPacket() throws -> SpokenMarginsPackageManifest {
        let link = enclosure(post: 98765, secret: senderEnclosureSecret)
        var item = Item(
            id: "sender-item", title: "Episode 12: The Private One", mediaType: "transcript_backed_media",
            text: nil, externalReference: "https://www.patreon.com/posts/episode-12-98765", status: "ready",
            externalReferenceType: "url", media: ItemMedia(sourceType: .remoteStream, url: link, durationMs: 3_600_000)
        )
        item.episodeGUID = link
        item.showTitle = "Members Only Show"
        item.publishedAt = "2026-09-01T00:00:00Z"
        item.sourceURL = "https://www.patreon.com/rss/someshow?auth=\(senderFeedSecret)"
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "recovery-package",
            createdAt: fixedDate,
            item: SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil]),
            itemTransportSelection: .reference,
            selections: [selection()]
        ).manifest
    }

    /// The friend's feed: a different token in every link, an earlier episode listed first, and a
    /// bonus episode with the same show but another title.
    private func friendFeed() throws -> ParsedFeed {
        try FeedParser().parse(data: Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
        <title>Members Only Show</title>
        <link>https://www.patreon.com/someshow</link>
        <item><title>Episode 13: The Next One</title><link>https://www.patreon.com/posts/episode-13-98766</link>
          <guid isPermaLink="false">\(xmlEscaped(enclosure(post: 98766, secret: recipientEnclosureSecret)))</guid>
          <pubDate>Tue, 08 Sep 2026 00:00:00 +0000</pubDate><itunes:duration>3000</itunes:duration>
          <enclosure url="\(xmlEscaped(enclosure(post: 98766, secret: recipientEnclosureSecret)))" type="audio/mpeg"/></item>
        <item><title>Episode 12: The Private One</title><link>https://www.patreon.com/posts/episode-12-98765</link>
          <guid isPermaLink="false">\(xmlEscaped(enclosure(post: 98765, secret: recipientEnclosureSecret)))</guid>
          <pubDate>Tue, 01 Sep 2026 00:00:00 +0000</pubDate><itunes:duration>1:03:00</itunes:duration>
          <enclosure url="\(xmlEscaped(enclosure(post: 98765, secret: recipientEnclosureSecret)))" type="audio/mpeg"/></item>
        <item><title>Episode 11: The Earlier One</title><link>https://www.patreon.com/posts/episode-11-98764</link>
          <guid isPermaLink="false">\(xmlEscaped(enclosure(post: 98764, secret: recipientEnclosureSecret)))</guid>
          <pubDate>Tue, 25 Aug 2026 00:00:00 +0000</pubDate><itunes:duration>3500</itunes:duration>
          <enclosure url="\(xmlEscaped(enclosure(post: 98764, secret: recipientEnclosureSecret)))" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8))
    }

    /// What the app saves when the friend's episode is added: the entry's links and the show's title.
    private func recoveredItem(from feedItem: ParsedFeedItem, showTitle: String) throws -> Item {
        let entry = try XCTUnwrap(SharedEpisodeFeedEntry.entry(for: feedItem))
        var item = Item(
            id: "recovered-item", title: entry.title, mediaType: "transcript_backed_media", text: nil,
            externalReference: entry.canonicalURL, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: entry.audioURL, durationMs: nil)
        )
        entry.fillEpisodeIdentity(of: &item, showTitle: showTitle)
        return item
    }

    func testThePacketIsPrivateAndTheFriendsFeedHoldsExactlyOneMatchingEpisode() throws {
        let manifest = try senderPacket()
        XCTAssertTrue(SharedEpisodeFeedMatcher.isPrivatePodcastSource(manifest))
        XCTAssertNil(manifest.item.episodeGUID, "a GUID that is a private link must not travel")
        guard case .matched(let episode) = SharedEpisodeFeedMatcher.match(manifest.item, in: try friendFeed()) else {
            return XCTFail("the friend's feed lists the episode once")
        }
        XCTAssertEqual(episode.title, "Episode 12: The Private One")
        XCTAssertEqual(episode.durationMs, 3_780_000)
    }

    func testTheEpisodeAddedFromTheFriendsFeedIsTheOneThePendingImportFinds() throws {
        let manifest = try senderPacket()
        let feed = try friendFeed()
        guard case .matched(let episode) = SharedEpisodeFeedMatcher.match(manifest.item, in: feed) else {
            return XCTFail("the friend's feed lists the episode once")
        }
        let recovered = try recoveredItem(from: episode, showTitle: feed.title)
        let earlier = try recoveredItem(
            from: try XCTUnwrap(feed.items.first { $0.title.hasPrefix("Episode 11") }), showTitle: feed.title)
        var earlierItem = earlier
        earlierItem.id = "earlier-item"

        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(manifest.item, SharedItemIdentityBuilder.localIdentity(for: recovered)))
        XCTAssertEqual(
            SharedPacketItemMatcher.matchingItemId(for: manifest.item, among: [earlierItem, recovered]),
            "recovered-item", "the friend's other episodes of the same show do not match")
        XCTAssertNil(SharedPacketItemMatcher.matchingItemId(for: manifest.item, among: [earlierItem]))
    }

    func testTheEpisodeEntryCarriesTheEpisodesOwnIdentityAndNoFeedLink() throws {
        let feed = try friendFeed()
        let episode = try XCTUnwrap(feed.items.first { $0.title.hasPrefix("Episode 12") })
        let entry = try XCTUnwrap(SharedEpisodeFeedEntry.entry(for: episode))
        XCTAssertEqual(entry.subscriptionId, SharedEpisodeFeedEntry.subscriptionId)
        XCTAssertEqual(entry.title, "Episode 12: The Private One")
        XCTAssertEqual(entry.canonicalURL, "https://www.patreon.com/posts/episode-12-98765")
        XCTAssertEqual(entry.audioURL, enclosure(post: 98765, secret: recipientEnclosureSecret))
        XCTAssertEqual(entry.episodeGUID, enclosure(post: 98765, secret: recipientEnclosureSecret))
        XCTAssertEqual(entry.audioDurationMs, 3_780_000)
        XCTAssertNil(SharedEpisodeFeedEntry.entry(for: ParsedFeedItem(
            id: "no-audio", title: "A text post", url: "", publishedAt: nil, audioURL: nil)), "nothing to listen to, nothing to add")
        XCTAssertNotNil(SharedEpisodeFeedEntry.entry(for: ParsedFeedItem(
            id: "page-only", title: "Page only", url: "https://example.com/p", publishedAt: nil, audioURL: nil)))
    }

    // MARK: The pasted feed link stays out of everything the friend shares

    func testNothingTheFriendSharesLaterCarriesTheFeedLinkOrAnyTokenFromIt() throws {
        let feedLink = "https://www.patreon.com/rss/someshow?auth=\(recipientFeedSecret)"
        let feed = try friendFeed()
        let episode = try XCTUnwrap(feed.items.first { $0.title.hasPrefix("Episode 12") })
        var recovered = try recoveredItem(from: episode, showTitle: feed.title)
        recovered.media?.durationMs = 3_780_000

        // The item, as saved, holds the episode's own links and not the feed link.
        let saved = String(decoding: try JSONEncoder().encode(recovered), as: UTF8.self)
        XCTAssertFalse(saved.contains(recipientFeedSecret), "the pasted feed link is not stored on the item")
        XCTAssertFalse(saved.contains(feedLink))

        // Shared on, it is the same private episode again: no link, no secret of either kind.
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "friend-reshare",
            createdAt: fixedDate,
            item: SharedItemIdentityBuilder.exportIdentity(for: recovered, draftEditionDigests: [nil]),
            itemTransportSelection: .reference,
            selections: [selection()]
        )
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("friend.spokenmargins")
        let manifest = try exportPacket(prepared, to: url)
        XCTAssertTrue(SharedEpisodeFeedMatcher.isPrivatePodcastSource(manifest))
        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let text = String(decoding: data, as: UTF8.self)
            for secret in [recipientFeedSecret, recipientEnclosureSecret, senderFeedSecret, senderEnclosureSecret] {
                XCTAssertFalse(text.contains(secret), "\(entry.path) leaks \(secret)")
            }
        }
    }

    // MARK: Helpers

    private func selection() -> ReviewedInterjectionSelection {
        ReviewedInterjectionSelection(
            packageScopedId: "margin-001",
            revision: InterjectionShareRevision(
                id: "revision-approved", interjectionId: "note", itemId: "item",
                sessionId: "session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought.",
                anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
            ),
            anchor: .init(anchorType: .media, mediaTimeMs: 600_000),
            representation: .textOnly
        )
    }

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_777_000_000) }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateFeedRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
