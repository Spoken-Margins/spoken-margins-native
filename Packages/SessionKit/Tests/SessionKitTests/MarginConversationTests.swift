import XCTest
@testable import SessionKit

final class MarginConversationTests: XCTestCase {
    private func node(_ id: String, parent: MarginReference? = nil, text: String = "A thought") -> MarginConversationSnapshot {
        .init(itemID: "source", conversation: .init(reference: .init(contributionID: id, revisionID: "v1"),
            authorID: "author-\(id)", authorLabel: id, parent: parent),
            anchor: .init(anchorType: .text, startChar: 20, endChar: 30), transcript: text, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testThreePersonForksMergeRegardlessOfOrderAndRepeatedPacketsAddNothing() throws {
        let a = node("a"), b = node("b", parent: node("a").conversation.reference)
        let c = node("c", parent: a.conversation.reference)
        let d = node("d", parent: b.conversation.reference)
        let left = try MarginConversationGraph.merge([a, b], [a, c, d])
        let right = try MarginConversationGraph.merge([d, c], [b, a])
        XCTAssertEqual(left, right)
        XCTAssertEqual(try MarginConversationGraph.merge(left, [a, b, c, d]), left)
        XCTAssertEqual(MarginConversationGraph.ancestors(of: d.conversation.reference, in: left).map(\.id), [a.id, b.id, d.id])
    }

    func testMissingParentCanArriveLaterButConflictingRevisionAndCycleAreRejected() throws {
        let a = node("a"), b = node("b", parent: node("a").conversation.reference)
        XCTAssertEqual(try MarginConversationGraph.merge([], [b]).count, 1)
        XCTAssertEqual(try MarginConversationGraph.merge([b], [a]).count, 2)
        XCTAssertThrowsError(try MarginConversationGraph.merge([a], [node("a", text: "Changed without a revision")]))
        XCTAssertThrowsError(try MarginConversationGraph.merge([b], [node("a", parent: b.conversation.reference)]))
    }

    func testImmutableSnapshotsPreserveBodyAcrossLocalPaths() throws {
        let a = node("a")
        let transported = MarginConversationSnapshot(itemID: "another-local-id", conversation: a.conversation,
            anchor: a.anchor, transcript: a.transcript, audioPath: "/different/container", createdAt: Date())
        XCTAssertTrue(a.hasSameContent(as: transported))
        var bad = a.conversation
        bad.context = .init(kind: .sourceText, start: 20, end: 10)
        XCTAssertThrowsError(try MarginConversationGraph.validate(bad))
        bad.context = .init(kind: .parent, start: 0, end: 0)
        XCTAssertThrowsError(try MarginConversationGraph.validate(bad))
    }
}
