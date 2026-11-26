import Foundation
import XCTest
import SessionKit
@testable import SessionKitFeeds
import SessionKitSharing

/// #5340: an episode whose feed asks directories not to list it (`<itunes:block>Yes</itunes:block>`, Apple's convention:
/// https://podcasters.apple.com/support/823-podcast-requirements), or that came from a feed whose own address holds an
/// access secret, never sends its audio or feed link on its own. An unlisted or self-hosted feed with neither signal
/// shares as before.
final class AutomaticSourceAccessTests: XCTestCase {
    // MARK: Reading the feed

    private static func rss(channelBlock: String? = nil, blockAfterItems: Bool = false, items: [(guid: String, block: String?)]) -> Data {
        let channelTag = channelBlock.map { "<itunes:block>\($0)</itunes:block>" } ?? ""
        let entries = items.map { item in
            """
            <item><title>Episode \(item.guid)</title><guid>\(item.guid)</guid>\
            <enclosure url="https://media.example.com/\(item.guid).mp3" type="audio/mpeg"/>\
            \(item.block.map { "<itunes:block>\($0)</itunes:block>" } ?? "")</item>
            """
        }.joined()
        return Data("""
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title>\
        \(blockAfterItems ? "" : channelTag)\(entries)\(blockAfterItems ? channelTag : "")</channel></rss>
        """.utf8)
    }

    func testEpisodeLevelBlockAppliesToThatEpisodeOnly() throws {
        let feed = try FeedParser().parse(data: Self.rss(items: [("a", "Yes"), ("b", nil), ("c", "No")]))
        XCTAssertEqual(feed.items.map(\.publisherBlocked), [true, false, false])
        XCTAssertFalse(feed.publisherBlocked)
    }

    func testShowLevelBlockAppliesToEveryEpisodeWhereverItSits() throws {
        for after in [false, true] {
            let feed = try FeedParser().parse(data: Self.rss(channelBlock: "Yes", blockAfterItems: after, items: [("a", nil), ("b", "No")]))
            XCTAssertTrue(feed.publisherBlocked, "block after items: \(after)")
            XCTAssertEqual(feed.items.map(\.publisherBlocked), [true, true], "block after items: \(after)")
        }
    }

    func testOnlyYesCountsAndCaseAndSpaceDoNot() throws {
        let values: [(String?, Bool)] = [
            (nil, false), ("No", false), ("no", false), ("", false), ("false", false), ("true", false), ("1", false),
            ("Yes", true), ("yes", true), ("YES", true), ("  Yes\n", true),
        ]
        for (value, expected) in values {
            let feed = try FeedParser().parse(data: Self.rss(channelBlock: value, items: [("a", nil)]))
            XCTAssertEqual(feed.items.first?.publisherBlocked, expected, "itunes:block \(value ?? "absent")")
        }
    }

    func testABlockFromAnotherNamespaceIsNotApplesSignal() throws {
        let data = Data("""
        <rss version="2.0" xmlns:googleplay="http://www.google.com/schemas/play-podcasts/1.0"><channel><title>Show</title>
        <googleplay:block>yes</googleplay:block><block>yes</block>
        <item><title>A</title><guid>a</guid><enclosure url="https://media.example.com/a.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8)
        XCTAssertEqual(try FeedParser().parse(data: data).items.map(\.publisherBlocked), [false])
    }

    func testApplesNamespaceUnderAnotherPrefixCountsForTheLinkResolversParser() {
        XCTAssertTrue(PublisherBlockSignal.isBlock("apple:block", namespaceURI: PublisherBlockSignal.appleNamespace, value: "Yes"))
        XCTAssertTrue(PublisherBlockSignal.isBlock("itunes:block", namespaceURI: nil, value: "Yes"))
        XCTAssertFalse(PublisherBlockSignal.isBlock("itunes:explicit", namespaceURI: PublisherBlockSignal.appleNamespace, value: "Yes"))
        XCTAssertFalse(PublisherBlockSignal.isBlock("block", namespaceURI: nil, value: "Yes"))
    }

    func testRecoveryEntryCarriesTheBlock() throws {
        let feed = try FeedParser().parse(data: Self.rss(items: [("a", "Yes"), ("b", nil)]))
        XCTAssertEqual(feed.items.map { SharedEpisodeFeedEntry.entry(for: $0)?.publisherBlocked }, [true, nil])
    }

    // MARK: Carried to the item

    func testEntryCarriesBothRestrictionsToTheItemAndNeverClearsThem() {
        var entry = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://media.example.com/a.mp3", title: "A")
        entry.publisherBlocked = true
        entry.fromPrivateFeed = true
        var item = Self.episode()
        entry.fillEpisodeIdentity(of: &item, showTitle: "Show")
        XCTAssertEqual(item.publisherBlocked, true)
        XCTAssertEqual(item.fromPrivateFeed, true)

        let plain = FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://media.example.com/a.mp3", title: "A")
        plain.fillEpisodeIdentity(of: &item, showTitle: "Show")
        XCTAssertEqual(item.publisherBlocked, true, "a later entry without the tag doesn't lift a known restriction")
        XCTAssertEqual(LibraryItemSummary(item).publisherBlocked, true)
        XCTAssertEqual(LibraryItemSummary(item).fromPrivateFeed, true)
    }

    func testAnItemSavedByThisBuildStillDecodesWithoutTheNewKeysAndKeepsThem() throws {
        var item = Self.episode()
        item.publisherBlocked = true
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(Item.self, from: data).publisherBlocked, true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["publisherBlocked"] = nil
        let older = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(Item.self, from: older).publisherBlocked)
    }

    // MARK: The restriction

    private static let privateFeed = "https://feeds.example.com/show.rss?auth=8f2c1a9b7d3e4f50a6b2c8d1e9f03a7b"
    private static let ordinaryFeed = "https://feeds.example.com/show.rss"
    private static let enclosure = "https://media.example.com/episode-12.mp3"
    private static let page = "https://example.com/show/episode-12"

    private static func episode(
        page: String? = page, enclosure: String = enclosure, feed: String? = ordinaryFeed, guid: String? = "show-ep-12"
    ) -> Item {
        var item = Item(
            id: "episode", title: "Episode 12", mediaType: "transcript_backed_media", text: nil,
            externalReference: page, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: enclosure, durationMs: 3_600_000),
            sourceTitle: "Show", sourceURL: feed
        )
        item.episodeGUID = guid
        item.showTitle = "Show"
        item.publishedAt = "2026-11-20T10:00:00Z"
        return item
    }

    func testRestrictionTable() {
        var blocked = Self.episode()
        blocked.publisherBlocked = true
        var recovered = Self.episode(feed: nil)
        recovered.fromPrivateFeed = true
        var spokenNoteLike = Self.episode(feed: Self.privateFeed)
        spokenNoteLike.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///note.m4a")
        let rows: [(String, Item, AutomaticSourceAccess.Restriction?)] = [
            ("public feed", Self.episode(), nil),
            ("unlisted, self-hosted feed with no tag", Self.episode(feed: "https://me.example.org/podcast.xml"), nil),
            ("added by audio link, no feed known", Self.episode(feed: nil), nil),
            ("feed blocks itself", blocked, .publisherBlocked),
            ("private feed, ordinary enclosure", Self.episode(feed: Self.privateFeed), .privateFeed),
            ("private feed by host", Self.episode(feed: "https://www.patreon.com/rss/show"), .privateFeed),
            ("private feed recorded without its address", recovered, .privateFeed),
            ("a sourceURL that is not a web link", Self.episode(feed: "Imported from Files"), nil),
            ("no web audio to protect", spokenNoteLike, nil),
        ]
        for (name, item, expected) in rows {
            XCTAssertEqual(AutomaticSourceAccess.restriction(of: item), expected, name)
            XCTAssertEqual(AutomaticSourceAccess.restriction(of: LibraryItemSummary(item)), expected, "\(name), summary")
        }
    }

    func testRestrictedItemKeepsItsPageButNotItsAudioOrFeed() {
        let item = Self.episode(feed: Self.privateFeed)
        XCTAssertEqual(AutomaticSourceAccess.sendableLink(Self.page, of: item), Self.page)
        XCTAssertNil(AutomaticSourceAccess.sendableLink(Self.enclosure, of: item))
        XCTAssertNil(AutomaticSourceAccess.sendableLink("HTTPS://MEDIA.example.com/episode-12.mp3#t=3", of: item), "another spelling of the audio link")
        XCTAssertNil(AutomaticSourceAccess.sendableAudioLink(of: item))

        var blocked = Self.episode()
        blocked.publisherBlocked = true
        XCTAssertNil(AutomaticSourceAccess.sendableLink(Self.ordinaryFeed, of: blocked), "a blocked show's feed link")
        XCTAssertNil(AutomaticSourceAccess.sendableLink(Self.enclosure, of: blocked))

        let open = Self.episode()
        XCTAssertEqual(AutomaticSourceAccess.sendableLink(Self.enclosure, of: open), Self.enclosure)
        XCTAssertEqual(AutomaticSourceAccess.sendableAudioLink(of: open), Self.enclosure)
        XCTAssertNil(AutomaticSourceAccess.sendableLink(Self.privateFeed, of: open), "#168 still drops a secret link")
    }

    // MARK: At the export boundary

    func testPacketOfARestrictedEpisodeCarriesNoAudioOrFeedLinkButStillMatchesByGUID() throws {
        let noPage = Self.episode(page: Self.enclosure, feed: Self.privateFeed) // a feed item with no <link> stands in its audio
        var blocked = Self.episode()
        blocked.publisherBlocked = true
        for (name, item, keptPage) in [("private feed, no page", noPage, nil as String?), ("blocked, with page", blocked, Self.page)] {
            let identity = SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil])
            XCTAssertNil(identity.enclosureURL, name)
            XCTAssertEqual(identity.canonicalURL, keptPage, name)
            XCTAssertEqual(identity.originalURL, keptPage, name)
            XCTAssertEqual(identity.episodeGUID, "show-ep-12", name)
            XCTAssertEqual(identity.showTitle, "Show", name)

            let manifest = try Self.manifestJSON(for: identity)
            XCTAssertFalse(manifest.contains("media.example.com"), "\(name): \(manifest)")
            XCTAssertFalse(manifest.contains("feeds.example.com"), name)
            XCTAssertFalse(manifest.contains("8f2c1a9b"), name)
            XCTAssertTrue(manifest.contains("show-ep-12"), name)

            // The recipient's own copy, with its own subscriber link, still matches.
            var theirs = Self.episode(enclosure: "https://media.example.com/episode-12.mp3?u=friend", feed: "https://feeds.example.com/show.rss?auth=friendfriendfriendfriendfriend123")
            theirs.externalReference = nil
            XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(identity, SharedItemIdentityBuilder.localIdentity(for: theirs)), name)
        }
    }

    func testPacketOfAnUnlistedEpisodeWithoutRestrictionIsUnchanged() throws {
        let item = Self.episode(feed: "https://me.example.org/podcast.xml")
        let identity = SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil])
        XCTAssertEqual(identity.enclosureURL, Self.enclosure)
        XCTAssertEqual(identity.canonicalURL, Self.page)
        let prepared = try Self.prepared(for: identity)
        XCTAssertEqual(prepared.manifest.item.enclosureURL, Self.enclosure)
        XCTAssertEqual(prepared.manifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion], "no new capability")
    }

    func testCredentialedGUIDIsStillDroppedForARestrictedEpisode() throws {
        var item = Self.episode(feed: Self.privateFeed, guid: "https://feeds.example.com/ep12?token=8f2c1a9b7d3e4f50a6b2c8d1e9f03a7b")
        item.publisherBlocked = true
        let manifest = try Self.manifestJSON(for: SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil]))
        XCTAssertFalse(manifest.contains("8f2c1a9b"), manifest)
    }

    func testAGUIDThatIsTheAudioLinkIsWithheldForARestrictedEpisodeOnly() throws {
        var blocked = Self.episode(guid: Self.enclosure)
        blocked.publisherBlocked = true
        let identity = SharedItemIdentityBuilder.exportIdentity(for: blocked, draftEditionDigests: [nil])
        XCTAssertNil(identity.episodeGUID)
        XCTAssertFalse(try Self.manifestJSON(for: identity).contains("media.example.com"))

        let open = SharedItemIdentityBuilder.exportIdentity(for: Self.episode(guid: Self.enclosure), draftEditionDigests: [nil])
        XCTAssertEqual(open.episodeGUID, Self.enclosure, "an unrestricted episode keeps its GUID")
        var plainGUID = Self.episode()
        plainGUID.publisherBlocked = true
        XCTAssertEqual(AutomaticSourceAccess.sendableEpisodeGUID("show-ep-12", of: plainGUID), "show-ep-12")
    }

    func testCommunityMapAndPublicMarkSkipARestrictedEpisodeWithoutAnyRequest() {
        var blocked = Self.episode()
        blocked.publisherBlocked = true
        XCTAssertTrue(CommunityMapUploadPolicy.linksArePublic(blocked), "fetching a map for it is unchanged")
        let timeline = TranscriptTimeline(segments: [MediaTimelineSegment(id: "all", startMs: 0, endMs: 3_600_000, text: "All of it.")],
                                          chapters: [], durationMs: 3_600_000)
        for item in [blocked, Self.episode(feed: nil).with { $0.fromPrivateFeed = true }] {
            XCTAssertEqual(CommunityMapUploadPolicy.decide(optedIn: true, item: item, timeline: timeline, hasPublisherChapters: false,
                                                           previous: nil, now: Date()), .skip(.privateLink))
        }
        XCTAssertNil(MapTextDisclosure.checkableAddress(of: blocked))
        XCTAssertNil(MapTextDisclosure.checkableAddress(of: Self.episode(feed: Self.privateFeed)))
        XCTAssertEqual(MapTextDisclosure.checkableAddress(of: Self.episode()), Self.page)
    }

    func testMarkdownExportOfARestrictedEpisodeKeepsItsPageAndDropsItsAudio() throws {
        var blocked = Self.episode()
        blocked.publisherBlocked = true
        let restricted = try Self.export(blocked)
        XCTAssertEqual(restricted.item.externalReference, Self.page)
        XCTAssertNil(restricted.item.sourceURL)

        let noPage = try Self.export(Self.episode(page: Self.enclosure, feed: Self.privateFeed))
        XCTAssertNil(noPage.item.externalReference, "a page that is really the audio link stays too")
        XCTAssertNil(noPage.item.sourceURL)

        let open = try Self.export(Self.episode())
        XCTAssertEqual(open.item.externalReference, Self.page)
        XCTAssertEqual(open.item.sourceURL, Self.enclosure)
    }

    private static func export(_ item: Item) throws -> SessionExport {
        let session = Session(id: "session-1", itemId: item.id, status: "completed", phase: .itemPlayback,
                              currentTargetType: .transcriptBackedMedia, currentTargetId: item.id,
                              position: Position(), completionPercent: 100, playbackRate: 1)
        let repository = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [:])
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "export", displayName: "Export", capabilities: [:]), repository: repository
        )
        return try engine.buildExport(options: ExportOptions(
            sessionId: session.id, includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false
        ))
    }

    private static func prepared(for identity: SharedItemIdentity) throws -> PreparedSpokenMarginsPackage {
        let selection = ReviewedInterjectionSelection(
            packageScopedId: "margin-0001",
            revision: InterjectionShareRevision(
                id: "revision-1", interjectionId: "ij-1", itemId: "episode", sessionId: "session-1",
                createdAt: Date(timeIntervalSince1970: 1_790_000_000), approvedTranscript: "A thought.",
                anchorBefore: "", anchorAfter: "", status: .senderApproved
            ),
            anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 600_000),
            representation: .textOnly
        )
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-5340", createdAt: Date(timeIntervalSince1970: 1_790_000_000), item: identity,
            itemTransportSelection: .reference, selections: [selection]
        )
    }

    private static func manifestJSON(for identity: SharedItemIdentity) throws -> String {
        let prepared = try prepared(for: identity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var text = String(decoding: try encoder.encode(prepared.manifest), as: UTF8.self)
        for data in prepared.artifactData.values { text += String(decoding: data, as: UTF8.self) }
        return text
    }
}

private extension Item {
    func with(_ change: (inout Item) -> Void) -> Item {
        var copy = self
        change(&copy)
        return copy
    }
}
