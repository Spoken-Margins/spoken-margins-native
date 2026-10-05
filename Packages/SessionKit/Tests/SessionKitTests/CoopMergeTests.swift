import CryptoKit
import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import XCTest

/// Co-op, first slice (#468): three friends' packets on one episode land on one item, whatever order they
/// arrive in, and opening any of them again adds nothing.
final class CoopMergeTests: XCTestCase {
    private static let episodePage = "https://podcasts.example.com/episodes/harbour-lights"
    private static let enclosure = "https://cdn.example.com/audio/harbour-lights.mp3"

    func testThreeSendersPacketsMergeOntoOneItemInEveryOrder() throws {
        try checkThreeSendersInEveryOrder(hasLocalCopy: false)
    }

    func testThreeSendersPacketsMergeOntoDigestMatchedLocalCopyInEveryOrder() throws {
        try checkThreeSendersInEveryOrder(hasLocalCopy: true)
    }

    private func checkThreeSendersInEveryOrder(hasLocalCopy: Bool) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Identity tests need file bytes and their real checksum, not audio decoding or playback.
        let localFile = root.appending(path: "harbour-lights.fixture")
        try Data("Harbour Lights local-copy fixture".utf8).write(to: localFile)
        let localDigest = SHA256.hash(data: try Data(contentsOf: localFile)).map { String(format: "%02x", $0) }.joined()
        // Ana names the exact edition; Ben and Cleo shared by link.
        let senders: [(label: String, digest: String?)] = [
            ("Ana", localDigest), ("Ben", nil), ("Cleo", nil),
        ]
        let packets = try senders.enumerated().map { index, sender in
            let url = root.appending(path: "\(sender.label).spokenmargins")
            // exportPacket also imports each packet with Build 29's frozen reader (Done when 4).
            _ = try exportPacket(packet(
                from: sender.label, digest: sender.digest, margins: index + 1,
                // Ana's alternate discovery link cannot match the recipient by URL or GUID.
                canonicalURL: hasLocalCopy && index == 0 ? "https://ana.example.com/harbour-lights" : Self.episodePage
            ), to: url)
            return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "assets-\(sender.label)"))
        }

        var expectedMargins: Set<String>?
        for order in permutations([0, 1, 2]) {
            let name = order.map { senders[$0].label }.joined(separator: "-")
            let store = try SQLiteSessionStore(path: root.appending(path: "\(name).sqlite").path)
            episodesAdded = 0
            if hasLocalCopy {
                // The app represents imported local audio as an audiobook, even for an episode.
                // It can still match Ben/Cleo by the retained discovery link.
                let item = Item(
                    id: "local-harbour-lights", title: "Harbour Lights", mediaType: "audiobook",
                    text: nil, externalReference: Self.episodePage, status: "ready", externalReferenceType: "url",
                    media: ItemMedia(sourceType: .nativeMediaFile, url: localFile.absoluteString, durationMs: 1_800_000)
                )
                try store.saveItem(item)
                try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
                    id: "local-episode-asset", itemId: item.id, category: .audiobook,
                    relativePath: localFile.lastPathComponent,
                    byteCount: Int64(try Data(contentsOf: localFile).count), checksumSHA256: localDigest,
                    isReproducible: false, integrity: .valid, protections: [.importedAudiobook]
                ))
                let digest = try ownedAudiobookDigest(for: item, in: store)
                let localIdentity = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: digest)
                XCTAssertEqual(localIdentity.exactEditionSHA256, packets[0].manifest.item.exactEditionSHA256, name)
                XCTAssertNotEqual(localIdentity.canonicalURL, packets[0].manifest.item.canonicalURL, name)
                XCTAssertNil(localIdentity.episodeGUID, name)
                XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(
                    for: packets[0].manifest.item, among: [item], ownedAudiobookDigest: { _ in digest }
                ), item.id, name)
                // Removing the recipient digest must remove Ana's only match.
                XCTAssertNil(SharedPacketItemMatcher.matchingItemId(
                    for: packets[0].manifest.item, among: [item]
                ), name)
            }
            for index in order {
                XCTAssertEqual(try importAsTheAppDoes(packets[index], into: store).isImported, true, name)
            }

            // An empty Library adds once; an existing local copy needs no new episode.
            XCTAssertEqual(episodesAdded, hasLocalCopy ? 0 : 1, name)
            let items = try store.listItems()
            XCTAssertEqual(items.count, 1, name)
            let itemId = try XCTUnwrap(items.first?.id)
            if hasLocalCopy { XCTAssertEqual(itemId, "local-harbour-lights", name) }
            let layers = try store.loadImportedCommentaryLayers(itemId: itemId)
            XCTAssertEqual(Set(layers.compactMap(\.displayLabel)), ["Ana", "Ben", "Cleo"], name)
            XCTAssertEqual(layers.count, 3, name)
            XCTAssertFalse(layers.contains { $0.sourceResolutionStatus == .wrongSource }, name)
            let margins = try Set(layers.flatMap { layer in
                try store.loadImportedCommentaryInterjections(layerId: layer.id).map {
                    "\(layer.displayLabel ?? "?")/\($0.packageScopedId)"
                }
            })
            XCTAssertEqual(margins.count, 6, name)
            if let expectedMargins { XCTAssertEqual(margins, expectedMargins, name) } else { expectedMargins = margins }

            // Opening all three again adds no layer and no Margin.
            for index in order {
                XCTAssertEqual(try importAsTheAppDoes(packets[index], into: store).isImported, false, name)
            }
            XCTAssertEqual(episodesAdded, hasLocalCopy ? 0 : 1, name)
            XCTAssertEqual(try store.listItems().count, 1, name)
            XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: itemId).count, 3, name)
            XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: itemId).flatMap {
                try store.loadImportedCommentaryInterjections(layerId: $0.id)
            }.count, 6, name)
        }
        XCTAssertEqual(expectedMargins, ["Ana/margin-001", "Ben/margin-001", "Ben/margin-002", "Cleo/margin-001", "Cleo/margin-002", "Cleo/margin-003"])
    }

    /// The admission rule on its own (#468). A packet naming this exact file places at the sender's times; a
    /// podcast packet on the listener's copy of the episode is admitted for acoustic placement; anything
    /// else, or a file whose bytes changed, is refused.
    func testLocalAudioAdmission() {
        let digest = String(repeating: "a", count: 64)
        let local = SharedItemIdentity(itemType: .other, title: "Harbour Lights", durationMs: 1_800_000, exactEditionSHA256: digest)
        let exact = SharedItemIdentity(itemType: .other, title: "Harbour Lights", durationMs: 1_800_100, exactEditionSHA256: digest)
        let episode = SharedItemIdentity(
            itemType: .podcast, canonicalURL: Self.episodePage, title: "Harbour Lights", enclosureURL: Self.enclosure
        )
        let article = SharedItemIdentity(itemType: .text, canonicalURL: Self.episodePage, title: "Harbour Lights")
        XCTAssertEqual(LocalAudioPacketAdmission.admission(source: exact, recipient: local, actualDigest: digest), .exactEdition)
        XCTAssertEqual(LocalAudioPacketAdmission.admission(source: episode, recipient: local, actualDigest: digest), .podcastCommentary)
        XCTAssertNil(LocalAudioPacketAdmission.admission(source: article, recipient: local, actualDigest: digest))
        let changedBytes = String(repeating: "b", count: 64)
        XCTAssertNil(LocalAudioPacketAdmission.admission(source: exact, recipient: local, actualDigest: changedBytes))
        XCTAssertNil(LocalAudioPacketAdmission.admission(source: episode, recipient: local, actualDigest: changedBytes))
    }

    // MARK: Helpers

    private var episodesAdded = 0

    /// The app's order of steps (Gate1AppModel.confirmSpokenMarginsPackageImport): skip a packet it already
    /// has, find the item with the same matcher, otherwise add the episode the packet names, then import.
    private func importAsTheAppDoes(
        _ contents: VerifiedSpokenMarginsPackage,
        into store: SQLiteSessionStore
    ) throws -> ImportedCommentaryImportDisposition {
        if let existing = try store.loadImportedCommentaryLayer(packageDigest: XCTUnwrap(contents.manifest.contentDigest)) {
            return .duplicate(existingLayerId: existing.id)
        }
        let assets = try store.loadOwnedOfflineAssets()
        let itemId = try SharedPacketItemMatcher.matchingItemId(
            for: contents.manifest.item, among: store.listItems(),
            ownedAudiobookDigest: { item in
                guard item.mediaType == "audiobook" else { return nil }
                return assets.first { $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid }?.checksumSHA256
            }
        )
            ?? addEpisode(named: contents.manifest.item, to: store)
        let item = try store.loadItem(id: itemId)
        if item.mediaType == "audiobook" {
            // The app's admission check for the listener's own file (verifyLocalAudioForImport): the bytes on
            // disk now, against the packet and the item. A podcast packet is placed like a download.
            let fileURL = try XCTUnwrap(item.media?.url.flatMap(URL.init(string:)))
            let actualDigest = SHA256.hash(data: try Data(contentsOf: fileURL)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(try LocalAudioPacketAdmission.admitted(
                contents, recipient: SharedPacketItemMatcher.localIdentity(
                    for: item, ownedAudiobookDigest: ownedAudiobookDigest(for: item, in: store)
                ), itemId: item.id, actualDigest: actualDigest
            ), .podcastCommentary)
        }
        return try SpokenMarginsPackageImporter.importPackage(
            contents,
            itemId: itemId,
            localItem: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: ownedAudiobookDigest(for: item, in: store)),
            repository: store
        )
    }

    /// What adding a podcast by link saves (SessionEngine.sourceImportItem): the link the packet gave and
    /// the resolved enclosure, keyed by the enclosure.
    private func addEpisode(named identity: SharedItemIdentity, to store: SQLiteSessionStore) throws -> String {
        episodesAdded += 1
        let item = Item(
            id: "audio-url:\(try XCTUnwrap(identity.enclosureURL))",
            title: identity.title,
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: identity.canonicalURL,
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: identity.enclosureURL, durationMs: identity.durationMs)
        )
        try store.saveItem(item)
        return item.id
    }

    private func ownedAudiobookDigest(for item: Item, in store: SQLiteSessionStore) throws -> String? {
        guard item.mediaType == "audiobook" else { return nil }
        return try store.loadOwnedOfflineAssets().first {
            $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid
        }?.checksumSHA256
    }

    private func packet(
        from sender: String, digest: String?, margins: Int, canonicalURL: String
    ) throws -> PreparedSpokenMarginsPackage {
        try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(sender.lowercased())",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: SharedItemIdentity(
                itemType: .podcast, canonicalURL: canonicalURL, originalURL: canonicalURL,
                title: "Harbour Lights", showTitle: "Example Show", episodeGUID: "harbour-lights",
                enclosureURL: Self.enclosure, durationMs: 1_800_000, exactEditionSHA256: digest
            ),
            itemTransportSelection: .reference,
            selections: (1...margins).map { index in
                ReviewedInterjectionSelection(
                    packageScopedId: String(format: "margin-%03d", index),
                    revision: InterjectionShareRevision(
                        id: "revision-\(sender)-\(index)", interjectionId: "note-\(index)", itemId: "sender-item",
                        sessionId: "sender-session", createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                        approvedTranscript: "\(sender)'s thought number \(index).",
                        anchorBefore: "", anchorAfter: "", status: .senderApproved
                    ),
                    anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: index * 60_000),
                    representation: .textOnly
                )
            },
            senderDisplayLabel: sender
        )
    }

    private func permutations(_ values: [Int]) -> [[Int]] {
        guard values.count > 1 else { return [values] }
        return values.flatMap { value in
            permutations(values.filter { $0 != value }).map { [value] + $0 }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CoopMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension ImportedCommentaryImportDisposition {
    var isImported: Bool {
        if case .imported = self { return true }
        return false
    }
}
