import Foundation
import SessionKit
import XCTest

/// The decisions the packet import flow makes before it touches files or the database (#318). The app's
/// `SpokenMarginsPackageImportCoordinatorTests` still run the whole flow against a real store; each case here
/// is one row of the same rules without one.
final class PackageImportPolicyTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func layer(
        itemId: String? = "item-1",
        status: ImportedSourceResolutionStatus = .resolved
    ) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer-1", itemId: itemId, packageDigest: "digest-1", packageId: "package-1",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Harbour Lights"),
            importedAt: clock, sourceResolutionStatus: status)
    }

    private func item(id: String = "item-1", deleted: Bool = false) -> Item {
        Item(id: id, title: "Harbour Lights", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
             deletedAt: deleted ? clock : nil)
    }

    // MARK: duplicateCheck

    func testNoEarlierImportGoesToReview() {
        var asked = false
        let check = PackageImportPolicy.duplicateCheck(
            existing: nil, loadItem: { _ in asked = true; return self.item() }, hasValidItemAssociation: { _, _ in true })
        XCTAssertEqual(check, .review(isRepair: false))
        XCTAssertFalse(asked, "with nothing imported there is no item to load")
    }

    func testAnEarlierImportOnAValidItemIsAlreadyImported() {
        let check = PackageImportPolicy.duplicateCheck(
            existing: layer(), loadItem: { _ in self.item() }, hasValidItemAssociation: { _, _ in true })
        XCTAssertEqual(check, .alreadyImported(itemId: "item-1"))
    }

    func testEarlierImportsThatNoLongerStandGoToRepairReview() {
        let rows: [(String, ImportedCommentaryLayer, Item?, Bool)] = [
            ("wrong source", layer(status: .wrongSource), item(), true),
            ("layer has no item", layer(itemId: nil), item(), true),
            ("item no longer loads", layer(), nil, true),
            ("item deleted", layer(), item(deleted: true), true),
            ("item is a different work", layer(), item(), false),
        ]
        for (name, existing, loaded, sameWork) in rows {
            let check = PackageImportPolicy.duplicateCheck(
                existing: existing, loadItem: { _ in loaded }, hasValidItemAssociation: { _, _ in sameWork })
            XCTAssertEqual(check, .review(isRepair: true), name)
        }
    }

    func testTheLaterChecksRunOnlyAsFarAsTheEarlierOnesPass() {
        var loads = 0
        var comparisons = 0
        _ = PackageImportPolicy.duplicateCheck(
            existing: layer(status: .wrongSource),
            loadItem: { _ in loads += 1; return self.item() },
            hasValidItemAssociation: { _, _ in comparisons += 1; return true })
        XCTAssertEqual(loads, 0)
        _ = PackageImportPolicy.duplicateCheck(
            existing: layer(), loadItem: { _ in loads += 1; return self.item(deleted: true) },
            hasValidItemAssociation: { _, _ in comparisons += 1; return true })
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(comparisons, 0, "a deleted item is never compared")
    }

    func testTheItemIsLoadedByTheLayersItemId() {
        var requested: String?
        _ = PackageImportPolicy.duplicateCheck(
            existing: layer(itemId: "item-9"), loadItem: { requested = $0; return self.item(id: $0) },
            hasValidItemAssociation: { layer, item in
                XCTAssertEqual(layer.id, "layer-1")
                XCTAssertEqual(item.id, "item-9")
                return true
            })
        XCTAssertEqual(requested, "item-9")
    }

    // MARK: itemSource

    func testTheMatchingLibraryItemWinsOverEveryTransport() {
        for kind in [SharedItemTransportKind.reference, .embeddedText, .recipientSupplied] {
            for type in [SharedItemType.text, .podcast, .pdf, .epub, .other] {
                XCTAssertEqual(
                    PackageImportPolicy.itemSource(matchingItemId: "item-3", transportKind: kind, itemType: type),
                    .existing(itemId: "item-3"), "\(kind) \(type)")
            }
        }
    }

    func testWithoutAMatchEmbeddedTextIsInstalledWhateverTheItemType() {
        for type in [SharedItemType.text, .podcast, .pdf, .epub, .other] {
            XCTAssertEqual(
                PackageImportPolicy.itemSource(matchingItemId: nil, transportKind: .embeddedText, itemType: type),
                .embeddedText, "\(type)")
        }
    }

    func testWithoutAMatchOrEmbeddedTextPodcastsAreFetchedAsEpisodesAndTheRestAsArticles() {
        for kind in [SharedItemTransportKind.reference, .recipientSupplied] {
            XCTAssertEqual(
                PackageImportPolicy.itemSource(matchingItemId: nil, transportKind: kind, itemType: .podcast),
                .acquirePodcast, "\(kind)")
            for type in [SharedItemType.text, .pdf, .epub, .other] {
                XCTAssertEqual(
                    PackageImportPolicy.itemSource(matchingItemId: nil, transportKind: kind, itemType: type),
                    .acquireArticle, "\(kind) \(type)")
            }
        }
    }
}
