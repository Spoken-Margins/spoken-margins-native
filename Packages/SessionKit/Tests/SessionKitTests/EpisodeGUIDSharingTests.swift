import Foundation
@testable import SessionKit
@testable import SessionKitSharing
import ShippedPacketReader
import XCTest

/// #177: shared podcast Margins match the recipient's copy by episode GUID, even when each
/// subscriber's audio link carries their own token.
final class EpisodeGUIDSharingTests: XCTestCase {
    private func episode(audioURL: String, guid: String?, durationMs: Int?) -> Item {
        var item = Item(
            id: "item-\(UUID().uuidString)", title: "Episode One", mediaType: "transcript_backed_media",
            text: nil, externalReference: audioURL, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: audioURL, durationMs: durationMs)
        )
        item.episodeGUID = guid
        item.showTitle = "Example Show"
        item.publishedAt = "Tue, 29 Sep 2026 10:00:00 GMT"
        return item
    }

    private let senderLink = "https://media.example.com/one.mp3?token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let recipientLink = "https://media.example.com/one.mp3?token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    // MARK: Done when 3: both sides fill the GUID, and never a private-link GUID

    func testBothIdentitiesCarryTheEpisodeGUIDShowAndDate() {
        let item = episode(audioURL: senderLink, guid: "show-episode-0001", durationMs: 3_600_000)
        for identity in [
            SharedItemIdentityBuilder.localIdentity(for: item),
            SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil])
        ] {
            XCTAssertEqual(identity.itemType, .podcast)
            XCTAssertEqual(identity.episodeGUID, "show-episode-0001")
            XCTAssertEqual(identity.showTitle, "Example Show")
            XCTAssertEqual(identity.publishedAt, "Tue, 29 Sep 2026 10:00:00 GMT")
        }
    }

    func testAGUIDThatIsAPrivateLinkIsDropped() {
        let item = episode(audioURL: senderLink, guid: senderLink, durationMs: 3_600_000)
        XCTAssertNil(SharedItemIdentityBuilder.localIdentity(for: item).episodeGUID)
        XCTAssertNil(SharedItemIdentityBuilder.exportIdentity(for: item, draftEditionDigests: [nil]).episodeGUID)
    }

    func testAnArticleCarriesNoEpisodeFields() {
        var article = Item(id: "a", title: "Article", mediaType: "text", text: "Body.", externalReference: "https://example.com/a", status: "ready")
        article.episodeGUID = "not-an-episode"
        let identity = SharedItemIdentityBuilder.localIdentity(for: article)
        XCTAssertNil(identity.episodeGUID)
        XCTAssertNil(identity.showTitle)
        XCTAssertNotNil(identity.normalizedContentSHA256)
    }

    // MARK: Done when 4: GUID matching with compatible durations

    func testTheSameGUIDWithDifferentTokenizedLinksAndAdFillMatches() {
        let sender = SharedItemIdentityBuilder.exportIdentity(
            for: episode(audioURL: senderLink, guid: "show-episode-0001", durationMs: 3_600_000), draftEditionDigests: [nil])
        let recipient = SharedItemIdentityBuilder.localIdentity(
            for: episode(audioURL: recipientLink, guid: "show-episode-0001", durationMs: 3_780_000))
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(sender, recipient), "5% apart is different ad fill")
    }

    func testTheSameGUIDOnATrailerDoesNotMatchTheFullEpisode() {
        let sender = SharedItemIdentityBuilder.exportIdentity(
            for: episode(audioURL: senderLink, guid: "show-episode-0001", durationMs: 3_600_000), draftEditionDigests: [nil])
        let trailer = SharedItemIdentityBuilder.localIdentity(
            for: episode(audioURL: recipientLink, guid: "show-episode-0001", durationMs: 120_000))
        XCTAssertNil(sender.exactEditionSHA256)
        XCTAssertNil(trailer.exactEditionSHA256)
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(sender, trailer))
        let longer = SharedItemIdentityBuilder.localIdentity(
            for: episode(audioURL: recipientLink, guid: "show-episode-0001", durationMs: 4_800_000))
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(sender, longer), "25% apart")
    }

    func testDifferentGUIDsDoNotMatchAndAnUnknownLengthKeepsTheGUIDMatch() {
        let sender = SharedItemIdentityBuilder.exportIdentity(
            for: episode(audioURL: senderLink, guid: "show-episode-0001", durationMs: 3_600_000), draftEditionDigests: [nil])
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(sender, SharedItemIdentityBuilder.localIdentity(
            for: episode(audioURL: recipientLink, guid: "show-episode-0002", durationMs: 3_600_000))))
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(sender, SharedItemIdentityBuilder.localIdentity(
            for: episode(audioURL: recipientLink, guid: "show-episode-0001", durationMs: nil))))
    }

    func testAShortGUIDFromAnotherShowDoesNotMatch() {
        let sender = SharedItemIdentityBuilder.exportIdentity(
            for: episode(audioURL: senderLink, guid: "42", durationMs: 3_600_000), draftEditionDigests: [nil])
        var otherShow = episode(audioURL: recipientLink, guid: "42", durationMs: 3_600_000)
        otherShow.showTitle = "A Different Show"
        XCTAssertFalse(ImportedItemResolver.canRepresentSameWork(sender, SharedItemIdentityBuilder.localIdentity(for: otherShow)))
        var sameShow = otherShow
        sameShow.showTitle = " example show "
        XCTAssertTrue(ImportedItemResolver.canRepresentSameWork(sender, SharedItemIdentityBuilder.localIdentity(for: sameShow)))
    }

    // MARK: Done when 2 and 6: Build 29 reads the new item record and the packet

    func testTheBuild29ItemDecoderReadsARecordWithTheNewFields() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let item = episode(audioURL: senderLink, guid: "show-episode-0001", durationMs: 3_600_000)
        let payload = try encoder.encode(item)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("\"episodeGUID\""))
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "item", payload: payload), item.id)
    }

    func testTheBuild29FeedEntryDecoderReadsAnEntryWithTheGUID() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = FeedEntry(
            id: "entry", subscriptionId: "subscription", canonicalURL: "https://media.example.com/one.mp3",
            title: "Episode One", publishedAt: Date(timeIntervalSince1970: 1_790_675_200), episodeGUID: "show-episode-0001"
        )
        let payload = try encoder.encode(entry)
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("\"episodeGUID\""))
        XCTAssertEqual(try ShippedPacketReader.decodeStoredRecord(kind: "feed_entry", payload: payload), "entry")
    }

    func testAPacketWithTheEpisodeGUIDImportsInBuild29() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("episode-guid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = SharedItemIdentityBuilder.exportIdentity(
            for: episode(audioURL: "https://media.example.com/one.mp3", guid: "show-episode-0001", durationMs: 3_600_000),
            draftEditionDigests: [nil])
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-episode-guid", createdAt: Date(timeIntervalSince1970: 1_777_000_000), item: identity,
            itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: InterjectionShareRevision(
                    id: "revision", interjectionId: "note", itemId: "item", sessionId: "session",
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000), approvedTranscript: "A thought.",
                    cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
                    anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
                ),
                anchor: .init(anchorType: .media, mediaTimeMs: 5_000),
                representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )
        let manifest = try exportPacket(prepared, to: root.appendingPathComponent("episode.spokenmargins"))
        XCTAssertEqual(manifest.item.episodeGUID, "show-episode-0001")
    }
}
