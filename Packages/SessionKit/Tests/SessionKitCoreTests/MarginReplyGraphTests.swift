import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// Reply links on saved Margins, and the threads worked out from them (#472). The packet half is
/// in SessionKitTests/MarginReplyPacketTests.
final class MarginReplyGraphTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    func testMarginsWithoutRepliesSaveExactlyAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = String(decoding: try encoder.encode(margin("m")), as: UTF8.self)
        XCTAssertFalse(plain.contains("replyTo") || plain.contains("sharedAs"), plain)
        let imported = String(decoding: try encoder.encode(importedMargin("i", layer: "layer", scoped: "s")), as: UTF8.self)
        XCTAssertFalse(imported.contains("replyLinks"), imported)
    }

    func testReplyLinksSurviveTheSQLiteStore() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("reply-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        let link = MarginReplyLink.replying(to: .init(packageDigest: digestA, packageScopedId: "a-1"), parentConversationId: nil)
        let reply = margin("r", replyTo: link).recordingShare(as: .init(packageDigest: digestB, packageScopedId: "b-1"))
        try store.saveInterjection(reply)
        XCTAssertEqual(try store.loadInterjections(sessionId: "session").first, reply)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testAReplyToAReplyStaysInItsConversation() {
        let root = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let first = MarginReplyLink.replying(to: root, parentConversationId: nil)
        XCTAssertEqual(first.conversationId, MarginReplyLink.conversationId(rootedAt: root))
        XCTAssertEqual(first, MarginReplyLink.replying(to: root, parentConversationId: nil), "two listeners answering one Margin share a conversation")
        let layer = ImportedCommentaryLayer(id: "layer-b", packageDigest: digestB, packageId: "b", itemIdentity: item, importedAt: date)
        let bReply = importedMargin("b", layer: layer.id, scoped: "b-1", links: [first])
        let second = bReply.replyLink(in: layer)
        XCTAssertEqual(second.conversationId, first.conversationId)
        XCTAssertEqual(second.parent, MarginPacketIdentity(packageDigest: digestB, packageScopedId: "b-1"))
    }

    func testRecordingTheSameShareTwiceKeepsOneIdentity() {
        let identity = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        XCTAssertEqual(margin("m").recordingShare(as: identity).recordingShare(as: identity).sharedAs, [identity])
    }

    func testTheListenersOwnMarginWinsOverACopyTheyImportedBack() {
        let identity = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let link = MarginReplyLink.replying(to: identity, parentConversationId: nil)
        let own = margin("own").recordingShare(as: identity)
        let layerA = ImportedCommentaryLayer(id: "layer-a", packageDigest: digestA, packageId: "a", itemIdentity: item, importedAt: date)
        let layerB = ImportedCommentaryLayer(id: "layer-b", packageDigest: digestB, packageId: "b", itemIdentity: item, importedAt: date)
        let graph = MarginReplyGraph.build(
            localMargins: [own],
            layers: [layerA, layerB],
            importedMargins: [importedMargin("copy", layer: "layer-a", scoped: "a-1"), importedMargin("reply", layer: "layer-b", scoped: "b-1", links: [link])]
        )
        XCTAssertEqual(graph.states[.imported("reply")], .linked(.init(link: link, parent: .local("own"))))
    }

    /// Codex audit on 8fe7edf: a deleted local Margin overrode the live copy imported back.
    func testADeletedLocalMarginIsNeitherAParentNorAReply() {
        let identity = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let link = MarginReplyLink.replying(to: identity, parentConversationId: nil)
        var deletedOwn = margin("own").recordingShare(as: identity)
        deletedOwn.status = "deleted"
        var deletedReply = margin("mine", replyTo: link).recordingShare(as: .init(packageDigest: digestB, packageScopedId: "b-9"))
        deletedReply.status = "deleted"
        let layerA = ImportedCommentaryLayer(id: "layer-a", packageDigest: digestA, packageId: "a", itemIdentity: item, importedAt: date)
        let layerB = ImportedCommentaryLayer(id: "layer-b", packageDigest: digestB, packageId: "b", itemIdentity: item, importedAt: date)
        let graph = MarginReplyGraph.build(
            localMargins: [deletedOwn, deletedReply],
            layers: [layerA, layerB],
            importedMargins: [importedMargin("copy", layer: "layer-a", scoped: "a-1"), importedMargin("reply", layer: "layer-b", scoped: "b-1", links: [link])]
        )
        XCTAssertEqual(graph.states[.imported("reply")], .linked(.init(link: link, parent: .imported("copy"))))
        XCTAssertNil(graph.states[.local("mine")])
        XCTAssertEqual(graph.threads, [link.conversationId: [.init(reply: .init(packageDigest: digestB, packageScopedId: "b-1"), parent: identity)]])
    }

    func testADeletedLayerIsNotAParentAndAnUnsharedReplyHasNoThreadYet() {
        let identity = MarginPacketIdentity(packageDigest: digestA, packageScopedId: "a-1")
        let link = MarginReplyLink.replying(to: identity, parentConversationId: nil)
        let deleted = ImportedCommentaryLayer(id: "layer-a", packageDigest: digestA, packageId: "a", itemIdentity: item, importedAt: date, deletedAt: date)
        let parent = importedMargin("parent", layer: "layer-a", scoped: "a-1")
        let reply = margin("mine", replyTo: link)
        XCTAssertEqual(
            MarginReplyGraph.build(localMargins: [reply], layers: [deleted], importedMargins: [parent]).states[.local("mine")],
            .parentMissing(link)
        )
        let live = ImportedCommentaryLayer(id: "layer-a", packageDigest: digestA, packageId: "a", itemIdentity: item, importedAt: date)
        let graph = MarginReplyGraph.build(localMargins: [reply], layers: [live], importedMargins: [parent])
        XCTAssertEqual(graph.states[.local("mine")], .linked(.init(link: link, parent: .imported("parent"))))
        XCTAssertTrue(graph.threads.isEmpty, "a reply joins the shared threads once it has been shared")
        let shared = reply.recordingShare(as: .init(packageDigest: digestB, packageScopedId: "b-1"))
        XCTAssertEqual(
            MarginReplyGraph.build(localMargins: [shared], layers: [live], importedMargins: [parent]).threads,
            [link.conversationId: [.init(reply: .init(packageDigest: digestB, packageScopedId: "b-1"), parent: identity)]]
        )
    }

    private let date = Date(timeIntervalSince1970: 1_777_000_000)
    private var item: SharedItemIdentity { SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/a", title: "A") }

    private func margin(_ id: String, replyTo: MarginReplyLink? = nil) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date, roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: "active", captureKind: .written, replyTo: replyTo
        )
    }

    private func importedMargin(_ id: String, layer: String, scoped: String, links: [MarginReplyLink]? = nil) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: scoped, createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Words", replyLinks: links
        )
    }
}
