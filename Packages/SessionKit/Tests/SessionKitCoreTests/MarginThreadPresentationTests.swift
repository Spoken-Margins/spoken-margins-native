import Foundation
import SessionKit
import XCTest

/// Replies under the Margin they answer, and the Margin to name before a reply plays (#473).
final class MarginThreadPresentationTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let digestC = String(repeating: "c", count: 64)
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    private var layerA: ImportedCommentaryLayer { layer("layer-a", digest: digestA, label: "Ana") }
    private var layerB: ImportedCommentaryLayer { layer("layer-b", digest: digestB, label: "Ben") }

    func testRepliesShowIndentedUnderTheirParentWithTheSendersLabel() {
        let aId = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let link = MarginReplyLink.replying(to: aId, parentConversationId: nil)
        let rows = MarginThreadPresentation.rows(
            itemId: "item",
            localMargins: [local("mine", at: 5_000, offset: 1)],
            layers: [layerA, layerB],
            importedMargins: [
                imported("a2", layer: "layer-a", scoped: "a-2", time: 90_000, offset: 2),
                imported("b1", layer: "layer-b", scoped: "b-1", time: nil, offset: 5, links: [link]),
                imported("a1", layer: "layer-a", scoped: "a-1", time: 30_000, offset: 3),
            ]
        )
        XCTAssertEqual(rows.map(\.reference), [.local("mine"), .imported("a1"), .imported("b1"), .imported("a2")])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 0])
        XCTAssertEqual(rows.map(\.senderLabel), ["you", "Ana", "Ben", "Ana"])
        XCTAssertEqual(rows.map(\.note), [nil, nil, nil, nil])
    }

    func testAReplyWhosePacketHasNotArrivedStandsAloneAndSaysSo() {
        let missing = MarginReplyLink.replying(to: .init(packageDigest: digestC, packageScopedId: "c-1"), parentConversationId: nil)
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [], layers: [layerB],
            importedMargins: [imported("b1", layer: "layer-b", scoped: "b-1", time: 10_000, offset: 0, links: [missing])]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].depth, 0)
        XCTAssertEqual(rows[0].note, "reply to a Margin you don't have")
    }

    func testRepliesToRepliesNestAndSiblingsGoOldestFirst() {
        let a1 = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let toA1 = MarginReplyLink.replying(to: a1, parentConversationId: nil)
        let b1 = MarginPacketIdentity(packageDigest: digestB, packageScopedId: "b-1")
        let toB1 = MarginReplyLink.replying(to: b1, parentConversationId: toA1.conversationId)
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [], layers: [layerA, layerB],
            importedMargins: [
                imported("b2", layer: "layer-b", scoped: "b-2", time: nil, offset: 9, links: [toA1]),
                imported("b3", layer: "layer-b", scoped: "b-3", time: nil, offset: 7, links: [toB1]),
                imported("b1", layer: "layer-b", scoped: "b-1", time: nil, offset: 4, links: [toA1]),
                imported("a1", layer: "layer-a", scoped: "a-1", time: 20_000, offset: 1),
            ]
        )
        XCTAssertEqual(rows.map(\.reference), [.imported("a1"), .imported("b1"), .imported("b3"), .imported("b2")])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1])
    }

    func testTheListenersOwnReplyThreadsUnderTheSharedMargin() {
        let a1 = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let mine = local("mine", at: 31_000, offset: 5).answering(
            imported("a1", layer: "layer-a", scoped: "a-1", time: 30_000, offset: 1), in: layerA
        )
        XCTAssertEqual(mine.replyTo?.parent, a1)
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [mine], layers: [layerA],
            importedMargins: [imported("a1", layer: "layer-a", scoped: "a-1", time: 30_000, offset: 1)]
        )
        XCTAssertEqual(rows.map(\.reference), [.imported("a1"), .local("mine")])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
    }

    func testTwoPacketsNamingEachOtherAsParentStillShowBothMargins() {
        let toB = MarginReplyLink.replying(to: .init(packageDigest: digestB, packageScopedId: "b-1"), parentConversationId: "c")
        let toA = MarginReplyLink.replying(to: .init(packageDigest: digestA, packageScopedId: "a-1"), parentConversationId: "c")
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [], layers: [layerA, layerB],
            importedMargins: [
                imported("a1", layer: "layer-a", scoped: "a-1", time: nil, offset: 1, links: [toB]),
                imported("b1", layer: "layer-b", scoped: "b-1", time: nil, offset: 2, links: [toA]),
            ]
        )
        XCTAssertEqual(Set(rows.map(\.reference)), [.imported("a1"), .imported("b1")])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.note), [nil, nil], "each parent is here, so neither is a reply to a Margin you don't have")
    }

    func testDeletedMarginsAndLayersAndOtherItemsStayOut() {
        var gone = layerB
        gone.deletedAt = t0
        var deleted = local("deleted", at: 1_000, offset: 1)
        deleted.status = "deleted"
        var elsewhere = local("elsewhere", at: 1_000, offset: 1)
        elsewhere.itemId = "other-item"
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [deleted, elsewhere], layers: [layerA, gone],
            importedMargins: [
                imported("a1", layer: "layer-a", scoped: "a-1", time: 1_000, offset: 1),
                imported("b1", layer: "layer-b", scoped: "b-1", time: 1_000, offset: 1),
            ]
        )
        XCTAssertEqual(rows.map(\.reference), [.imported("a1")])
    }

    func testAReplyNamesItsParentFirst() {
        let a1 = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let link = MarginReplyLink.replying(to: a1, parentConversationId: nil)
        let imports = [
            imported("a1", layer: "layer-a", scoped: "a-1", time: 30_000, offset: 1, text: "This is the key claim"),
            imported("b1", layer: "layer-b", scoped: "b-1", time: nil, offset: 2, links: [link]),
        ]
        let context = MarginThreadPresentation.parentContext(
            of: .imported("b1"), itemId: "item", localMargins: [], layers: [layerA, layerB], importedMargins: imports
        )
        XCTAssertEqual(context, .init(parent: .imported("a1"), senderLabel: "Ana", text: "This is the key claim"))
        XCTAssertNil(MarginThreadPresentation.parentContext(
            of: .imported("a1"), itemId: "item", localMargins: [], layers: [layerA, layerB], importedMargins: imports
        ), "a Margin that starts a thread has nothing to play first")
        XCTAssertNil(MarginThreadPresentation.parentContext(
            of: .imported("b1"), itemId: "item", localMargins: [], layers: [layerB], importedMargins: [imports[1]]
        ), "a missing parent can't be played")
    }

    func testAnUnnamedSenderReadsAsSomeone() {
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [], layers: [layer("layer-x", digest: digestC, label: "  ")],
            importedMargins: [imported("x1", layer: "layer-x", scoped: "x-1", time: 1, offset: 0)]
        )
        XCTAssertEqual(rows.map(\.senderLabel), ["Someone"])
    }

    // MARK: Fixtures

    private func layer(_ id: String, digest: String, label: String?) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: digest, packageId: id, itemIdentity: item, displayLabel: label, importedAt: t0
        )
        layer.isEnabled = true
        return layer
    }

    private var item: SharedItemIdentity { SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/a", title: "A") }

    private func local(_ id: String, at timeMs: Int, offset: TimeInterval) -> Interjection {
        var anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "")
        anchor.mediaTimeMs = timeMs
        return Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: t0.addingTimeInterval(offset), roughPercent: 0, anchor: anchor,
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "Mine \(id)",
            cleanedTranscript: nil, displayText: "Mine \(id)", status: "active", captureKind: .written
        )
    }

    func testAListFilteredToOneSendersMarginKeepsTheWholeConversation() {
        let a1 = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let toA1 = MarginReplyLink.replying(to: a1, parentConversationId: nil)
        let rows = MarginThreadPresentation.rows(
            itemId: "item", localMargins: [local("mine", at: 5_000, offset: 6)], layers: [layerA, layerB],
            importedMargins: [
                imported("a1", layer: "layer-a", scoped: "a-1", time: 20_000, offset: 1),
                imported("b1", layer: "layer-b", scoped: "b-1", time: nil, offset: 4, links: [toA1]),
                imported("b9", layer: "layer-b", scoped: "b-9", time: 90_000, offset: 3),
            ]
        )
        let kept = MarginThreadPresentation.threads(in: rows) { $0.reference == .imported("b1") }
        XCTAssertEqual(kept.map(\.reference), [.imported("a1"), .imported("b1")], "the reply keeps its parent; the other threads go")
        XCTAssertEqual(MarginThreadPresentation.threads(in: rows) { _ in false }, [])
        XCTAssertEqual(MarginThreadPresentation.threads(in: [], containing: { _ in true }), [])
    }

    func testTheReplyDraftNamesTheMarginItAnswers() {
        let parent = imported("a1", layer: "layer-a", scoped: "a-1", time: 20_000, offset: 1, text: "The author never says why.")
        let draft = MarginReplyDraft(parent: parent, in: layerA)
        XCTAssertEqual(draft.link, parent.replyLink(in: layerA))
        XCTAssertEqual(draft.caption, "Replying to Ana: \u{201C}The author never says why.\u{201D}")
        let long = imported("a2", layer: "layer-a", scoped: "a-2", time: nil, offset: 2, text: String(repeating: "word ", count: 60))
        XCTAssertTrue(MarginReplyDraft(parent: long, in: layerA).caption.hasSuffix("…\u{201D}"))
        let blank = imported("a3", layer: "layer-a", scoped: "a-3", time: nil, offset: 3, text: "  ")
        XCTAssertEqual(MarginReplyDraft(parent: blank, in: layerA).caption, "Replying to Ana")
    }

    private func imported(
        _ id: String, layer: String, scoped: String, time: Int?, offset: TimeInterval,
        links: [MarginReplyLink]? = nil, text: String? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: scoped, createdAt: t0.addingTimeInterval(offset),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: text ?? "Words \(id)",
            resolution: ImportedAnchorResolution(evidenceClass: time == nil ? .unresolved : .exactEdition, localMediaTimeMs: time),
            replyLinks: links
        )
    }
}
