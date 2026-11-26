import Foundation
import SessionKit
import XCTest

/// A friend's voice played by a Margin moment or review opens the reply window too (#5238, owner 2026-11-09).
final class MomentReplyWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    private func row(_ id: String, layer layerId: String, label: String) -> SharedMarginRow {
        var layer = ImportedCommentaryLayer(
            id: layerId, itemId: "item", packageDigest: String(repeating: "a", count: 64), packageId: layerId,
            itemIdentity: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/a", title: "A"),
            displayLabel: label, importedAt: t0
        )
        layer.isEnabled = true
        let margin = ImportedCommentaryInterjection(
            id: id, layerId: layerId, packageScopedId: "\(id)-scoped", createdAt: t0,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words \(id)",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 1_000)
        )
        return SharedMarginRow(interjection: margin, layer: layer, itemTitle: "A")
    }

    func testAFriendsMomentVoiceGivesItsDraft() throws {
        let rows = [row("c1", layer: "cole", label: "Cole"), row("a1", layer: "ana", label: "Ana")]
        let draft = try XCTUnwrap(MomentReplyWindow.draft(
            forMarginId: SharedMarginReview.marginId(layerId: "ana", interjectionId: "a1"), rows: rows))
        XCTAssertEqual(draft, MarginReplyDraft(parent: rows[1].interjection, in: rows[1].layer))
    }

    func testAnOwnMarginOrAnUnknownIdGivesNone() {
        let rows = [row("c1", layer: "cole", label: "Cole")]
        XCTAssertNil(MomentReplyWindow.draft(forMarginId: "own-margin-uuid", rows: rows), "the listener's own Margin")
        XCTAssertNil(MomentReplyWindow.draft(
            forMarginId: SharedMarginReview.marginId(layerId: "cole", interjectionId: "gone"), rows: rows), "not in the rows yet")
        XCTAssertNil(MomentReplyWindow.draft(
            forMarginId: SharedMarginReview.marginId(layerId: "cole", interjectionId: "c1"), rows: []))
    }
}
