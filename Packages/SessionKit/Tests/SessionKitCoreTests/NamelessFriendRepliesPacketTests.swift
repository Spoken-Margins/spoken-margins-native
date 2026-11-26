import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest

/// #5337, found by the #4785 real-use run: a friend who never set a name shares replies by file, round after round.
/// Each replies packet carries every reply so far. The packets name no sender, only the phone's random sender id
/// (#2846), so the importer used to treat each one as a stranger's and kept every earlier reply again: after round two
/// the listener held reply one twice and catch-up replayed it.
///
/// Real packets: the builder writes each one, the archive writes and reads it back, and the importer saves it into a
/// real SQLite Library, as on the listener's phone.
final class NamelessFriendRepliesPacketTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)
    private let friendSession = "session-\(UUID().uuidString.lowercased())"
    private let friendPhone = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    private let parent = MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "margin-0001")
    private var imports = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NamelessReplies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("listener.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEachCumulativeRepliesPacketAddsOnlyItsNewReply() throws {
        try importPacket(replies(["Friend reply one"], round: 1))
        let first = try XCTUnwrap(try margins().first)
        XCTAssertNil(try layers().first?.displayLabel, "the packet names nobody")
        _ = try store.markImportedCommentaryInterjectionHeard(id: first.id, at: createdAt)

        guard case .imported(_, let added) = try importPacket(replies(["Friend reply one", "Friend reply two"], round: 2)) else {
            return XCTFail("reply two is new")
        }
        XCTAssertEqual(added.count, 1)
        try importPacket(replies(["Friend reply one", "Friend reply two", "Friend reply three"], round: 3))

        let held = try margins()
        XCTAssertEqual(held.map(\.approvedTranscript).sorted(), ["Friend reply one", "Friend reply three", "Friend reply two"])
        XCTAssertEqual(held.filter(\.isNewToListener).map(\.approvedTranscript).sorted(), ["Friend reply three", "Friend reply two"],
                       "catch-up has only the replies not yet heard")
        XCTAssertTrue(held.allSatisfy { $0.replyLinks?.first?.parent == parent }, "every reply still answers the listener's Margin")
    }

    func testANamelessPacketWithNoSenderIdIsStillImportedWhole() throws {
        try importPacket(replies(["Friend reply one"], round: 1, withSenderID: false))
        try importPacket(replies(["Friend reply one", "Friend reply two"], round: 2, withSenderID: false))
        XCTAssertEqual(try margins().count, 3, "with no label and no id there is nobody to compare against")
    }

    // MARK: Helpers

    /// The friend's replies packet for one round: every reply so far, as the reply-back share sends them.
    private func replies(_ words: [String], round: Int, withSenderID: Bool = true) throws -> URL {
        let phone = withSenderID ? friendPhone : nil
        let link = MarginReplyLink.replying(to: parent, parentConversationId: nil)
        let selections = words.enumerated().map { index, text in
            ReviewedInterjectionSelection(
                packageScopedId: String(format: "margin-%04d", index + 1),
                revision: InterjectionShareRevision(
                    id: "share-revision-\(round)-\(index)", interjectionId: "ij-\(index + 1)", itemId: "episode",
                    sessionId: friendSession, createdAt: createdAt.addingTimeInterval(Double(round)), approvedTranscript: text,
                    anchorBefore: "", anchorAfter: "", status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 600_000 + index * 1_000),
                representation: .textOnly,
                replyTo: link
            )
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-round-\(round)", createdAt: createdAt.addingTimeInterval(Double(round)),
            item: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/music-and-your-mind", title: "Music and Your Mind"),
            itemTransportSelection: .reference, selections: selections,
            senderDisplayLabel: nil, senderID: phone
        )
        let url = root.appendingPathComponent("round-\(round).spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        return url
    }

    @discardableResult
    private func importPacket(_ url: URL) throws -> ImportedCommentaryImportDisposition {
        imports += 1
        let contents = try SpokenMarginsPackageArchive.read(
            from: url, extractingAssetsTo: root.appendingPathComponent("import-\(imports)", isDirectory: true))
        return try SpokenMarginsPackageImporter.importPackage(contents, itemId: "episode", importedAt: createdAt, repository: store)
    }

    private func layers() throws -> [ImportedCommentaryLayer] {
        try store.loadImportedCommentaryLayers(itemId: "episode")
    }

    private func margins() throws -> [ImportedCommentaryInterjection] {
        try layers().flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
    }
}
