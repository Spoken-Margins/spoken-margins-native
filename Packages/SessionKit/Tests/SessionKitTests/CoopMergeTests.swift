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
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Ana downloaded the episode, so her packet names the exact edition; Ben and Cleo shared by link.
        let senders: [(label: String, digest: String?)] = [
            ("Ana", String(repeating: "a1", count: 32)), ("Ben", nil), ("Cleo", nil),
        ]
        let packets = try senders.enumerated().map { index, sender in
            let url = root.appending(path: "\(sender.label).spokenmargins")
            // exportPacket also imports each packet with Build 29's frozen reader (Done when 4).
            _ = try exportPacket(packet(from: sender.label, digest: sender.digest, margins: index + 1), to: url)
            return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "assets-\(sender.label)"))
        }

        var expectedMargins: Set<String>?
        for order in permutations([0, 1, 2]) {
            let name = order.map { senders[$0].label }.joined(separator: "-")
            let store = try SQLiteSessionStore(path: root.appending(path: "\(name).sqlite").path)
            episodesAdded = 0
            for index in order {
                XCTAssertEqual(try importAsTheAppDoes(packets[index], into: store).isImported, true, name)
            }

            // The second and third packets find the episode the first one added.
            XCTAssertEqual(episodesAdded, 1, name)
            let items = try store.listItems().filter { $0.media?.url == Self.enclosure }
            XCTAssertEqual(items.count, 1, name)
            let itemId = try XCTUnwrap(items.first?.id)
            let layers = try store.loadImportedCommentaryLayers(itemId: itemId)
            XCTAssertEqual(Set(layers.compactMap(\.displayLabel)), ["Ana", "Ben", "Cleo"], name)
            XCTAssertEqual(layers.count, 3, name)
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
            XCTAssertEqual(episodesAdded, 1, name)
            XCTAssertEqual(try store.listItems().filter { $0.media?.url == Self.enclosure }.count, 1, name)
            XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: itemId).count, 3, name)
            XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: itemId).flatMap {
                try store.loadImportedCommentaryInterjections(layerId: $0.id)
            }.count, 6, name)
        }
        XCTAssertEqual(expectedMargins, ["Ana/margin-001", "Ben/margin-001", "Ben/margin-002", "Cleo/margin-001", "Cleo/margin-002", "Cleo/margin-003"])
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
        let itemId = try SharedPacketItemMatcher.matchingItemId(for: contents.manifest.item, among: store.listItems())
            ?? addEpisode(named: contents.manifest.item, to: store)
        let item = try store.loadItem(id: itemId)
        return try SpokenMarginsPackageImporter.importPackage(
            contents,
            itemId: itemId,
            localItem: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: nil),
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

    private func packet(from sender: String, digest: String?, margins: Int) throws -> PreparedSpokenMarginsPackage {
        try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-\(sender.lowercased())",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: SharedItemIdentity(
                itemType: .podcast, canonicalURL: Self.episodePage, originalURL: Self.episodePage,
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
