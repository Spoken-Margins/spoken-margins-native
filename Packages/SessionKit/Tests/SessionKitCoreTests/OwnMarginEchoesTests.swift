import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4697: the Library row said "14 Margins from a friend · 3 new" when the friend left 3 and the other 11 were the
/// listener's own, imported back in a packet. Real temporary SQLite, because the counts come from SQL; and one table of
/// neighbouring inputs run through the SQL rule and the Swift rule together, so they cannot drift apart.
final class OwnMarginEchoesTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 5_000, confidence: 1)
    private let benId = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func withStore(items: [String], _ body: (SQLiteSessionStore) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "own-echo-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        for id in items {
            try store.saveItem(Item(id: id, title: "Title \(id)", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
            try store.saveSession(Session(
                id: "session-\(id)", itemId: id, createdAt: when, updatedAt: when, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: id, position: Position(), completionPercent: 0, playbackRate: 1))
        }
        try body(store)
    }

    private func own(_ id: String, item: String, sharedAs: [MarginPacketIdentity]?, status: String = "active") -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: "session-\(item)", targetType: .item, targetId: item, createdAt: when, roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 754_000),
            audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: status, sharedAs: sharedAs)
    }

    private func layer(_ id: String, digest: String? = nil, item: String, label: String?, sender: String? = nil) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: id, itemId: item, packageDigest: digest ?? "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label, importedAt: when, sourceResolutionStatus: .resolved, isEnabled: true)
        layer.senderId = sender
        return layer
    }

    private func margin(
        _ id: String, layer: String, scoped: String? = nil, words: String = "Listen to this part.",
        also: [MarginPacketIdentity]? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: scoped ?? id, createdAt: when,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: words,
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000, resolution: placed, alsoSharedAs: also)
    }

    // The owner's row: 11 of his own Margins came back in a packet next to the friend's 3.
    func testOwnMarginsThatCameBackAreNotCountedAsTheFriends() throws {
        try withStore(items: ["a"]) { store in
            let sent = (1...11).map { MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "margin-\(String(format: "%04d", $0))") }
            for (index, identity) in sent.enumerated() { try store.saveInterjection(own("mine-\(index)", item: "a", sharedAs: [identity])) }
            _ = try store.importCommentaryLayer(layer("ben", item: "a", label: "Ben", sender: benId), interjections: (1...3).map { margin("ben-\($0)", layer: "ben") })
            _ = try store.importCommentaryLayer(layer("mine", item: "a", label: nil), interjections: sent.map { margin("back-\($0.packageScopedId)", layer: "mine", scoped: $0.packageScopedId) })

            let tally = try XCTUnwrap(store.loadSharedMarginTallies()["a"])
            XCTAssertEqual(tally.counts, SharedMarginTally(total: 3, new: 3), "only what the friend made")
            XCTAssertEqual(tally.senderLine, "3 new Margins from Ben", "and it names the friend: Done when 2")
            XCTAssertEqual(try store.loadFriendMarginsArrivals()["a"], when, "the arrival is the friend's layer")

            // Read-only: the copies are still stored, exactly as imported, so the previous build opens the same records.
            XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "mine").count, 11)
        }
    }

    // A packet that holds only the listener's own Margins adds nothing to the row, and its sender is not a friend.
    func testAPacketOfOnlyTheListenersOwnMarginsLeavesTheRowEmpty() throws {
        try withStore(items: ["a"]) { store in
            let identity = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "m-1")
            try store.saveInterjection(own("mine", item: "a", sharedAs: [identity]))
            _ = try store.importCommentaryLayer(layer("mine", item: "a", label: "Cole", sender: benId), interjections: [margin("back", layer: "mine", scoped: "m-1")])
            XCTAssertNil(try store.loadSharedMarginTallies()["a"])
            XCTAssertNil(try store.loadFriendMarginsArrivals()["a"])
        }
    }

    // The rows of neighbouring inputs. `echo` is whether the imported Margin is a copy of the listener's own.
    private struct Row {
        let why: String
        let echo: Bool
        var ownSharedAs: [MarginPacketIdentity]? = [MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "m-1")]
        var ownItem = "a"
        var ownStatus = "active"
        var layerDigest = "digest-mine"
        var scoped = "m-1"
        var also: [MarginPacketIdentity]?
        var words = "Listen to this part."
        var label: String? = "Cole"
    }

    private var rows: [Row] {
        let mine = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "m-1")
        return [
            Row(why: "the same packet and id", echo: true),
            Row(why: "the same packet and id, no label on the layer", echo: true, label: nil),
            Row(why: "the same Margin arrived again in a later packet (alsoSharedAs)", echo: true, layerDigest: "digest-later", scoped: "x-9", also: [mine]),
            Row(why: "the own Margin was shared in two packets and this is the second", echo: true,
                ownSharedAs: [MarginPacketIdentity(packageDigest: "digest-first", packageScopedId: "f-1"), mine]),
            Row(why: "the own Margin was deleted after it was shared", echo: true, ownStatus: "deleted"),
            Row(why: "the same id from another packet", echo: false, layerDigest: "digest-other"),
            Row(why: "the same packet, another id", echo: false, scoped: "m-2"),
            Row(why: "the same words and label, no shared identity: a lookalike", echo: false, ownSharedAs: nil, words: "Listen to this part."),
            Row(why: "the same words and label, another packet", echo: false, layerDigest: "digest-other", scoped: "m-9", words: "Words"),
            Row(why: "the identity differs only by case", echo: false, layerDigest: "DIGEST-MINE"),
            Row(why: "the identity differs only by a trailing space", echo: false, scoped: "m-1 "),
            Row(why: "the own Margin is on another item", echo: false, ownItem: "b"),
            Row(why: "alsoSharedAs names someone else's identity", echo: false, layerDigest: "digest-later", scoped: "x-9",
                also: [MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "m-7")]),
            Row(why: "an empty identity list", echo: false, ownSharedAs: []),
        ]
    }

    func testTheSQLRuleAndTheSwiftRuleAgreeOnEveryRow() throws {
        for row in rows {
            // A store of its own per row: a packet already held is not imported twice, and rows share digests.
            try withStore(items: ["a", "b"]) { store in
                let ownItem = row.ownItem
                try store.saveInterjection(own("own", item: ownItem, sharedAs: row.ownSharedAs, status: row.ownStatus))
                let theLayer = layer("layer", digest: row.layerDigest, item: "a", label: row.label)
                let theMargin = margin("copy", layer: "layer", scoped: row.scoped, words: row.words, also: row.also)
                _ = try store.importCommentaryLayer(theLayer, interjections: [theMargin])

                let ownHere = ownItem == "a" ? [own("o", item: "a", sharedAs: row.ownSharedAs, status: row.ownStatus)] : []
                XCTAssertEqual(
                    OwnMarginEchoes.isEcho(theMargin, in: theLayer, ownIdentities: OwnMarginEchoes.identities(of: ownHere)),
                    row.echo, "Swift: \(row.why)")
                XCTAssertEqual(try store.loadSharedMarginTallies()["a"]?.total ?? 0, row.echo ? 0 : 1, "SQL: \(row.why)")
                XCTAssertEqual(try store.loadFriendMarginsArrivals()["a"] == nil, row.echo, "arrivals: \(row.why)")
                XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "layer").count, 1, "stored either way: \(row.why)")
            }
        }
    }

    // The offer says what the row says: a copy of the listener's own Margin is not offered as a friend's new Margin.
    func testTheReviewDoesNotOfferACopyOfTheListenersOwnMargin() {
        let mine = MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "m-1")
        let theLayer = layer("mine", item: "a", label: "Cole")
        let records = [margin("back", layer: "mine", scoped: "m-1"), margin("friends", layer: "mine", scoped: "m-2")]
        let withOwn = SharedMarginReview.entriesInMemory(layers: [theLayer], records: ["mine": records], ownMargins: [own("o", item: "a", sharedAs: [mine])])
        XCTAssertEqual(withOwn.map(\.interjection.id), ["friends"])
        let without = SharedMarginReview.entriesInMemory(layers: [theLayer], records: ["mine": records])
        XCTAssertEqual(Set(without.map(\.interjection.id)), ["back", "friends"], "with no own Margins given, nothing changes")
    }

    // The reads must still find each layer by its primary key, and look up the listener's Margins by the item index.
    func testTheEchoRuleKeepsTheCountsOffAFullScan() throws {
        try withStore(items: ["a"]) { store in
            for sql in [SQLiteSessionStore.sharedMarginTalliesSQL, SQLiteSessionStore.sharedMarginSendersSQL, SQLiteSessionStore.sharedMarginRepliesSQL] {
                let plan = try store.sharedMarginTalliesQueryPlan(of: sql)
                XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN layer") }, "plan: \(plan)")
                XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN mine") }, "plan: \(plan)")
            }
        }
    }
}
