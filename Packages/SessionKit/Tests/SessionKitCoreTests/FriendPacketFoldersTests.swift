import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #3406: permanent delete removes a friend's imported packet folder at once, on real folders and a real SQLite
/// Library. Only the folders the deleted items' own imported rows named go, and only after the rows are gone.
final class FriendPacketFoldersTests: XCTestCase {
    private var root: URL!
    private var incoming: URL!
    private var databasePath: String!
    private var store: SQLiteSessionStore!
    private let date = Date(timeIntervalSince1970: 1_777_000_000)
    private let identity = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/episodes/harbour-lights", title: "Harbour Lights")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("friend-folders-\(UUID().uuidString)", isDirectory: true)
        incoming = root.appendingPathComponent("SpokenMargins/IncomingPackages", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        databasePath = root.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: databasePath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheFriendsFolderIsGoneAfterPermanentDelete() async throws {
        let folder = try importFriend(onItem: "a")

        let removal = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "a")
        }
        let outcome = await removal.value

        XCTAssertEqual(outcome.removed, [folder])
        XCTAssertEqual(try folderNames(), [], "the audio and the kept packet are both gone")
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "a").count, 0)
    }

    func testTrashThenUndoKeepsTheFolderAndTheRecordingStillResolves() throws {
        try store.saveItem(Item(id: "a", title: "Harbour Lights", mediaType: "text", text: "Words.", externalReference: nil, status: "ready"))
        let folder = try importFriend(onItem: "a")

        try store.moveItemToTrash(id: "a")
        // A launch sweep while the item sits in Recently Deleted: its rows still name the folder.
        IncomingPackageSweep.sweep(directory: incoming, keeping: [], store: store)
        try store.restoreItem(id: "a")

        XCTAssertEqual(try folderNames(), [folder])
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayers(itemId: "a").first)
        let margin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(margin.audioPath)),
                      "the row's audioPath still names a file that exists; actually playing it is not proved on the host")
    }

    func testAnotherItemsFolderStays() async throws {
        let mine = try importFriend(onItem: "a")
        let other = try importFriend(onItem: "b")

        let removal = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "a")
        }
        let outcome = await removal.value

        XCTAssertEqual(outcome.removed, [mine])
        XCTAssertEqual(try folderNames(), [other])
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "b").count, 1)
    }

    /// Two packets are two folders and one packet is one layer, so this does not arise from an import (the
    /// coordinator stages every packet into a fresh UUID folder and a repeat of a packet's digest opens the first
    /// import's item). If a Library ever did hold two items on one folder, it stays until the last one goes.
    func testAFolderTwoItemsNameStaysUntilTheLastOneGoes() async throws {
        let shared = try importFriend(onItem: "a")
        try saveLayer(id: "layer-b", itemId: "b", digest: "digest-b", folder: shared, margin: "margin-b")

        let first = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "a")
        }
        let afterFirst = await first.value
        XCTAssertEqual(afterFirst.removed, [])
        XCTAssertEqual(afterFirst.kept, [shared])
        XCTAssertEqual(try folderNames(), [shared], "item b's Margin still plays from it")

        let last = try FriendPacketFolders.deleting(itemIds: ["b"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "b")
        }
        let afterLast = await last.value
        XCTAssertEqual(afterLast.removed, [shared])
        XCTAssertEqual(try folderNames(), [])
    }

    func testBulkDeleteRemovesEachDeletedItemsFolderAndNoOther() async throws {
        let first = try importFriend(onItem: "a")
        let second = try importFriend(onItem: "b")
        let kept = try importFriend(onItem: "c")

        let removal = try FriendPacketFolders.deleting(itemIds: ["a", "b"], store: store, directory: incoming, keeping: []) {
            try store.deleteItems(ids: ["a", "b"])
        }
        let outcome = await removal.value

        XCTAssertEqual(Set(outcome.removed), [first, second])
        XCTAssertEqual(try folderNames(), [kept])
    }

    func testAFailedRowDeleteLeavesTheFilesAndTheRows() async throws {
        let folder = try importFriend(onItem: "a")
        try StoreRawSQL.execute("""
            CREATE TRIGGER refuse_delete BEFORE DELETE ON records
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """, at: databasePath)

        XCTAssertThrowsError(
            try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
                try store.deleteItem(id: "a")
            })

        XCTAssertEqual(try folderNames(), [folder], "no row is left pointing at nothing")
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "a").count, 1)
    }

    func testAnImportInProgressSurvives() async throws {
        let mine = try importFriend(onItem: "a")
        let staging = try stagedFolder(files: ["package.spokenmargins"]) // extracted, no row names it yet
        let alsoInFlight = try stagedFolder(files: ["package.spokenmargins"])

        let removal = try FriendPacketFolders.deleting(
            itemIds: ["a"], store: store, directory: incoming, keeping: [alsoInFlight]
        ) { try store.deleteItem(id: "a") }
        let outcome = await removal.value

        XCTAssertEqual(outcome.removed, [mine])
        XCTAssertEqual(try folderNames(), [staging, alsoInFlight].sorted(), "a folder no row of this item names is never a candidate")
    }

    func testAFolderThatAnImportInProgressOwnsStaysEvenIfTheItemNamesIt() async throws {
        let folder = try importFriend(onItem: "a")

        let removal = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: [folder]) {
            try store.deleteItem(id: "a")
        }
        let outcome = await removal.value

        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(try folderNames(), [folder])
    }

    func testListenersOwnRecordingsAndOtherDirectoriesAreNeverTouched() async throws {
        _ = try importFriend(onItem: "a")
        let ownRecordings = root.appendingPathComponent("SpokenMargins/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: ownRecordings, withIntermediateDirectories: true)
        let ownVoice = ownRecordings.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("mine".utf8).write(to: ownVoice)

        let removal = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "a")
        }
        await removal.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: ownVoice.path))
    }

    func testAQuarantinedFriendMarginsFolderGoesWithItsItem() async throws {
        let folder = try stagedFolder(files: ["assets/voice.m4a"])
        try saveLayer(id: "layer-a", itemId: "a", digest: "digest-a", folder: nil, margin: nil)
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            VALUES ('imported_commentary_interjection', 'held', ?, 'newer build', '2026-02-03 04:05:06');
            """, bindings: ["{\"layerId\":\"layer-a\",\"audioPath\":\"\(incoming.path)/\(folder)/assets/voice.m4a\"}"], at: databasePath)

        let removal = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "a")
        }
        await removal.value

        XCTAssertEqual(try folderNames(), [])
    }

    func testNothingHappensForAnItemWithNoFriendRecordings() async throws {
        let other = try importFriend(onItem: "b")

        let removal = try FriendPacketFolders.deleting(itemIds: ["a"], store: store, directory: incoming, keeping: []) {
            try store.deleteItem(id: "a")
        }
        let outcome = await removal.value

        XCTAssertEqual(outcome, IncomingPackageSweep.Outcome())
        XCTAssertEqual(try folderNames(), [other])
    }

    // MARK: Fixtures

    /// A friend's packet imported onto `itemId`: the folder, one layer and one Margin that plays from the folder.
    private func importFriend(onItem itemId: String) throws -> String {
        let folder = try stagedFolder(files: ["package.spokenmargins", "assets/voice.m4a"])
        try saveLayer(id: "layer-\(itemId)", itemId: itemId, digest: "digest-\(itemId)", folder: folder, margin: "margin-\(itemId)")
        return folder
    }

    private func saveLayer(id: String, itemId: String, digest: String, folder: String?, margin: String?) throws {
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: id, itemId: itemId, packageDigest: digest, packageId: "packet-\(id)",
            itemIdentity: identity, displayLabel: "Friend", importedAt: date,
            sourceResolutionStatus: .contextOnly, isEnabled: true, isMuted: false))
        guard let folder, let margin else { return }
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: margin, layerId: id, packageScopedId: "\(margin)-001", createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
            approvedTranscript: "Keep this thought",
            audioPath: incoming.appendingPathComponent("\(folder)/assets/voice.m4a").path, audioDurationMs: 500,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 9_000)))
    }

    private func stagedFolder(files: [String]) throws -> String {
        let name = UUID().uuidString
        for file in files {
            let url = incoming.appendingPathComponent("\(name)/\(file)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: url)
        }
        return name
    }

    private func folderNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: incoming.path).sorted()
    }
}
