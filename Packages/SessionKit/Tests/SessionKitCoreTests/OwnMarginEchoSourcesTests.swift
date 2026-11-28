import Foundation
import SQLite3
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4910: a copy of the listener's own Margin that came back in a packet showed and played as a friend's on the Margins
/// tab, in the automatic prompts, in the friend-listen state and in the arrival banner. The two in-memory sources (the
/// Margins tab's rows and the item's layers) and the banner now leave copies out with `OwnMarginEchoes`. Real temporary
/// SQLite throughout: 11 own Margins shared under digest-mine, their 11 copies imported back as the layer "mine", and
/// Ben's 3 in the layer "ben".
final class OwnMarginEchoSourcesTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_700_000_000)
    private let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 5_000, confidence: 1)

    private func withStore(_ body: (SQLiteSessionStore, String) throws -> Void) throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "own-echo-sources-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "a", title: "A", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
        for (id, minutes) in [("s1", 0.0), ("s2", 1.0)] {
            let at = when.addingTimeInterval(minutes * 60)
            try store.saveSession(Session(
                id: id, itemId: "a", createdAt: at, updatedAt: at, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: "a", position: Position(), completionPercent: 0, playbackRate: 1))
        }
        try body(store, path)
    }

    private func identity(_ n: Int) -> MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: "digest-mine", packageScopedId: "margin-\(String(format: "%04d", n))")
    }

    private func own(_ id: String, session: String = "s1", sharedAs: [MarginPacketIdentity]?) -> Interjection {
        Interjection(
            id: id, itemId: "a", sessionId: session, targetType: .item, targetId: "a", createdAt: when, roughPercent: 0,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 754_000),
            audioPath: "\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: "active", sharedAs: sharedAs)
    }

    private func layer(_ id: String, digest: String? = nil, label: String? = nil) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "a", packageDigest: digest ?? "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label ?? id, importedAt: when, sourceResolutionStatus: .resolved, isEnabled: true)
    }

    private func margin(
        _ id: String, layer: String, scoped: String? = nil, also: [MarginPacketIdentity]? = nil, replyTo: MarginPacketIdentity? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: scoped ?? id, createdAt: when,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Listen.",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000, resolution: placed,
            replyLinks: replyTo.map {
                [MarginReplyLink(conversationId: "c", parentPackageDigest: $0.packageDigest, parentPackageScopedId: $0.packageScopedId)]
            },
            alsoSharedAs: also)
    }

    private var copies: [ImportedCommentaryInterjection] {
        (1...11).map { margin("back-\($0)", layer: "mine", scoped: identity($0).packageScopedId) }
    }

    /// The own Margins (split over two sessions) and their copies; Ben's 3 only when `withBen`.
    private func seed(_ store: SQLiteSessionStore, withBen: Bool = true) throws {
        for n in 1...11 { try store.saveInterjection(own("mine-\(n)", session: n.isMultiple(of: 2) ? "s2" : "s1", sharedAs: [identity(n)])) }
        _ = try store.importCommentaryLayer(layer("mine", digest: "digest-mine", label: "Cole"), interjections: copies)
        if withBen {
            _ = try store.importCommentaryLayer(layer("ben", label: "Ben"), interjections: (1...3).map { margin("ben-\($0)", layer: "ben") })
        }
    }

    private func load(_ store: SQLiteSessionStore, session: String = "s2") throws -> ItemDetailState {
        try ItemDetailLoader.load(
            id: "a", store: store, snapshotItemId: "a", snapshotSessionId: session, placementPasses: SharedMarginPlacementPasses())
    }

    // Test 1, the Margins tab: Ben's 3 under Shared and the listener's 11 under Mine, nothing twice.
    func testTheMarginsTabSharesOnlyTheFriendsMarginsAndKeepsTheListenersOwnRows() throws {
        try withStore { store, _ in
            try seed(store)
            for (name, entries) in [("item", try MarginRowsReading.item("a", store: store)), ("all", try MarginRowsReading.all(store: store))] {
                XCTAssertEqual(Set(entries.sharedRows.map(\.interjection.id)), ["ben-1", "ben-2", "ben-3"], name)
                XCTAssertEqual(entries.privateRows.count, 11, "\(name): the listener's own rows stay")
            }
        }
    }

    // Test 2, the automatic prompts (and through them Skim, the pinned card and the Live Activity): only Ben's play.
    func testTheItemsLayersAndTheAutomaticPromptsHoldOnlyTheFriendsMargins() throws {
        try withStore { store, _ in
            try seed(store)
            let state = try load(store)
            XCTAssertEqual(state.importedCommentaryLayers.map(\.id), ["ben"], "the echo layer is gone")
            XCTAssertEqual(state.importedCommentaryInterjections.values.flatMap { $0 }.count, 3)
            XCTAssertNil(state.importedCommentaryInterjections["mine"])
            let prompts = SharedMarginPrompts.prompts(
                layers: state.importedCommentaryLayers, recordsByLayerID: state.importedCommentaryInterjections,
                announcedIDs: [], includeAnnounced: true, durationMs: state.mediaDurationMs)
            XCTAssertEqual(prompts.map(\.interjection.id).sorted(), ["ben-1", "ben-2", "ben-3"])
        }
    }

    // Test 3, the friend-listen state reads the loaded layers with no own Margins, as `friendListenState` calls it.
    func testTheFriendListenStateCountsOnlyTheFriendsMargins() throws {
        try withStore { store, _ in
            try seed(store)
            let state = try load(store)
            let entries = SharedMarginReview.entriesInMemory(
                layers: state.importedCommentaryLayers, records: state.importedCommentaryInterjections, durationMs: state.mediaDurationMs)
            XCTAssertEqual(entries.count, 3)
        }
    }

    // Test 4, an item whose only packet was the listener's own: no friend to hear first, nobody else reacted.
    func testAnEchoOnlyItemOffersNoFriendMarginsAndNoReactions() throws {
        try withStore { store, _ in
            try seed(store, withBen: false)
            let state = try load(store)
            XCTAssertTrue(SharedMarginReview.entriesInMemory(
                layers: state.importedCommentaryLayers, records: state.importedCommentaryInterjections).isEmpty)
            XCTAssertFalse(MarginLayerSynthesis.offersReactions(
                itemId: "a", layers: state.importedCommentaryLayers, interjections: state.importedCommentaryInterjections,
                ownMargins: state.itemOwnMargins))
            XCTAssertEqual(state.itemOwnMargins.count, 11, "the listener's own Margins are all still theirs")
        }
    }

    // Test 5: Ben's packet also carries the listener's Margin 1 (alsoSharedAs) and his reply to it. The copy goes; the
    // reply still threads under the listener's own Margin, which is in an earlier session than the one open.
    func testAReplyStillThreadsUnderTheListenersOwnMarginWhenItsCopyIsLeftOut() throws {
        try withStore { store, _ in
            try store.saveInterjection(own("mine-1", session: "s1", sharedAs: [identity(1)]))
            _ = try store.importCommentaryLayer(layer("ben", label: "Ben"), interjections: [
                margin("ben-copy", layer: "ben", scoped: "x-1", also: [identity(1)]),
                margin("ben-reply", layer: "ben", replyTo: identity(1)),
            ])
            XCTAssertEqual(try MarginRowsReading.item("a", store: store).sharedRows.map(\.interjection.id), ["ben-reply"])

            let state = try load(store, session: "s2")
            XCTAssertEqual(state.interjections.map(\.id), [], "the open session is s2")
            let imported = state.importedCommentaryLayers.flatMap { state.importedCommentaryInterjections[$0.id, default: []] }
            XCTAssertEqual(imported.map(\.id), ["ben-reply"])
            let graph = MarginReplyGraph.build(localMargins: state.itemOwnMargins, layers: state.importedCommentaryLayers, importedMargins: imported)
            guard case .linked(let parent) = graph.states[.imported("ben-reply")] else { return XCTFail("the reply is linked") }
            XCTAssertEqual(parent.parent, .local("s1::mine-1"), "a local Margin is keyed by session and id")

            // What the Timeline rail now passes (`itemOwnMargins`) links the reply; the open session's alone would not.
            let rows = MarginThreadPresentation.rows(
                itemId: "a", localMargins: state.itemOwnMargins, layers: state.importedCommentaryLayers, importedMargins: imported)
            let reply = try XCTUnwrap(rows.first { $0.reference == .imported("ben-reply") })
            XCTAssertNotEqual(reply.note, MarginThreadPresentation.missingParentNote)
            XCTAssertEqual(reply.depth, 1)
            let sessionOnly = MarginThreadPresentation.rows(
                itemId: "a", localMargins: state.interjections, layers: state.importedCommentaryLayers, importedMargins: imported)
            XCTAssertEqual(sessionOnly.first { $0.reference == .imported("ben-reply") }?.note, MarginThreadPresentation.missingParentNote)
        }
    }

    // Test 6, relaunch: the rule is worked out from stored data alone.
    func testASecondStoreOverTheSameFileGivesTheSameCounts() throws {
        try withStore { store, path in
            try seed(store)
            let again = try SQLiteSessionStore(path: path)
            XCTAssertEqual(try MarginRowsReading.item("a", store: again).sharedRows.count, 3)
            XCTAssertEqual(try load(again).importedCommentaryInterjections.values.flatMap { $0 }.count, 3)
        }
    }

    // Test 7, a guard: the reads rewrite nothing. The copies stay stored exactly as imported, so the previous build opens
    // the same records.
    func testTheReadsLeaveEveryImportedRecordAsItWas() throws {
        try withStore { store, path in
            try seed(store)
            func importedRows() -> [String: String] {
                var db: OpaquePointer?
                guard sqlite3_open(path, &db) == SQLITE_OK else { return [:] }
                defer { sqlite3_close(db) }
                var statement: OpaquePointer?
                let sql = "SELECT id, payload FROM records WHERE kind IN ('imported_commentary_layer', 'imported_commentary_interjection')"
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
                defer { sqlite3_finalize(statement) }
                var rows: [String: String] = [:]
                while sqlite3_step(statement) == SQLITE_ROW {
                    rows[String(cString: sqlite3_column_text(statement, 0))] = String(cString: sqlite3_column_text(statement, 1))
                }
                return rows
            }
            let before = importedRows()
            XCTAssertEqual(before.count, 2 + 14, "two layers and all 14 imported Margins")
            _ = try MarginRowsReading.all(store: store)
            let state = try load(store)
            _ = SharedMarginReview.entriesInMemory(layers: state.importedCommentaryLayers, records: state.importedCommentaryInterjections)
            XCTAssertEqual(importedRows(), before)
        }
    }

    // Test 9, the issue's count: Ben's second packet of 3 onto an item holding his first layer and the echo layer.
    func testBensSecondPacketSaysThreeNewMarginsFromBen() throws {
        try withStore { store, _ in
            try seed(store, withBen: false)
            _ = try store.importCommentaryLayer(layer("ben", label: "Ben"), interjections: (1...2).map { margin("ben-\($0)", layer: "ben") })
            let before = try PacketArrivalReading.beforeImport(itemId: "a", store: store)
            XCTAssertTrue(before.hadFriendMargins)
            let second = layer("ben2", label: "Ben")
            let added = (1...3).map { margin("ben2-\($0)", layer: "ben2") }
            _ = try store.importCommentaryLayer(second, interjections: added)
            let count = SharedPacketArrival.newMarginCount(
                importedIds: added.map(\.id), saved: try store.loadImportedCommentaryInterjections(layerId: "ben2"),
                layer: second, ownMargins: before.ownMargins)
            XCTAssertEqual(count, 3)
            XCTAssertEqual(
                SharedPacketArrival.announcement(newMarginCount: count, senderName: "Ben", itemHadFriendMargins: before.hadFriendMargins),
                "3 new Margins from Ben")
        }
        // The unknown route (#4697): one layer of 11 copies and 3 new Margins counts the 3, not 14.
        try withStore { store, _ in
            for n in 1...11 { try store.saveInterjection(own("mine-\(n)", sharedAs: [identity(n)])) }
            let mixed = layer("mixed", label: "Ben")
            let added = (1...11).map { margin("echo-\($0)", layer: "mixed", scoped: "x-\($0)", also: [identity($0)]) }
                + (1...3).map { margin("ben-\($0)", layer: "mixed") }
            let before = try PacketArrivalReading.beforeImport(itemId: "a", store: store)
            _ = try store.importCommentaryLayer(mixed, interjections: added)
            let saved = try store.loadImportedCommentaryInterjections(layerId: "mixed")
            XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: added.map(\.id), saved: saved, layer: mixed, ownMargins: before.ownMargins), 3)
            XCTAssertNil(SharedPacketArrival.ownCopiesCount(importedIds: added.map(\.id), saved: saved, layer: mixed, ownMargins: before.ownMargins))
        }
    }

    // The line the import says, for every row of the Design's banner table. The own-copies line wins on every route.
    func testTheImportSaysNothingNewForTheListenersOwnFileOnEveryRoute() {
        func line(own: Int?, waits: Bool = false, direct: Bool = true, new: Int = 0, had: Bool = false) -> String? {
            SharedPacketArrival.confirmation(
                ownCopiesCount: own, openingWaits: waits, opensDirectly: direct, newMarginCount: new, itemHadFriendMargins: had,
                senderName: "Ben")
        }
        let nothingNew = "Nothing new: these are your own Margins"
        for (waits, direct, had) in [(false, true, true), (false, true, false), (true, true, true), (false, false, false)] {
            XCTAssertEqual(line(own: 11, waits: waits, direct: direct, had: had), nothingNew, "waits \(waits), direct \(direct), had \(had)")
        }
        XCTAssertEqual(line(own: 1), "Nothing new: this is your own Margin")
        XCTAssertEqual(line(own: nil, new: 3, had: true), "3 new Margins from Ben", "Ben's packet next to his earlier layer")
        XCTAssertNil(line(own: nil, new: 3, had: false), "a first arrival: the item screen's intro says it")
        XCTAssertNil(line(own: nil, new: 0, had: true), "nothing new from Ben, as before")
        XCTAssertEqual(line(own: nil, waits: true, new: 3, had: true), SharedPacketArrival.waitingToOpenMessage(senderName: "Ben"))
        XCTAssertEqual(line(own: nil, direct: false, new: 3, had: true), SharedPacketArrival.importedWithoutPlaybackMessage)
    }

    // Test 10, the listener's own packet re-imported: "Nothing new", never "11 new Margins from <the listener>".
    func testTheListenersOwnPacketSaysNothingNewWithOrWithoutAFriendThere() throws {
        for withBen in [true, false] {
            try withStore { store, _ in
                for n in 1...11 { try store.saveInterjection(own("mine-\(n)", sharedAs: [identity(n)])) }
                if withBen {
                    _ = try store.importCommentaryLayer(layer("ben", label: "Ben"), interjections: (1...3).map { margin("ben-\($0)", layer: "ben") })
                }
                let before = try PacketArrivalReading.beforeImport(itemId: "a", store: store)
                XCTAssertEqual(before.hadFriendMargins, withBen)
                let echo = layer("mine", digest: "digest-mine", label: "Cole")
                _ = try store.importCommentaryLayer(echo, interjections: copies)
                let saved = try store.loadImportedCommentaryInterjections(layerId: "mine")
                let ids = copies.map(\.id)
                let ownCount = SharedPacketArrival.ownCopiesCount(importedIds: ids, saved: saved, layer: echo, ownMargins: before.ownMargins)
                XCTAssertEqual(ownCount, 11, "with Ben: \(withBen)")
                XCTAssertEqual(ownCount.map(SharedPacketArrival.ownCopiesMessage(count:)), "Nothing new: these are your own Margins")
                XCTAssertEqual(SharedPacketArrival.newMarginCount(importedIds: ids, saved: saved, layer: echo, ownMargins: before.ownMargins), 0)

                // Ben's first real packet after that: the echo layer is not a friend's, so this is a first arrival.
                if !withBen {
                    XCTAssertFalse(try PacketArrivalReading.beforeImport(itemId: "a", store: store).hadFriendMargins)
                }
            }
        }
    }
}
