import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// A friend who shares again sends the Margins they already sent (#858). Each row is a neighbouring
/// input of the matching rule, run through a real SQLite Library. The same flow with real packets
/// is in SessionKitTests/CoopResendTests.
final class ImportedMarginResendsTests: XCTestCase {
    private var folder: URL!
    private var store: SQLiteSessionStore!
    private let item = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/episodes/harbour-lights", title: "Harbour Lights")
    private var clock = Date(timeIntervalSince1970: 1_777_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("resends-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The rows

    func testTheSamePacketTwiceIsOneLayer() throws {
        let first = packet("O", from: "Ada", [("hello", 60_000), ("again", 120_000)])
        XCTAssertTrue(try send(first).isImported)
        XCTAssertFalse(try send(first).isImported)
        XCTAssertEqual(try visible(), ["Ada|60000|hello", "Ada|120000|again"].sorted())
    }

    func testTheUpdateAfterTheOriginalAddsOnlyTheNewMargin() throws {
        let original = packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)])
        let update = packet("U", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)])
        XCTAssertTrue(try send(original).isImported)
        guard case .imported(_, let ids) = try send(update) else { return XCTFail("the update brings a new Margin") }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try visible(), ["Ada|60000|one", "Ada|120000|two", "Ada|180000|three"].sorted())
        // The update's names for the Margins already held are kept on them.
        XCTAssertEqual(try identities(of: "one"), [id("O", "O-1"), id("U", "U-1")].sorted(by: Self.order))
    }

    func testTheUpdateBeforeTheOriginalLeavesTheOriginalOut() throws {
        let original = packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)])
        let update = packet("U", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)])
        XCTAssertTrue(try send(update).isImported)
        XCTAssertFalse(try send(original).isImported, "everything in it is already held")
        XCTAssertEqual(try visible(), ["Ada|60000|one", "Ada|120000|two", "Ada|180000|three"].sorted())
        XCTAssertEqual(try identities(of: "one"), [id("O", "O-1"), id("U", "U-1")].sorted(by: Self.order))
        // Opening the original again changes nothing.
        XCTAssertFalse(try send(original).isImported)
        XCTAssertEqual(try identities(of: "one").count, 2)
    }

    func testEveryOrderOfThreeShareGivesTheSameMargins() throws {
        let packets = [
            packet("O", from: "Ada", [("one", 60_000)]),
            packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]),
            packet("V", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)]),
        ]
        var outcomes: Set<[String]> = []
        var names: Set<[String]> = []
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            try setUpWithError()
            for index in order { _ = try send(packets[index]) }
            outcomes.insert(try visible())
            names.insert(try ["one", "two", "three"].map { try identities(of: $0).map { "\($0.packageDigest)/\($0.packageScopedId)" }.joined(separator: ",") })
            XCTAssertEqual(try visible().count, 3, "order \(order)")
        }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(names.count, 1, "each Margin is known by every packet name in any order")
    }

    func testAMarginTheFriendDeletedBetweenSharesStaysHeld() throws {
        // The update no longer has "one"; the listener may have heard it or replied to it.
        let original = packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)])
        let update = packet("U", from: "Ada", [("two", 120_000), ("three", 180_000)])
        for order in [[original, update], [update, original]] {
            try setUpWithError()
            for packet in order { _ = try send(packet) }
            XCTAssertEqual(try visible(), ["Ada|60000|one", "Ada|120000|two", "Ada|180000|three"].sorted())
        }
    }

    func testEditedWordsAreAnotherMargin() throws {
        // Without a stable id in the packet an edit can't be told from a new Margin at the same place.
        _ = try send(packet("O", from: "Ada", [("teh point", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("the point", 60_000)]))
        XCTAssertEqual(try visible(), ["Ada|60000|teh point", "Ada|60000|the point"].sorted())
    }

    func testTheSameWordsAtAnotherPlaceAreAnotherMargin() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000), ("love this", 600_000)]))
        XCTAssertEqual(try visible(), ["Ada|60000|love this", "Ada|600000|love this"].sorted())
    }

    func testTheSameWordsAtTheSamePlaceFromAnotherPersonAreNotMerged() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ben", [("love this", 60_000)]))
        XCTAssertEqual(try visible(), ["Ada|60000|love this", "Ben|60000|love this"].sorted())
    }

    func testTwoPeopleWithOneLabelNeedTheSameWordsPlaceAndVoice() throws {
        _ = try send(packet("O", from: "Sam", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Sam", [("love this", 61_000), ("love this!", 60_000)]))
        XCTAssertEqual(try visible().count, 3)
    }

    func testAVoiceMarginAndATextMarginAreNotTheSame() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], voiceMs: 4_000))
        XCTAssertEqual(try visible().count, 2)
        _ = try send(packet("V", from: "Ada", [("love this", 60_000)], voiceMs: 4_000))
        XCTAssertEqual(try visible().count, 2, "the same voice Margin again is the one already held")
    }

    func testAcousticEvidenceIdsDoNotMakeAMarginNew() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], evidence: ["signature-a"]))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], evidence: ["signature-b"]))
        XCTAssertEqual(try visible().count, 1)
    }

    func testSpacesAroundTheWordsDoNotMakeAMarginNew() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("  love this\n", 60_000)]))
        XCTAssertEqual(try visible().count, 1)
    }

    func testTheSameMarginsOnAnotherItemAreKept() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], itemId: "item-1"))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], itemId: "item-2"))
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "item-1").count, 1)
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "item-2").count, 1)
    }

    func testASenderWithNoLabelIsNeverMerged() throws {
        _ = try send(packet("O", from: nil, [("love this", 60_000)]))
        _ = try send(packet("U", from: nil, [("love this", 60_000)]))
        XCTAssertEqual(try visible().count, 2)
    }

    func testAPacketWithoutAnItemYetIsImportedWhole() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], itemId: nil))
        XCTAssertTrue(try send(packet("U", from: "Ada", [("love this", 60_000)], itemId: nil)).isImported)
    }

    func testTwoIdenticalMarginsInOnePacketKeepBothAndAreNotCountedAgain() throws {
        // Said twice at the same place: both stay. The update that carries both adds neither.
        _ = try send(packet("O", from: "Ada", [("mm", 60_000), ("mm", 60_000)]))
        XCTAssertFalse(try send(packet("U", from: "Ada", [("mm", 60_000), ("mm", 60_000)])).isImported)
        XCTAssertEqual(try visible().count, 2)
        // A third one is new.
        XCTAssertTrue(try send(packet("V", from: "Ada", [("mm", 60_000), ("mm", 60_000), ("mm", 60_000)])).isImported)
        XCTAssertEqual(try visible().count, 3)
    }

    func testALayerTheListenerDeletedIsBroughtBackByTheUpdate() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var layer = try XCTUnwrap(store.loadImportedCommentaryLayers(itemId: "item-1").first)
        layer.deletedAt = clock
        try store.saveImportedCommentaryLayer(layer)
        _ = try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]))
        let live = try store.loadImportedCommentaryLayers(itemId: "item-1").filter { $0.deletedAt == nil }
        XCTAssertEqual(try live.flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }.count, 2)
    }

    func testALayerForTheWrongSourceDoesNotAbsorbTheUpdate() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var layer = try XCTUnwrap(store.loadImportedCommentaryLayers(itemId: "item-1").first)
        layer.sourceResolutionStatus = .wrongSource
        try store.saveImportedCommentaryLayer(layer)
        XCTAssertTrue(try send(packet("U", from: "Ada", [("one", 60_000)])).isImported)
    }

    func testAMarginTheListenerHeardIsNotNewAgain() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        let held = try XCTUnwrap(try margins().first)
        let heardAt = clock
        _ = try store.markImportedCommentaryInterjectionHeard(id: held.id, at: heardAt)
        _ = try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]))
        let all = try margins()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.approvedTranscript == "one" }?.firstHeardAt, heardAt)
        XCTAssertNil(all.first { $0.approvedTranscript == "two" }?.firstHeardAt)
    }

    // MARK: Replies

    func testARepliesParentIsFoundByEitherPacketsName() throws {
        let replyToOriginal = reply("R1", parent: id("O", "O-1"))
        let replyToUpdate = reply("R2", parent: id("U", "U-2"))
        for order in [["O", "U"], ["U", "O"]] {
            try setUpWithError()
            let packets = ["O": packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)]),
                           "U": packet("U", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)])]
            for name in order { _ = try send(packets[name]!) }
            _ = try send(replyToOriginal)
            _ = try send(replyToUpdate)
            let graph = try graph()
            let parentOfOne = try XCTUnwrap(margins().first { $0.approvedTranscript == "one" })
            let parentOfTwo = try XCTUnwrap(margins().first { $0.approvedTranscript == "two" })
            for (text, parent) in [("reply to O-1", parentOfOne), ("reply to U-2", parentOfTwo)] {
                let reply = try XCTUnwrap(margins().first { $0.approvedTranscript == text })
                guard case .linked(let link)? = graph.states[.imported(reply.id)] else { return XCTFail("\(text) lost its parent in order \(order)") }
                XCTAssertEqual(link.parent, .imported(parent.id), "\(text) in order \(order)")
            }
        }
    }

    func testAReplySharedAgainKeepsOneCopyAndOneThread() throws {
        let original = packet("O", from: "Ada", [("one", 60_000)])
        let ben1 = reply("B1", parent: id("O", "O-1"), from: "Ben")
        _ = try send(original)
        _ = try send(ben1)
        // Ben shares again; his reply is in the update too.
        let ben2 = packet("B2", from: "Ben", [("reply to O-1", 60_000), ("and another", 90_000)], links: [MarginReplyLink.replying(to: id("O", "O-1"), parentConversationId: nil)])
        _ = try send(ben2)
        let bens = try margins().filter { $0.approvedTranscript.hasPrefix("reply") }
        XCTAssertEqual(bens.count, 1)
        // Ben's first reply is known by both packets (2 edges); the new one by one.
        XCTAssertEqual(try graph().threads.values.map(\.count), [3])
    }

    // MARK: Storage

    func testAMarginThatArrivedOnceSavesExactlyAsBefore() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(try XCTUnwrap(margins().first)), as: UTF8.self)
        XCTAssertFalse(json.contains("alsoSharedAs"), json)
    }

    func testARecordFromBeforeThisChangeStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let margin = ImportedCommentaryInterjection(
            id: "m", layerId: "l", packageScopedId: "s", createdAt: clock,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1), approvedTranscript: "words"
        )
        let decoded = try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: try encoder.encode(margin))
        XCTAssertNil(decoded.alsoSharedAs)
        var marked = margin
        marked.alsoSharedAs = [id("U", "U-1")]
        XCTAssertEqual(try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: try encoder.encode(marked)), marked)
    }

    // MARK: Helpers

    private struct Packet {
        let digest: String
        let label: String?
        let itemId: String?
        let margins: [ImportedCommentaryInterjection]
        let links: [MarginReplyLink]
    }

    private func id(_ digest: String, _ scoped: String) -> MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: digest, packageScopedId: scoped)
    }

    private static func order(_ lhs: MarginPacketIdentity, _ rhs: MarginPacketIdentity) -> Bool {
        (lhs.packageDigest, lhs.packageScopedId) < (rhs.packageDigest, rhs.packageScopedId)
    }

    /// A packet's Margins as the importer builds them: new local ids, the packet's own scoped ids.
    private func packet(
        _ digest: String, from label: String?, _ margins: [(String, Int)],
        voiceMs: Int? = nil, evidence: [String] = [], itemId: String? = "item-1", links: [MarginReplyLink] = []
    ) -> Packet {
        Packet(
            digest: digest, label: label, itemId: itemId,
            margins: margins.enumerated().map { index, margin in
                ImportedCommentaryInterjection(
                    id: "local-\(digest)-\(index + 1)", layerId: "layer-\(digest)", packageScopedId: "\(digest)-\(index + 1)",
                    // The time the packet was made, as the app stamps it: never the same twice.
                    createdAt: clock.addingTimeInterval(Double(digest.unicodeScalars.first!.value)),
                    anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: margin.1, machineEvidenceAssetIds: evidence),
                    approvedTranscript: margin.0,
                    audioDurationMs: voiceMs,
                    replyLinks: links.isEmpty ? nil : links
                )
            },
            links: links
        )
    }

    private func reply(_ digest: String, parent: MarginPacketIdentity, from label: String = "Ben") -> Packet {
        let link = MarginReplyLink.replying(to: parent, parentConversationId: nil)
        return packet(digest, from: label, [("reply to \(parent.packageScopedId)", 60_000)], links: [link])
    }

    @discardableResult
    private func send(_ packet: Packet) throws -> ImportedCommentaryImportDisposition {
        let layer = ImportedCommentaryLayer(
            id: "layer-\(packet.digest)", itemId: packet.itemId, packageDigest: packet.digest, packageId: "package-\(packet.digest)",
            itemIdentity: item, displayLabel: packet.label, importedAt: clock, isEnabled: true
        )
        clock = clock.addingTimeInterval(1)
        // The app asks the store first; a packet with a layer is a duplicate there.
        return try ImportedMarginResends.importLayer(layer, interjections: packet.margins, repository: store)
    }

    private func layers() throws -> [ImportedCommentaryLayer] {
        try ["item-1", "item-2"].flatMap { try store.loadImportedCommentaryLayers(itemId: $0) }
    }

    private func margins() throws -> [ImportedCommentaryInterjection] {
        try layers().flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
    }

    /// What the listener has, by sender, place and words. Layers don't count: which packet holds a Margin
    /// depends on the order they arrived in.
    private func visible() throws -> [String] {
        let labels = Dictionary(uniqueKeysWithValues: try layers().map { ($0.id, $0.displayLabel ?? "?") })
        return try margins().map {
            "\(labels[$0.layerId] ?? "?")|\($0.anchorEvidence.mediaTimeMs ?? -1)|\($0.approvedTranscript)"
        }.sorted()
    }

    private func identities(of words: String) throws -> [MarginPacketIdentity] {
        let layers = try layers()
        let margin = try XCTUnwrap(margins().first { $0.approvedTranscript == words })
        let digest = try XCTUnwrap(layers.first { $0.id == margin.layerId }).packageDigest
        return ([id(digest, margin.packageScopedId)] + (margin.alsoSharedAs ?? [])).sorted(by: Self.order)
    }

    private func graph() throws -> MarginReplyGraph {
        MarginReplyGraph.build(localMargins: [], layers: try layers(), importedMargins: try margins())
    }
}

private extension ImportedCommentaryImportDisposition {
    var isImported: Bool {
        if case .imported = self { return true }
        return false
    }
}
