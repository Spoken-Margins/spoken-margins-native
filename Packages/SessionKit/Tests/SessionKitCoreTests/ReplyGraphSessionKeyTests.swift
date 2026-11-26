import Foundation
import XCTest
@testable import SessionKit

/// #5133: each listening pass numbers its Margins from "ij-001", so a replay's first Margin shares its id with the
/// first listen's. A friend's reply names its parent by packet identity (digest + scoped id, `sharedAs`), which is
/// unique per Margin; the listener's own Margin must be keyed by session and id from there on, or the reply resolves
/// to the other pass's Margin (wrong place, wrong caption, merged threads).
final class ReplyGraphSessionKeyTests: XCTestCase {
    private let first = "pass-1", second = "pass-2"

    private func identity(_ scopedId: String, digest: String = "digest-mine") -> MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: digest, packageScopedId: scopedId)
    }

    private func own(_ id: String, session: String, atMs: Int, itemId: String = "item", sharedAs: [MarginPacketIdentity]? = nil) -> Interjection {
        Interjection(
            id: id, itemId: itemId, sessionId: session, targetType: .item, targetId: itemId,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(atMs)), roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: atMs),
            audioPath: "Interjections/\(session)-\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete",
            transcript: "Mine at \(atMs)", cleanedTranscript: nil, displayText: "Mine at \(atMs)", status: "active",
            sharedAs: sharedAs
        )
    }

    private var layer: ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "ben", itemId: "item", packageDigest: "digest-ben", packageId: "package-ben",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: "Ben", importedAt: Date(timeIntervalSince1970: 1_700_000_100), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: false
        )
    }

    private func reply(_ id: String, to parent: MarginPacketIdentity, at ms: Int) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "ben", packageScopedId: id, createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Reply \(id)",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: ms, confidence: 1),
            replyLinks: [MarginReplyLink(conversationId: "conversation", parentPackageDigest: parent.packageDigest, parentPackageScopedId: parent.packageScopedId)]
        )
    }

    /// Both passes hold "ij-001"; each was shared in its own packet, and Ben answered each.
    private var twoPasses: (margins: [Interjection], replies: [ImportedCommentaryInterjection]) {
        let a = identity("ij-001", digest: "digest-pass-1"), b = identity("ij-001", digest: "digest-pass-2")
        return (
            [own("ij-001", session: first, atMs: 100_000, sharedAs: [a]), own("ij-001", session: second, atMs: 700_000, sharedAs: [b])],
            [reply("to-first", to: a, at: 101_000), reply("to-second", to: b, at: 701_000)]
        )
    }

    private func scoped(_ session: String, _ id: String = "ij-001") -> String { Interjection.sessionScopedId(sessionId: session, id: id) }

    func testTheGraphLinksEachReplyToItsOwnPassesMargin() {
        let (margins, replies) = twoPasses
        let graph = MarginReplyGraph.build(localMargins: margins, layers: [layer], importedMargins: replies)
        XCTAssertEqual(parent(of: .imported("to-first"), in: graph), .local(scoped(first)))
        XCTAssertEqual(parent(of: .imported("to-second"), in: graph), .local(scoped(second)))
    }

    func testTheReviewNamesTheRightParentInEachReplyContext() throws {
        let (margins, replies) = twoPasses
        let entries = SharedMarginReview.entries(layers: [layer], records: ["ben": replies], ownMargins: margins)
        let byId = Dictionary(entries.map { ($0.interjection.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byId["to-first"]?.replyContext?.parent, .yours(interjectionId: scoped(first), mediaTimeMs: 100_000))
        XCTAssertEqual(byId["to-second"]?.replyContext?.parent, .yours(interjectionId: scoped(second), mediaTimeMs: 700_000))
        XCTAssertEqual(byId["to-first"]?.replyContext?.caption, "Reply to your Margin at 1:40")
        XCTAssertEqual(byId["to-second"]?.replyContext?.caption, "Reply to your Margin at 11:40")
    }

    func testThePlaylistPlaysEachReplysOwnParentFirst() throws {
        let (margins, replies) = twoPasses
        let entries = SharedMarginReview.entries(layers: [layer], records: ["ben": replies], ownMargins: margins)
        let steps = SharedMarginReview.playlist(for: entries, ownMargins: margins)
        XCTAssertEqual(
            steps.map { $0.entry?.interjection.id ?? "parent:\($0.ownParent?.sessionId ?? "?")" },
            ["parent:\(first)", "to-first", "parent:\(second)", "to-second"],
            "one parent per reply, from the pass the reply answered"
        )
        XCTAssertEqual(steps.compactMap(\.ownParent).map(\.anchor.mediaTimeMs), [100_000, 700_000])
        XCTAssertEqual(Set(steps.filter { $0.ownParent != nil }.map(\.anchor.marginId)).count, 2, "the two parents are two steps")
    }

    /// The thread rows and the Margins tab key an own Margin the same way, so two own Margins with one id are two rows.
    func testThreadRowsKeepTheTwoPassesApart() {
        let (margins, replies) = twoPasses
        let rows = MarginThreadPresentation.rows(itemId: "item", localMargins: margins, layers: [layer], importedMargins: replies)
        XCTAssertEqual(rows.map(\.reference), [
            .local(scoped(first)), .imported("to-first"), .local(scoped(second)), .imported("to-second")
        ])
        XCTAssertEqual(Set(rows.map(\.id)).count, 4, "no two rows share an id")
        let center = MarginsControlCenter.rows(itemId: "item", localMargins: margins, layers: [layer], importedMargins: replies)
        XCTAssertEqual(center.filter(\.isYours).map(\.timeMs), [100_000, 700_000])
    }

    /// A reply written by the last shipped build names its parent the same way (digest + scoped id): nothing in the
    /// packet changed, so it attaches in a library with one pass exactly as before.
    func testASinglePassAndAnOldFormatReplyStillAttach() throws {
        let one = identity("ij-001")
        let margins = [own("ij-001", session: first, atMs: 50_000, sharedAs: [one])]
        let old = reply("old", to: one, at: 51_000)
        let graph = MarginReplyGraph.build(localMargins: margins, layers: [layer], importedMargins: [old])
        XCTAssertEqual(parent(of: .imported("old"), in: graph), .local(scoped(first)))
        let entry = try XCTUnwrap(SharedMarginReview.entries(layers: [layer], records: ["ben": [old]], ownMargins: margins).first)
        XCTAssertEqual(entry.replyContext?.yoursParentId, scoped(first))
    }

    /// The same id on another item's pass is a different Margin, and each reply still finds its own.
    func testAnIdSharedAcrossDifferentItemsDoesNotCollide() {
        let a = identity("ij-001", digest: "digest-a"), b = identity("ij-001", digest: "digest-b")
        let margins = [
            own("ij-001", session: "other-item-pass", atMs: 10_000, itemId: "other", sharedAs: [a]),
            own("ij-001", session: first, atMs: 20_000, sharedAs: [b])
        ]
        let graph = MarginReplyGraph.build(
            localMargins: margins, layers: [layer],
            importedMargins: [reply("to-other", to: a, at: 11_000), reply("to-item", to: b, at: 21_000)]
        )
        XCTAssertEqual(parent(of: .imported("to-other"), in: graph), .local(scoped("other-item-pass")))
        XCTAssertEqual(parent(of: .imported("to-item"), in: graph), .local(scoped(first)))
    }

    /// "Play the parent" picks the row the reference names (`Gate1AppModel.playMarginParent`): the replay's own
    /// "ij-001" for a reply to it, never the first listen's.
    func testPlayTheParentMatchesOnlyTheNamedPassesMargin() throws {
        let (margins, replies) = twoPasses
        let context = try XCTUnwrap(MarginThreadPresentation.parentContext(
            of: .imported("to-second"), itemId: "item", localMargins: margins, layers: [layer], importedMargins: replies))
        XCTAssertEqual(margins.filter { context.parent.isOwnMargin($0) }.map(\.sessionId), [second])
        XCTAssertFalse(MarginReference.imported("ij-001").isOwnMargin(margins[0]))
    }

    private func parent(of reference: MarginReference, in graph: MarginReplyGraph) -> MarginReference? {
        if case .linked(let link)? = graph.states[reference] { return link.parent }
        return nil
    }
}
