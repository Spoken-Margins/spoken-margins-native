import Foundation
@testable import SessionKit
@testable import SessionKitSharing
import XCTest

final class ImportedLayerAssociationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let digest = String(repeating: "a", count: 64)

    func testWrongSourceLayerIsInvalidEvenWhenItemMatches() {
        var layer = makeLayer()
        XCTAssertTrue(isValid(layer, item: makeItem()))
        layer.sourceResolutionStatus = .wrongSource
        XCTAssertFalse(isValid(layer, item: makeItem()))
    }

    func testDeletedMissingAndDifferentItemsAreInvalid() {
        let layer = makeLayer()
        var deleted = makeItem()
        deleted.deletedAt = date
        XCTAssertFalse(isValid(layer, item: deleted))
        XCTAssertFalse(isValid(layer, item: nil))
        var unassociated = layer
        unassociated.itemId = nil
        XCTAssertFalse(isValid(unassociated, item: makeItem()))
        let different = Item(id: "different", title: "Other", mediaType: "article", text: "Other text",
                             externalReference: "https://example.com/other", status: "ready")
        XCTAssertFalse(isValid(layer, item: different))
    }

    func testRepairWrongSourceThrowsExactCodeWithoutWrites() throws {
        let repository = RecordingRepository()
        let existing = makeLayer()
        repository.importedCommentaryLayers[existing.id] = existing
        let wrong = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/other", title: "Other")
        XCTAssertThrowsError(try SpokenMarginsPackageImporter.repairAssociation(
            existing: existing, contents: makeContents(), itemId: "new", localItem: wrong,
            itemText: nil, repository: repository
        )) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_package_repair_source_did_not_match"))
        }
        XCTAssertTrue(repository.events.isEmpty)
        XCTAssertEqual(repository.importedCommentaryLayers, [existing.id: existing])
        XCTAssertTrue(repository.importedCommentaryInterjections.isEmpty)
    }

    func testRepairMissingInputsThrowExactCodeWithoutWrites() {
        for missing in ["itemId", "localItem", "commentary"] {
            let repository = RecordingRepository()
            XCTAssertThrowsError(try SpokenMarginsPackageImporter.repairAssociation(
                existing: makeLayer(), contents: makeContents(includeCommentary: missing != "commentary"),
                itemId: missing == "itemId" ? nil : "new",
                localItem: missing == "localItem" ? nil : identity,
                itemText: nil, repository: repository
            )) { error in
                XCTAssertEqual(error as? SessionKitError, .persistenceFailed("shared_package_repair_item_is_unavailable"))
            }
            XCTAssertTrue(repository.events.isEmpty, missing)
            XCTAssertTrue(repository.importedCommentaryLayers.isEmpty, missing)
            XCTAssertTrue(repository.importedCommentaryInterjections.isEmpty, missing)
        }
    }

    func testRepairSavesLayerFirstThenEveryMarginAndFallsBackToUnresolved() throws {
        let repository = RecordingRepository()
        let existing = makeLayer()
        let known = makeMargin(id: "known", packageScopedId: "in-packet")
        let absent = makeMargin(id: "absent", packageScopedId: "not-in-packet")
        repository.importedCommentaryLayers[existing.id] = existing
        repository.importedCommentaryInterjections = [known.id: known, absent.id: absent]
        try SpokenMarginsPackageImporter.repairAssociation(
            existing: existing, contents: makeContents(), itemId: "new", localItem: identity,
            itemText: nil, repository: repository
        )
        XCTAssertEqual(repository.events, ["layer:layer", "load:layer", "margin:absent", "margin:known"])
        var expectedLayer = existing
        expectedLayer.itemId = "new"
        expectedLayer.sourceResolutionStatus = .resolved
        XCTAssertEqual(repository.importedCommentaryLayers, [existing.id: expectedLayer])
        var expectedKnown = known
        expectedKnown.resolution = ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 1_000, confidence: 1)
        var expectedAbsent = absent
        expectedAbsent.resolution = ImportedAnchorResolution(evidenceClass: .unresolved)
        XCTAssertEqual(repository.importedCommentaryInterjections[known.id], expectedKnown)
        XCTAssertEqual(repository.importedCommentaryInterjections[absent.id], expectedAbsent)
    }

    func testRepairKeepsPartialWritesWhenAMarginSaveThrows() throws {
        let repository = RecordingRepository()
        let existing = makeLayer()
        let first = makeMargin(id: "a", packageScopedId: "in-packet")
        let second = makeMargin(id: "b", packageScopedId: "not-in-packet")
        repository.importedCommentaryLayers[existing.id] = existing
        repository.importedCommentaryInterjections = [first.id: first, second.id: second]
        repository.failMarginId = second.id
        XCTAssertThrowsError(try SpokenMarginsPackageImporter.repairAssociation(
            existing: existing, contents: makeContents(), itemId: "new", localItem: identity,
            itemText: nil, repository: repository
        )) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("injected_margin_failure"))
        }
        XCTAssertEqual(repository.events, ["layer:layer", "load:layer", "margin:a", "margin:b"])
        XCTAssertEqual(repository.importedCommentaryLayers[existing.id]?.itemId, "new")
        XCTAssertEqual(repository.importedCommentaryInterjections[first.id]?.resolution.evidenceClass, .exactEdition)
        XCTAssertEqual(repository.importedCommentaryInterjections[second.id], second)
    }

    func testDigestRequiresAudiobookItemAndFirstValidOwnedAudiobookAsset() {
        let item = makeItem()
        let valid = makeAsset(id: "first")
        XCTAssertNil(SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: []))
        var nonAudio = item
        nonAudio.mediaType = "podcast"
        XCTAssertNil(SharedPacketItemMatcher.ownedAudiobookDigest(for: nonAudio, assets: [valid]))
        var otherItem = valid
        otherItem.itemId = "other-item"
        var otherCategory = valid
        otherCategory.category = .podcast
        var stale = valid
        stale.integrity = .stale
        var corrupt = valid
        corrupt.integrity = .corrupt
        let invalid = [otherItem, otherCategory, stale, corrupt]
        for asset in invalid {
            XCTAssertNil(SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: [asset]))
        }
        XCTAssertEqual(SharedPacketItemMatcher.ownedAudiobookDigest(
            for: item, assets: invalid + [valid, makeAsset(id: "second")]), "first")
        var noChecksum = valid
        noChecksum.checksumSHA256 = nil
        XCTAssertNil(SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: [noChecksum, valid]))
        XCTAssertTrue(isValid(makeLayer(), item: item))
        XCTAssertFalse(SharedPacketItemMatcher.layerHasValidItemAssociation(makeLayer(), item: item, ownedAudiobookDigest: nil))
    }

    private var identity: SharedItemIdentity {
        SharedItemIdentity(itemType: .other, title: "Book", durationMs: 10_000, exactEditionSHA256: digest)
    }

    private func makeItem() -> Item {
        Item(id: "item", title: "Book", mediaType: "audiobook", text: nil, externalReference: nil, status: "ready",
             media: ItemMedia(sourceType: .nativeMediaFile, durationMs: 10_000))
    }

    private func makeLayer() -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "packet-digest", packageId: "packet",
                                itemIdentity: identity, displayLabel: "Friend", importedAt: date,
                                sourceResolutionStatus: .contextOnly, isEnabled: true, isMuted: true,
                                resolvedRecipientEditionSHA256: "old-edition")
    }

    private func isValid(_ layer: ImportedCommentaryLayer, item: Item?) -> Bool {
        SharedPacketItemMatcher.layerHasValidItemAssociation(layer, item: item, ownedAudiobookDigest: digest)
    }

    private func makeAsset(id: String) -> OwnedOfflineAsset {
        OwnedOfflineAsset(id: id, itemId: "item", category: .audiobook, relativePath: "Audiobooks/book.caf",
                          byteCount: 100, checksumSHA256: id, isReproducible: false)
    }

    private func makeMargin(id: String, packageScopedId: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(id: id, layerId: "layer", packageScopedId: packageScopedId, createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
            approvedTranscript: "Keep this thought", audioPath: "IncomingPackages/old/voice.m4a", audioDurationMs: 500,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 9_000), firstHeardAt: date)
    }

    private func makeContents(includeCommentary: Bool = true) -> VerifiedSpokenMarginsPackage {
        let record = SharedInterjectionPackageRecord(packageScopedId: "in-packet", createdAt: date,
            anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000), defaultRepresentationId: "text",
            representations: [.init(id: "text", kind: .textOnly, approvedTranscript: "Keep this thought", provenance: .senderApprovedTextOnly)])
        return VerifiedSpokenMarginsPackage(
            manifest: SpokenMarginsPackageManifest(packageId: "packet", createdAt: date, contentDigest: "packet-digest",
                item: identity, itemTransport: .init(kind: .recipientSupplied), artifacts: []),
            commentaryLayers: includeCommentary ? [.init(id: "commentary", interjections: [record])] : [],
            listeningMapProposals: [], editionFingerprintSpines: [], transcriptPhraseSketches: [], embeddedTextItems: [],
            extractedAssetURLs: [:])
    }
}

private final class RecordingRepository: InMemorySessionRepository, @unchecked Sendable {
    var events: [String] = []
    var failMarginId: String?

    override func saveImportedCommentaryLayer(_ layer: ImportedCommentaryLayer) throws {
        events.append("layer:\(layer.id)")
        try super.saveImportedCommentaryLayer(layer)
    }

    override func loadImportedCommentaryInterjections(layerId: String) throws -> [ImportedCommentaryInterjection] {
        events.append("load:\(layerId)")
        return try super.loadImportedCommentaryInterjections(layerId: layerId).sorted { $0.id < $1.id }
    }

    override func saveImportedCommentaryInterjection(_ interjection: ImportedCommentaryInterjection) throws {
        events.append("margin:\(interjection.id)")
        if interjection.id == failMarginId { throw SessionKitError.persistenceFailed("injected_margin_failure") }
        try super.saveImportedCommentaryInterjection(interjection)
    }
}
