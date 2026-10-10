import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest

/// #755: a packet shared by link finds the listener's own copy of the episode when the listener has said
/// which episode their imported file is, and finds no other work. The link-shared packet carries no checksum,
/// so before this a second, streamed copy of the episode was added next to the file.
final class LinkedFileEpisodeMatchTests: XCTestCase {
    private static let page = "https://podcasts.example.com/episodes/harbour-lights"
    private static let enclosure = "https://cdn.example.com/audio/harbour-lights.mp3"
    private static let digest = String(repeating: "a", count: 64)

    /// What `LocalSourceImporters.importAudiobook` writes for a file the listener imported.
    private func importedFile(id: String = "audiobook-1", durationMs: Int = 1_800_000) -> Item {
        Item(
            id: id, title: "harbour-lights", mediaType: "audiobook", text: nil,
            externalReference: "file:///var/mobile/Audiobooks/\(id).m4a", status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(
                sourceType: .nativeMediaFile, url: "file:///var/mobile/Audiobooks/\(id).m4a",
                durationMs: durationMs, nativeMediaId: "audiobook-audio-\(id)"
            )
        )
    }

    private func candidate(
        guid: String? = "harbour-lights", showTitle: String? = "Example Show", durationMs: Int? = 1_800_000,
        audioURL: String? = enclosure
    ) -> LinkResolutionCandidate {
        LinkResolutionCandidate(
            sourceLink: SourceLink(url: Self.page), title: "Harbour Lights", showTitle: showTitle,
            durationMs: durationMs, publishedAt: "2026-09-29T10:00:00Z", episodeGUID: guid, audioURL: audioURL, confidence: 1
        )
    }

    private func linkedFile(
        id: String = "audiobook-1", guid: String? = "harbour-lights", showTitle: String? = "Example Show",
        pageURL: String? = page, audioURL: String? = enclosure
    ) throws -> Item {
        try ImportedFileEpisodeLink.link(
            importedFile(id: id), to: candidate(guid: guid, showTitle: showTitle, audioURL: audioURL), pageURL: pageURL
        )
    }

    /// What a friend's packet names when they share a public podcast episode by link.
    private func linkShared(
        guid: String? = "harbour-lights", showTitle: String? = "Example Show", title: String = "Harbour Lights",
        canonicalURL: String? = page, enclosureURL: String? = enclosure, durationMs: Int? = 1_800_000
    ) -> SharedItemIdentity {
        SharedItemIdentity(
            itemType: .podcast, canonicalURL: canonicalURL, originalURL: canonicalURL, title: title,
            showTitle: showTitle, episodeGUID: guid, enclosureURL: enclosureURL, durationMs: durationMs
        )
    }

    private func match(_ packet: SharedItemIdentity, _ items: [Item], digest: String? = digest) -> String? {
        SharedPacketItemMatcher.matchingItemId(for: packet, among: items, ownedAudiobookDigest: { _ in digest })
    }

    func testALinkSharedPacketLandsOnTheLinkedFile() throws {
        let file = try linkedFile()
        XCTAssertEqual(match(linkShared(), [file]), file.id)
        // By GUID alone, and by page alone, as feeds that give one or the other do.
        XCTAssertEqual(match(linkShared(canonicalURL: nil, enclosureURL: nil), [file]), file.id)
        XCTAssertEqual(match(linkShared(guid: nil, enclosureURL: nil), [file]), file.id)
        XCTAssertEqual(match(linkShared(), [file, importedFile(id: "audiobook-2")]), file.id, "next to an unrelated file")
    }

    func testTheLinkedFileKeepsItsFileIdentity() throws {
        let file = try linkedFile()
        let identity = SharedPacketItemMatcher.localIdentity(for: file, ownedAudiobookDigest: Self.digest)
        XCTAssertEqual(identity.itemType, .other, "admission and exact-edition placement still see an audio file")
        XCTAssertEqual(identity.exactEditionSHA256, Self.digest)
        XCTAssertEqual(identity.episodeGUID, "harbour-lights")
        // The exact-file packet from Ana still matches by checksum, linked or not.
        let ana = SharedItemIdentity(itemType: .other, title: "Harbour Lights", durationMs: 1_800_000, exactEditionSHA256: Self.digest)
        XCTAssertEqual(match(ana, [file]), file.id)
        XCTAssertEqual(match(ana, [importedFile()]), "audiobook-1")
        // A link-shared packet is placed like a downloaded episode, as the app does for any podcast packet.
        XCTAssertEqual(LocalAudioPacketAdmission.admission(source: linkShared(), recipient: identity, actualDigest: Self.digest), .podcastCommentary)
        XCTAssertNil(LocalAudioPacketAdmission.admission(source: linkShared(), recipient: identity, actualDigest: String(repeating: "b", count: 64)))
    }

    func testAFileNobodyLinkedStaysMatchedOnlyByItsChecksum() {
        // Option (a) of #755 is what a file with no chosen episode keeps: no guessing from title or length.
        let file = importedFile()
        XCTAssertNil(match(linkShared(), [file]))
        XCTAssertNil(match(linkShared(canonicalURL: nil, enclosureURL: nil), [file]))
        let lookalike = linkShared(guid: nil, canonicalURL: nil, enclosureURL: nil)
        XCTAssertNil(match(lookalike, [file]), "same title, show and length is not enough")
        let ana = SharedItemIdentity(itemType: .other, title: "Harbour Lights", durationMs: 1_800_000, exactEditionSHA256: Self.digest)
        XCTAssertEqual(match(ana, [file]), file.id)
        XCTAssertNil(match(ana, [file], digest: nil))
    }

    func testALinkedFileLandsNoOtherWork() throws {
        let file = try linkedFile()
        let table: [(String, SharedItemIdentity)] = [
            ("another episode's GUID", linkShared(guid: "another-episode", canonicalURL: "https://podcasts.example.com/episodes/other", enclosureURL: nil)),
            ("same GUID, another show", linkShared(showTitle: "Another Show")),
            ("same GUID, show title in other case and markup", linkShared(showTitle: "<b>EXAMPLE show</b>")),
            ("same GUID, a cut three times as long", linkShared(durationMs: 5_400_000)),
            ("same title and show, no identity", linkShared(guid: nil, canonicalURL: nil, enclosureURL: nil)),
            ("same title, another page", linkShared(guid: nil, canonicalURL: "https://podcasts.example.com/episodes/other", enclosureURL: nil)),
            ("an article on the same page", SharedItemIdentity(itemType: .text, canonicalURL: Self.page, title: "Harbour Lights")),
            ("a PDF with the same GUID", SharedItemIdentity(itemType: .pdf, canonicalURL: Self.page, title: "Harbour Lights", episodeGUID: "harbour-lights")),
        ]
        for (name, packet) in table {
            let expected: String? = name == "same GUID, show title in other case and markup" ? file.id : nil
            XCTAssertEqual(match(packet, [file]), expected, name)
        }
    }

    func testTwoFilesLinkedToOneEpisodeAreNotGuessedBetween() throws {
        let first = try linkedFile(id: "audiobook-1")
        let second = try linkedFile(id: "audiobook-2")
        XCTAssertNil(match(linkShared(), [first, second]))
        XCTAssertEqual(match(linkShared(), [first, importedFile(id: "audiobook-2")]), "audiobook-1")
    }

    func testAGUIDThatIsAPrivateLinkNeverTakesPart() throws {
        // The same filter a streamed episode's identity applies. Page and audio links are only compared here,
        // never sent, and a private feed's packet carries none, so they cannot match anything.
        let privateFile = try linkedFile(guid: "https://www.patreon.com/rss/example?auth=secret", pageURL: nil, audioURL: nil)
        let identity = SharedPacketItemMatcher.localIdentity(for: privateFile, ownedAudiobookDigest: Self.digest)
        XCTAssertNil(identity.episodeGUID)
        let privatePacket = linkShared(guid: "https://www.patreon.com/rss/example?auth=secret", canonicalURL: nil, enclosureURL: nil)
        XCTAssertNil(match(privatePacket, [privateFile]))
    }

    func testALinkedFileWithoutItsOwnedFileClaimsNothing() throws {
        let file = try linkedFile()
        XCTAssertNil(match(linkShared(), [file], digest: nil))
        XCTAssertFalse(SharedPacketItemMatcher.layerHasValidItemAssociation(layer(for: linkShared()), item: file, ownedAudiobookDigest: nil))
        XCTAssertTrue(SharedPacketItemMatcher.layerHasValidItemAssociation(layer(for: linkShared()), item: file, ownedAudiobookDigest: Self.digest))
        // Unlinking takes the episode identity away again; the file and its checksum are untouched.
        XCTAssertNil(match(linkShared(), [ImportedFileEpisodeLink.unlink(file)]))
    }

    /// Build 29 imports what a new build exports: linking a file does not change what sharing from it sends.
    func testExportingFromALinkedFileSendsNothingNew() throws {
        let linked = try linkedFile()
        let plain = importedFile()
        for digests in [[Self.digest], [nil]] as [[String?]] {
            XCTAssertEqual(
                SharedItemIdentityBuilder.exportIdentity(for: linked, draftEditionDigests: digests, localAudioDigest: Self.digest),
                SharedItemIdentityBuilder.exportIdentity(for: plain, draftEditionDigests: digests, localAudioDigest: Self.digest)
            )
        }
    }

    /// The link goes through the real store: a later load, as the app does on the next launch or import, still finds the file.
    func testTheLinkSurvivesTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "linked-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SQLiteSessionStore(path: folder.appending(path: "library.sqlite").path)
        let plain = importedFile()
        try store.saveItem(plain)
        XCTAssertNil(match(linkShared(), try store.listItems()))
        let linked = try ImportedFileEpisodeLink.link(try store.loadItem(id: plain.id), to: candidate(), pageURL: Self.page)
        try store.saveItem(linked)
        XCTAssertEqual(try store.loadItem(id: plain.id), linked)
        XCTAssertEqual(match(linkShared(), try store.listItems()), plain.id)
        try store.saveItem(ImportedFileEpisodeLink.unlink(try store.loadItem(id: plain.id)))
        XCTAssertEqual(try store.loadItem(id: plain.id), plain)
        XCTAssertNil(match(linkShared(), try store.listItems()))
    }

    private func layer(for identity: SharedItemIdentity) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer", itemId: "audiobook-1", packageDigest: String(repeating: "c", count: 64), packageId: "package",
            itemIdentity: identity, displayLabel: "Friend", importedAt: Date(timeIntervalSince1970: 1_777_000_000),
            sourceResolutionStatus: .resolved
        )
    }
}
