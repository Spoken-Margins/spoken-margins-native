import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
@testable import SessionKitPersistence
@testable import SessionKitSharing

/// #5286: Hacker Public Radio publishes each episode in MP3, Opus and Ogg feeds, each with its own GUID (the file's
/// address). The sender heard the MP3, the friend's copy came from the Opus feed, and the friend's replies landed on a
/// second row of the episode. The addresses, titles and dates below are HPR4777's as its feeds list them on 2026-11-24.
final class FriendRepliesAnotherEditionTests: XCTestCase {
    private static let page = "https://hackerpublicradio.org/eps/hpr4777/index.html"
    private static let mp3 = "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4777/hpr4777.mp3"
    private static let opus = "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4777/hpr4777.opus"
    private static let title = "HPR4777: Improvements to the HPR Community News"
    private static let day = "Tue, 24 Nov 2026 00:00:00 +0000"

    private func episode(
        _ id: String, file: String, title: String = FriendRepliesAnotherEditionTests.title,
        page: String? = FriendRepliesAnotherEditionTests.page, publishedAt: String? = FriendRepliesAnotherEditionTests.day,
        show: String = "Hacker Public Radio", durationMs: Int? = nil
    ) -> Item {
        var item = Item(
            id: id, title: title, mediaType: "transcript_backed_media", text: nil,
            externalReference: page ?? file, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: file, durationMs: durationMs)
        )
        item.episodeGUID = file
        item.showTitle = show
        item.publishedAt = publishedAt
        return item
    }

    /// What a friend's packet says about their copy.
    private func packet(of item: Item) -> SharedItemIdentity {
        SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil])
    }

    private func local(_ item: Item) -> SharedItemIdentity { SharedItemIdentityBuilder.localIdentity(for: item) }

    // MARK: One episode, another edition

    func testTheOpusEditionOfAnEpisodeIsTheSameWorkAsItsMP3() {
        let senderCopy = episode("cc96", file: Self.mp3)
        let friendCopy = episode("a969", file: Self.opus)
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(packet(of: friendCopy), local(senderCopy)))
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(packet(of: senderCopy), local(friendCopy)))
        XCTAssertNotEqual(ImportedItemResolver.resolve(
            item: packet(of: friendCopy), interjections: [], against: local(senderCopy), itemText: nil
        ).status, .wrongSource)
    }

    /// Neighbouring pairs that are not one episode keep apart: a page every episode shares (a show's homepage) with
    /// another title, another day or no day, another show, a length far apart, and a "page" that is the file itself.
    func testOnlyTheSamePageTitleAndDayMakeOneEpisode() {
        let homepage = "https://example.com/show"
        let senderCopy = episode("s", file: Self.mp3, page: homepage, durationMs: 1_800_000)
        let rows: [(String, Item, Bool)] = [
            ("same page, title and day", episode("f", file: Self.opus, page: homepage, durationMs: 1_790_000), true),
            ("title differs only in case and punctuation", episode("f", file: Self.opus, title: "hpr4777 - improvements to the HPR community news", page: homepage), true),
            ("another episode on the shared homepage", episode("f", file: Self.opus, title: "HPR4778: Something else", page: homepage), false),
            ("same title, another day", episode("f", file: Self.opus, page: homepage, publishedAt: "Wed, 25 Nov 2026 00:00:00 +0000"), false),
            ("no publish day", episode("f", file: Self.opus, page: homepage, publishedAt: nil), false),
            ("another show", episode("f", file: Self.opus, page: homepage, show: "Another Show"), false),
            ("length far apart", episode("f", file: Self.opus, page: homepage, durationMs: 600_000), false),
            ("another page", episode("f", file: Self.opus, page: "https://example.com/show/other"), false)
        ]
        for (name, friendCopy, expected) in rows {
            XCTAssertEqual(ImportedItemResolver.canRepresentSameWork(packet(of: friendCopy), local(senderCopy)), expected, name)
        }
        // Items with no page: the address is the file, which names one edition only.
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(
            packet(of: episode("f", file: Self.opus, page: nil)), local(episode("s", file: Self.mp3, page: nil))))
    }

    func testTheSendersRowIsTheMatchForTheFriendsReplies() {
        let senderCopy = episode("cc96", file: Self.mp3)
        let unrelated = episode("other", file: "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4778/hpr4778.mp3",
                                title: "HPR4778: Something else", page: "https://hackerpublicradio.org/eps/hpr4778/index.html")
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(
            for: packet(of: episode("a969", file: Self.opus)), among: [senderCopy, unrelated]), "cc96")
    }

    /// A listener holding both editions keeps getting packets on the row each one names exactly (review of 046731f):
    /// the edition rule must not make an exact GUID or file match ambiguous.
    func testTheRowAPacketNamesExactlyStillWinsOverAnotherEdition() {
        let mp3Row = episode("cc96", file: Self.mp3), opusRow = episode("a969", file: Self.opus)
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: packet(of: mp3Row), among: [mp3Row, opusRow]), "cc96")
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: packet(of: opusRow), among: [mp3Row, opusRow]), "a969")
        // An Ogg copy matches both by edition and neither exactly: no guess.
        let ogg = episode("ogg", file: "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4777/hpr4777.ogg")
        XCTAssertNil(SharedPacketItemMatcher.matchingItemId(for: packet(of: ogg), among: [mp3Row, opusRow]))
    }

    // MARK: Replies go to the row holding their parents (Done when 1)

    /// Real SQLite: the listener holds the episode on two rows (their MP3 and an Opus copy an earlier import added).
    /// Both are the same work, so the ordinary match has no answer; the row holding the Margins the replies answer does.
    func testRepliesLandOnTheRowHoldingTheMarginsTheyAnswer() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "reply-parents-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        let senderCopy = episode("cc96", file: Self.mp3), secondRow = episode("a969", file: Self.opus)
        for item in [senderCopy, secondRow] {
            try store.saveItem(item)
            try store.saveSession(Session(
                id: "session-\(item.id)", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
                status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: item.id,
                position: Position(), completionPercent: 0, playbackRate: 1))
        }
        func own(_ id: String, item: String, sharedAs: [MarginPacketIdentity]?, status: String = "active") -> Interjection {
            Interjection(
                id: id, itemId: item, sessionId: "session-\(item)", targetType: .item, targetId: item, createdAt: Date(timeIntervalSince1970: 1), roughPercent: 0,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 754_000),
                audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
                displayText: "Words", status: status, sharedAs: sharedAs)
        }
        let first = MarginPacketIdentity(packageDigest: "b628f972", packageScopedId: "margin-0001")
        let second = MarginPacketIdentity(packageDigest: "b628f972", packageScopedId: "margin-0002")
        try store.saveInterjection(own("m1", item: "cc96", sharedAs: [first]))
        try store.saveInterjection(own("m2", item: "cc96", sharedAs: [second]))
        try store.saveInterjection(own("unshared", item: "a969", sharedAs: nil))
        // A Margin deleted after it was shared is no parent, as in the reply graph.
        let deleted = MarginPacketIdentity(packageDigest: "b628f972", packageScopedId: "margin-0003")
        try store.saveInterjection(own("gone", item: "a969", sharedAs: [deleted], status: "deleted"))

        let conversation = MarginConversationArtifact(replies: [
            .init(packageScopedId: "reply-1", link: .replying(to: first, parentConversationId: nil)),
            .init(packageScopedId: "reply-2", link: .replying(to: second, parentConversationId: nil)),
            .init(packageScopedId: "reply-3", link: .replying(to: first, parentConversationId: nil))
        ])
        let parents = ReplyParentItemMatch.parents(in: [conversation])
        XCTAssertEqual(parents, [first, second], "each parent once, in packet order")

        let repliesPacket = packet(of: secondRow) // the friend's copy is the Opus edition
        let items = [senderCopy, secondRow]
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: repliesPacket, among: items), "a969",
                       "the ordinary match takes the row the packet names exactly, the Opus copy")
        let holding = try store.itemIdsHoldingOwnMargins(sharedAs: parents)
        XCTAssertEqual(holding, ["cc96"])
        XCTAssertEqual(ReplyParentItemMatch.itemId(for: repliesPacket, holdingParents: holding, among: items), "cc96")

        XCTAssertEqual(try store.itemIdsHoldingOwnMargins(sharedAs: [deleted]), [], "a deleted Margin holds no replies")
        XCTAssertEqual(try store.itemIdsHoldingOwnMargins(sharedAs: []), [])
        // A row the listener deleted, or one that is another work, never takes the replies.
        var deletedRow = senderCopy
        deletedRow.deletedAt = Date()
        XCTAssertNil(ReplyParentItemMatch.itemId(for: repliesPacket, holdingParents: holding, among: [deletedRow, secondRow]))
        let anotherShow = packet(of: episode("x", file: Self.opus, show: "Another Show"))
        XCTAssertNil(ReplyParentItemMatch.itemId(for: anotherShow, holdingParents: holding, among: items))
    }

    // MARK: The friend's copy is the edition the packet names (Done when 2)

    private static let pageHTML = """
        <html><head>
        <link rel="alternate" type="application/rss+xml" title="Hacker Public Radio Opus RSS" href="/hpr_opus_rss.php" />
        <link rel="alternate" type="application/rss+xml" title="Hacker Public Radio Ogg Vorbis RSS" href="/hpr_ogg_rss.php" />
        <link rel="alternate" type="application/rss+xml" title="Hacker Public Radio MP3 RSS" href="/hpr_mp3_rss.php" />
        </head><body><p>HPR4777</p></body></html>
        """

    private static func feed(_ file: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Hacker Public Radio</title>
        <item><title>\(title)</title><link>\(page)</link><guid>\(file)</guid><pubDate>\(day)</pubDate>
        <enclosure url="\(file)" length="1" type="audio/mpeg" /></item>
        </channel></rss>
        """
    }

    private func hprResolver() -> PublicPodcastLinkResolver {
        let fetch: @Sendable (URL) throws -> Data = { url in
            switch url.absoluteString {
            case Self.page: return Data(Self.pageHTML.utf8)
            case "https://hackerpublicradio.org/hpr_opus_rss.php": return Data(Self.feed(Self.opus).utf8)
            case "https://hackerpublicradio.org/hpr_ogg_rss.php":
                return Data(Self.feed("https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4777/hpr4777.ogg").utf8)
            case "https://hackerpublicradio.org/hpr_mp3_rss.php": return Data(Self.feed(Self.mp3).utf8)
            default: throw URLError(.badServerResponse)
            }
        }
        return PublicPodcastLinkResolver(fetch: fetch, asynchronousFetch: { try fetch($0) })
    }

    func testAFriendsPacketResolvesToTheEditionItNames() async throws {
        let resolver = hprResolver()
        let request = LinkResolutionRequest(
            id: "hpr", inputURL: Self.page, sourceSurface: "spoken_margins_package", createdAt: Date(), preferredEnclosureURL: Self.mp3)
        for result in [try resolver.resolve(request), try await resolver.resolveAsync(request)] {
            XCTAssertEqual(result.status, .playable)
            XCTAssertEqual(result.selectedCandidate?.audioURL, Self.mp3)
            XCTAssertEqual(result.selectedCandidate?.sourceLink.url, "https://hackerpublicradio.org/hpr_mp3_rss.php")
        }
    }

    /// A listener's own paste names no file, so the page's first feed is taken as before; so is a packet whose file
    /// none of the feeds lists any more.
    func testWithoutAFileToPreferThePagesFirstFeedIsKept() async throws {
        let resolver = hprResolver()
        for preferred in [nil, "https://hub.hackerpublicradio.org/ccdn.php?filename=/eps/hpr4777/hpr4777.flac"] {
            let request = LinkResolutionRequest(
                id: "hpr", inputURL: Self.page, sourceSurface: "paste", createdAt: Date(), preferredEnclosureURL: preferred)
            for result in [try resolver.resolve(request), try await resolver.resolveAsync(request)] {
                XCTAssertEqual(result.selectedCandidate?.audioURL, Self.opus, String(describing: preferred))
            }
        }
    }

    func testSettlingTakesTheCandidateThatIsThePacketsFile() throws {
        func candidate(_ file: String) -> LinkResolutionCandidate {
            LinkResolutionCandidate(
                sourceLink: SourceLink(url: Self.page, provider: "rss", role: "canonical_feed"),
                title: Self.title, audioURL: file, confidence: 0.9)
        }
        let request = LinkResolutionRequest(id: "r", inputURL: Self.page, sourceSurface: "spoken_margins_package", createdAt: Date())
        let lookup = LinkResolutionResult(
            requestId: "r", status: .playable, originalLink: SourceLink(url: Self.page, provider: "rss", role: "canonical_feed"),
            selectedCandidate: candidate(Self.opus), candidates: [candidate(Self.opus), candidate(Self.mp3)])
        let senderPacket = packet(of: episode("cc96", file: Self.mp3))
        XCTAssertEqual(try SharedPodcastResolutionPolicy.settle(lookup, item: senderPacket, request: request).result.selectedCandidate?.audioURL, Self.mp3)
        // An episode the lookup could not tell apart before (#5286): two editions of one file name both read as "the same file".
        var review = lookup
        review.status = .needsReview
        review.selectedCandidate = nil
        XCTAssertEqual(try SharedPodcastResolutionPolicy.settle(review, item: senderPacket, request: request).result.selectedCandidate?.audioURL, Self.mp3)
    }
}
