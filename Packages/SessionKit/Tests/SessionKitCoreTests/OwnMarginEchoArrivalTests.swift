import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4910, PR 1: the in-memory rule for friend Margins, the arrival counts and the item's own Margins from every
/// session. Real temporary SQLite where a store is involved.
final class OwnMarginEchoArrivalTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 5_000, confidence: 1)

    private func withStore(sessions: [String] = ["s1"], _ body: (SQLiteSessionStore) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "own-echo-arrival-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "a", title: "A", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
        for id in sessions {
            try store.saveSession(Session(
                id: id, itemId: "a", createdAt: when, updatedAt: when, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: "a", position: Position(), completionPercent: 0, playbackRate: 1))
        }
        try body(store)
    }

    private func identity(_ n: Int) -> MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "margin-\(String(format: "%04d", n))")
    }

    private func own(_ id: String, session: String = "s1", sharedAs: [MarginPacketIdentity]?, status: String = "active") -> Interjection {
        Interjection(
            id: id, itemId: "a", sessionId: session, targetType: .item, targetId: "a", createdAt: when, roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 754_000),
            audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: status, sharedAs: sharedAs)
    }

    private func layer(_ id: String, digest: String? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "a", packageDigest: digest ?? "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: id, importedAt: when, sourceResolutionStatus: .resolved, isEnabled: true)
    }

    private func margin(_ id: String, layer: String, scoped: String? = nil) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: scoped ?? id, createdAt: when,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Listen.",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000, resolution: placed)
    }

    /// 11 own Margins, their 11 copies in the layer "mine" (digest-mine), and a friend's 3 in "ben".
    private struct Fixture {
        let ownMargins: [Interjection]
        let echoLayer: ImportedCommentaryLayer
        let benLayer: ImportedCommentaryLayer
        let copies: [ImportedCommentaryInterjection]
        let bens: [ImportedCommentaryInterjection]
    }

    private func fixture() -> Fixture {
        let ids = (1...11).map(identity)
        return Fixture(
            ownMargins: ids.enumerated().map { own("mine-\($0.offset)", sharedAs: [$0.element]) },
            echoLayer: layer("mine", digest: "digest-mine"),
            benLayer: layer("ben"),
            copies: ids.map { margin("copy-\($0.packageScopedId)", layer: "mine", scoped: $0.packageScopedId) },
            bens: (1...3).map { margin("ben-\($0)", layer: "ben") })
    }

    func testAMixedLayerKeepsOnlyTheFriendsMargins() {
        let f = fixture()
        let mixedLayer = f.echoLayer
        let result = OwnMarginEchoes.friendMargins(
            layers: [mixedLayer], records: ["mine": f.copies + f.bens.map { margin($0.id, layer: "mine") }], ownMargins: f.ownMargins)
        XCTAssertEqual(result.layers.map(\.id), ["mine"])
        XCTAssertEqual(result.records["mine"]?.count, 3)
    }

    func testAnEchoOnlyLayerIsDroppedWithItsKeyAndTheFriendsLayerStays() {
        let f = fixture()
        let result = OwnMarginEchoes.friendMargins(
            layers: [f.benLayer, f.echoLayer], records: ["ben": f.bens, "mine": f.copies], ownMargins: f.ownMargins)
        XCTAssertEqual(result.layers.map(\.id), ["ben"])
        XCTAssertEqual(Set(result.records.keys), ["ben"])
        XCTAssertEqual(result.records["ben"]?.count, 3)
    }

    func testALayerWithNoRecordsIsKeptAndNoOwnMarginsReturnsTheInputUnchanged() {
        let f = fixture()
        let map = layer("map")
        let kept = OwnMarginEchoes.friendMargins(layers: [map, f.echoLayer], records: ["mine": f.copies], ownMargins: f.ownMargins)
        XCTAssertEqual(kept.layers.map(\.id), ["map"], "a Listening Map layer has no Margins to be copies of")
        XCTAssertNil(kept.records["map"], "its key stays as it came in")

        let layers = [f.benLayer, f.echoLayer]
        let records = ["ben": f.bens, "mine": f.copies]
        let none = OwnMarginEchoes.friendMargins(layers: layers, records: records, ownMargins: [])
        XCTAssertEqual(none, OwnMarginEchoes.FriendMargins(layers: layers, records: records), "first-run: nothing to compare")
        let deleted = OwnMarginEchoes.friendMargins(
            layers: layers, records: records, ownMargins: f.ownMargins.map { var m = $0; m.status = "deleted"; return m })
        XCTAssertEqual(deleted.layers.count, 2, "a deleted own Margin leaves its copy reading as the sender's")
    }

    func testTheArrivalCountsLeaveTheListenersOwnCopiesOut() {
        let f = fixture()
        let mixed = f.copies + f.bens.map { margin($0.id, layer: "mine") }
        let ids = mixed.map(\.id)
        XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: ids, saved: mixed, layer: f.echoLayer, ownMargins: f.ownMargins), 3)
        XCTAssertNil(SharedPacketArrival.ownCopiesCount(importedIds: ids, saved: mixed, layer: f.echoLayer, ownMargins: f.ownMargins))
        XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: ids, saved: mixed, layer: f.echoLayer, ownMargins: []), 14)

        let copyIds = f.copies.map(\.id)
        XCTAssertEqual(SharedPacketArrival.ownCopiesCount(importedIds: copyIds, saved: f.copies, layer: f.echoLayer, ownMargins: f.ownMargins), 11)
        XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: copyIds, saved: f.copies, layer: f.echoLayer, ownMargins: f.ownMargins), 0)
        XCTAssertEqual(SharedPacketArrival.ownCopiesMessage(count: 11), "Nothing new: these are your own Margins")

        XCTAssertEqual(
            SharedPacketArrival.ownCopiesCount(importedIds: [copyIds[0]], saved: f.copies, layer: f.echoLayer, ownMargins: f.ownMargins), 1)
        XCTAssertEqual(SharedPacketArrival.ownCopiesMessage(count: 1), "Nothing new: this is your own Margin")
        XCTAssertNil(SharedPacketArrival.ownCopiesCount(importedIds: [], saved: f.copies, layer: f.echoLayer, ownMargins: f.ownMargins))
        XCTAssertNil(SharedPacketArrival.ownCopiesCount(importedIds: ["unknown"], saved: f.copies, layer: f.echoLayer, ownMargins: f.ownMargins))
    }

    func testACopyThatCannotPlayIsStillACopy() {
        let f = fixture()
        var silent = f.copies[0]
        silent.audioPath = nil
        XCTAssertEqual(
            SharedPacketArrival.ownCopiesCount(importedIds: [silent.id], saved: [silent], layer: f.echoLayer, ownMargins: f.ownMargins), 1)
    }

    func testHadFriendMarginsIgnoresACopyOnlyLayer() {
        let f = fixture()
        XCTAssertFalse(SharedPacketArrival.hadFriendMargins(layers: [f.echoLayer], records: ["mine": f.copies], ownMargins: f.ownMargins))
        XCTAssertTrue(SharedPacketArrival.hadFriendMargins(
            layers: [f.echoLayer, f.benLayer], records: ["mine": f.copies, "ben": f.bens], ownMargins: f.ownMargins))
        XCTAssertTrue(SharedPacketArrival.hadFriendMargins(layers: [layer("map")], records: [:], ownMargins: f.ownMargins))
    }

    func testTheLoaderGivesEverySessionsActiveOwnMarginsAndNotADeletedOne() throws {
        try withStore(sessions: ["s1", "s2"]) { store in
            try store.saveInterjection(own("one", session: "s1", sharedAs: nil))
            try store.saveInterjection(own("two", session: "s2", sharedAs: nil))
            try store.saveInterjection(own("gone", session: "s2", sharedAs: nil, status: "deleted"))
            let state = try ItemDetailLoader.load(id: "a", store: store, snapshotItemId: "a", snapshotSessionId: "s2")
            XCTAssertEqual(Set(state.itemOwnMargins.map(\.id)), ["one", "two"])
            XCTAssertEqual(state.interjections.map(\.id), ["two"], "the active session's list is unchanged")
        }
    }

    func testBeforeImportReadsTheOwnMarginsAndWhetherAFriendWasThere() throws {
        try withStore(sessions: ["s1", "s2"]) { store in
            let f = fixture()
            XCTAssertEqual(try PacketArrivalReading.beforeImport(itemId: "a", store: store).hadFriendMargins, false)
            for (index, m) in f.ownMargins.enumerated() { try store.saveInterjection(own(m.id, session: index.isMultiple(of: 2) ? "s1" : "s2", sharedAs: m.sharedAs)) }
            _ = try store.importCommentaryLayer(f.echoLayer, interjections: f.copies)

            var read = try PacketArrivalReading.beforeImport(itemId: "a", store: store)
            XCTAssertEqual(read.ownMargins.count, 11, "both sessions")
            XCTAssertFalse(read.hadFriendMargins, "only an echo layer")

            _ = try store.importCommentaryLayer(f.benLayer, interjections: f.bens)
            read = try PacketArrivalReading.beforeImport(itemId: "a", store: store)
            XCTAssertTrue(read.hadFriendMargins)
        }
    }

    func testBeforeImportCountsALayerWithNoRecords() throws {
        try withStore { store in
            _ = try store.importCommentaryLayer(layer("map"), interjections: [])
            XCTAssertTrue(try PacketArrivalReading.beforeImport(itemId: "a", store: store).hadFriendMargins)
        }
    }
}
