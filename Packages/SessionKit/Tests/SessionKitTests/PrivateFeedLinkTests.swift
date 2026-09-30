import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest
import ZIPFoundation

/// Paid podcast feeds put a per-subscriber secret in the feed and audio links. A shared
/// packet must never carry that secret, or anyone holding the packet can listen as the sender.
final class PrivateFeedLinkTests: XCTestCase {
    private struct PrivateFeed {
        let name: String
        let secret: String
        let feedURL: String
        let episodeURL: String
        let enclosureURL: String
        let episodeGUID: String
        /// The episode page when it holds no secret; nil when the page link itself can grant access.
        let publicEpisodeURL: String?
    }

    private let privateFeeds: [PrivateFeed] = [
        PrivateFeed(
            name: "Patreon query token",
            secret: "pAtReOnSeCrEt7f3a9c2e41b8d6",
            feedURL: "https://www.patreon.com/rss/someshow?auth=pAtReOnSeCrEt7f3a9c2e41b8d6",
            episodeURL: "https://www.patreon.com/posts/episode-12-98765",
            enclosureURL: "https://c10.patreonusercontent.com/4/patreon-media/p/post/98765/a1/episode.mp3?token-time=1790000000&token-hash=pAtReOnSeCrEt7f3a9c2e41b8d6",
            episodeGUID: "https://c10.patreonusercontent.com/4/patreon-media/p/post/98765/a1/episode.mp3?token-time=1790000000&token-hash=pAtReOnSeCrEt7f3a9c2e41b8d6",
            publicEpisodeURL: nil
        ),
        PrivateFeed(
            name: "Substack private path token",
            secret: "5b2d8e0c9a7f4e1d8c3b6a5f2e9d0c7b",
            feedURL: "https://api.substack.com/feed/podcast/424242/private/5b2d8e0c9a7f4e1d8c3b6a5f2e9d0c7b.rss",
            episodeURL: "https://someshow.substack.com/p/episode-12",
            enclosureURL: "https://api.substack.com/feed/podcast/171717/5b2d8e0c9a7f4e1d8c3b6a5f2e9d0c7b.mp3",
            episodeGUID: "substack:post:171717",
            publicEpisodeURL: "https://someshow.substack.com/p/episode-12"
        ),
        PrivateFeed(
            name: "Userinfo password",
            secret: "hunter2UserInfoSecret",
            feedURL: "https://listener:hunter2UserInfoSecret@feeds.example.org/members-show.rss",
            episodeURL: "https://listener:hunter2UserInfoSecret@feeds.example.org/episodes/12",
            enclosureURL: "https://listener:hunter2UserInfoSecret@media.example.org/episodes/12.mp3",
            episodeGUID: "example-episode-12",
            publicEpisodeURL: nil
        ),
        PrivateFeed(
            name: "Signed audio link on an unknown host",
            secret: "Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq",
            feedURL: "https://feeds.example.net/show.rss?key=Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq",
            episodeURL: "https://example.net/show/episode-12",
            enclosureURL: "https://cdn.example.net/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode-12.mp3",
            episodeGUID: "https://cdn.example.net/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode-12.mp3",
            publicEpisodeURL: "https://example.net/show/episode-12"
        )
    ]

    func testPacketFromAPrivateFeedCarriesNoSubscriberSecretAnywhere() throws {
        for feed in privateFeeds {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let packageURL = root.appendingPathComponent("private.spokenmargins")

            _ = try exportPacket(try prepare(feed), to: packageURL)

            let archive = try Archive(url: packageURL, accessMode: .read)
            for entry in archive {
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                XCTAssertFalse(
                    String(decoding: data, as: UTF8.self).contains(feed.secret),
                    "\(feed.name): \(entry.path) leaks the subscriber secret"
                )
            }
        }
    }

    func testPacketFromAPrivateFeedStillImportsAndIdentifiesTheEpisode() throws {
        for feed in privateFeeds {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let packageURL = root.appendingPathComponent("private.spokenmargins")
            _ = try exportPacket(try prepare(feed), to: packageURL)

            let verified = try SpokenMarginsPackageArchive.read(
                from: packageURL,
                extractingAssetsTo: root.appendingPathComponent("assets")
            )
            let item = verified.manifest.item
            XCTAssertEqual(item.canonicalURL, feed.publicEpisodeURL, feed.name)
            XCTAssertEqual(item.originalURL, feed.publicEpisodeURL, feed.name)
            XCTAssertNil(item.enclosureURL, feed.name)
            XCTAssertNil(item.source, feed.name)
            XCTAssertEqual(
                verified.manifest.itemTransport.kind,
                feed.publicEpisodeURL == nil ? .recipientSupplied : .reference,
                feed.name
            )
            XCTAssertEqual(item.title, "Episode 12: The Private One", feed.name)
            XCTAssertEqual(item.showTitle, "Members Only Show", feed.name)
            XCTAssertEqual(item.durationMs, 3_600_000, feed.name)
            XCTAssertEqual(item.publishedAt, "2026-09-01T00:00:00Z", feed.name)
            XCTAssertNil(verified.editionFingerprintSpines.first?.canonicalURL, feed.name)
            if feed.episodeGUID.hasPrefix("https://") {
                XCTAssertNil(item.episodeGUID, "\(feed.name): a GUID that is a private link must not travel")
            } else {
                XCTAssertEqual(item.episodeGUID, feed.episodeGUID, "\(feed.name): a plain GUID is how the recipient finds the episode")
            }
        }
    }

    func testPacketFromAPublicFeedKeepsItsLinks() throws {
        let enclosure = "https://traffic.megaphone.fm/ABC1234567890.mp3?updated=1790000000"
        let item = SharedItemIdentity(
            itemType: .podcast,
            canonicalURL: "https://example.com/podcast/episode-12",
            originalURL: "https://example.com/podcast/episode-12",
            title: "Episode 12",
            showTitle: "Public Show",
            episodeGUID: "https://example.com/podcast/episode-12",
            enclosureURL: enclosure,
            durationMs: 3_600_000,
            source: SharedSourceIdentity(sourceType: .podcastFeed, canonicalURL: "https://feeds.megaphone.fm/PUBLIC123")
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "public-package",
            createdAt: fixedDate,
            item: item,
            itemTransportSelection: .reference,
            selections: [selection()]
        )
        XCTAssertEqual(prepared.manifest.item, item)
        XCTAssertEqual(prepared.manifest.itemTransport.kind, .reference)
    }

    func testLinkPolicyKeepsCommonPublicPodcastHostsShareable() {
        let publicLinks = [
            "https://traffic.megaphone.fm/ABC1234567890.mp3?updated=1790000000",
            "https://cdn.simplecast.com/audio/8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f/episodes/1b2c3d4e-5f60-4718-293a-4b5c6d7e8f90/audio/128/default.mp3",
            "https://traffic.omny.fm/d/clips/8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f/1b2c3d4e-5f60-4718-293a-4b5c6d7e8f90/audio.mp3?utm_source=Podcast&in_playlist=2c3d4e5f-6071-4829-3a4b-5c6d7e8f9001",
            "https://sphinx.acast.com/p/open/s/5f1e2d3c4b5a697887766554/e/64a1b2c3d4e5f60718293a4b/media.mp3",
            "https://www.buzzsprout.com/123456/12345678-episode-title.mp3",
            "https://rss.art19.com/episodes/8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f.mp3",
            "https://dts.podtrac.com/redirect.mp3/chrt.fm/track/ABC123/traffic.megaphone.fm/XYZ9876543210.mp3",
            "https://anchor.fm/s/abc123/podcast/play/12345678/https%3A%2F%2Fd3ctxlq1ktw2nl.cloudfront.net%2Fstaging%2F2026-9-1%2F12345678-44100-2-abcdef1234567890.m4a"
        ]
        for link in publicLinks {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(link), link, link)
        }
        XCTAssertEqual(ShareableLinkPolicy.shareableLink("http://example.com/essay"), "http://example.com/essay")
    }

    /// #209: Amperwave (Audacy) feeds from Apple's top charts end in 32 hex digits without
    /// hyphens, which `UUID(uuidString:)` rejects, so they were stripped from packets as private.
    /// The exemption is scoped to that public feed host; the same shape elsewhere stays private.
    func testPublicAmperwaveFeedKeepsItsLinkButTheSameShapeElsewhereStaysPrivate() {
        let publicFeeds = [
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f",
            "https://rss.amperwave.net/v2/feed/audacynetwork/e69da14a26973f1dc761432876205254"
        ]
        for feed in publicFeeds {
            XCTAssertEqual(ShareableLinkPolicy.shareableLink(feed), feed, feed)
        }
        let stillPrivate = [
            // A private token of the same shape on any other host.
            "https://feeds.example.net/v2/feed/network/16aa3c6bf526fae9db63070c73cad09f",
            // Longer than a hyphenless UUID, or not hex: still a secret on Amperwave too.
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f16aa3c6b",
            "https://rss.amperwave.net/v2/feed/audacynetwork/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZn",
            // Private markers and credential parameters are never exempt.
            "https://rss.amperwave.net/v2/feed/private/16aa3c6bf526fae9db63070c73cad09f",
            "https://rss.amperwave.net/v2/feed/audacynetwork/16aa3c6bf526fae9db63070c73cad09f?token=abc"
        ]
        for link in stillPrivate {
            XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
        }
    }

    func testLinkPolicyRejectsLinksThatCanGrantAccess() {
        let privateLinks = [
            "https://www.patreon.com/rss/someshow?auth=abc",
            "https://feeds.supercast.com/episodes/abc",
            "https://api.substack.com/feed/podcast/424242/private/abc.rss",
            "https://user:pass@example.com/feed.rss",
            "https://example.com/feed.rss?token=short",
            "https://example.com/feed.rss?X-Amz-Signature=abc&X-Amz-Expires=300",
            "https://example.com/audio.mp3?Policy=abc&Key-Pair-Id=def",
            "https://example.com/premium/feed.rss",
            "https://cdn.example.net/Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq/episode.mp3",
            "https://example.com/feed.rss?s=Zk9xQ2hTb2tlbjEyMzQ1Njc4OTBhYmNkZWZnaGlq==",
            "file:///var/mobile/Containers/Data/Application/ABC/Library/episode.mp3",
            "not a link"
        ]
        for link in privateLinks {
            XCTAssertNil(ShareableLinkPolicy.shareableLink(link), link)
        }
    }

    func testEpisodeGUIDIsKeptUnlessItIsAPrivateLink() {
        XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID("patreon-98765"), "patreon-98765")
        XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID("8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f"), "8f2c1c9e-1a2b-4c3d-9e8f-0a1b2c3d4e5f")
        XCTAssertEqual(ShareableLinkPolicy.shareableEpisodeGUID("https://example.com/?p=123"), "https://example.com/?p=123")
        XCTAssertNil(ShareableLinkPolicy.shareableEpisodeGUID("https://www.patreon.com/posts/98765?token=abc"))
        XCTAssertNil(ShareableLinkPolicy.shareableEpisodeGUID("http://user:secret@example.com/episode"))
    }

    private func prepare(_ feed: PrivateFeed) throws -> PreparedSpokenMarginsPackage {
        let item = SharedItemIdentity(
            itemType: .podcast,
            canonicalURL: feed.episodeURL,
            originalURL: feed.episodeURL,
            title: "Episode 12: The Private One",
            showTitle: "Members Only Show",
            episodeGUID: feed.episodeGUID,
            enclosureURL: feed.enclosureURL,
            publishedAt: "2026-09-01T00:00:00Z",
            durationMs: 3_600_000,
            source: SharedSourceIdentity(sourceType: .podcastFeed, canonicalURL: feed.feedURL, title: "Members Only Show")
        )
        let spine = EditionFingerprintSpineArtifact(
            id: "spine-1",
            itemId: "episode-12",
            canonicalURL: feed.enclosureURL,
            episodeGUID: feed.episodeGUID,
            producingEditionDurationMs: 3_600_000,
            createdAt: fixedDate,
            landmarks: []
        )
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "private-package",
            createdAt: fixedDate,
            item: item,
            itemTransportSelection: .reference,
            selections: [selection()],
            fingerprintSpines: [spine]
        )
    }

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
            .appendingPathComponent("PrivateFeedLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
