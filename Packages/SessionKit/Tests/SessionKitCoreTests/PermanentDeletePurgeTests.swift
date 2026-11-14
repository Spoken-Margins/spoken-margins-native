import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// #4227: a permanent delete finishes taking the item's files off the phone even when the app is killed or a removal
/// fails. Real temporary files and a real SQLite store; the only fake is the one removal call, in the failure tests.
final class PermanentDeletePurgeTests: XCTestCase {
    private var base: URL!
    private var prepared: URL { base.appending(path: "PreparedAudio", directoryHint: .isDirectory) }
    private var editions: URL { base.appending(path: "ListeningEditions", directoryHint: .isDirectory) }
    private var journal: URL { base.appending(path: "PurgeJournal", directoryHint: .isDirectory) }
    private let manager = FileManager.default

    override func setUpWithError() throws {
        base = manager.temporaryDirectory.appending(path: "purge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: prepared, withIntermediateDirectories: true)
        try manager.createDirectory(at: editions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? manager.removeItem(at: base) }

    private func purge(removeFile: (@Sendable (URL) throws -> Void)? = nil) -> PermanentDeletePurge {
        let roots = [
            PermanentDeletePurge.Root(name: ItemOwnedFiles.preparedAudioRoot, url: prepared),
            PermanentDeletePurge.Root(name: ItemOwnedFiles.listeningEditionsRoot, url: editions),
        ]
        if let removeFile { return PermanentDeletePurge(journalDirectory: journal, roots: roots, removeFile: removeFile) }
        return PermanentDeletePurge(journalDirectory: journal, roots: roots)
    }

    /// Seeds the files of `itemId` the way the writers lay them out.
    private func seedFiles(of itemId: String) throws {
        let chunks = prepared.appending(path: ItemOwnedFiles.preparedAudioDirectoryName(itemId: itemId) + "/digest/chunks")
        try manager.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Data("chunk".utf8).write(to: chunks.appending(path: "a-00000.wav"))
        try Data("edition".utf8).write(to: editions.appending(path: ItemOwnedFiles.listeningEditionFileName(itemId: itemId)))
    }

    private func filesExist(of itemId: String) -> (chunks: Bool, edition: Bool) {
        (manager.fileExists(atPath: prepared.appending(path: ItemOwnedFiles.preparedAudioDirectoryName(itemId: itemId)).path),
         manager.fileExists(atPath: editions.appending(path: ItemOwnedFiles.listeningEditionFileName(itemId: itemId)).path))
    }

    private func journalCount() -> Int {
        ((try? manager.contentsOfDirectory(atPath: journal.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    private var later: Date { Date().addingTimeInterval(60) }
    private let gone = "item-6f1c2d3e-0000-4000-8000-000000000001"
    private let kept = "item-6f1c2d3e-0000-4000-8000-000000000002"

    // MARK: The order of a delete

    func testADeleteRemovesTheItemsFilesAndOnlyThose() async throws {
        try seedFiles(of: gone); try seedFiles(of: kept)
        var deleted = false
        let task = try purge().deleting(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone)) { deleted = true }
        let outcome = await task.value
        XCTAssertTrue(deleted)
        XCTAssertEqual(outcome.removed.count, 2)
        XCTAssertTrue(outcome.kept.isEmpty)
        XCTAssertEqual(filesExist(of: gone).chunks, false)
        XCTAssertEqual(filesExist(of: gone).edition, false)
        XCTAssertEqual(filesExist(of: kept).chunks, true, "another item's chunks stay")
        XCTAssertEqual(filesExist(of: kept).edition, true, "another item's edition stays")
        XCTAssertEqual(journalCount(), 0, "the record goes when every file is gone")
    }

    func testTheRecordIsOnDiskBeforeTheDeleteRuns() throws {
        try seedFiles(of: gone)
        var recordsDuringDelete = -1
        let purge = purge()
        let task = try purge.deleting(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone)) {
            recordsDuringDelete = journalCount()
        }
        _ = task
        XCTAssertEqual(recordsDuringDelete, 1)
    }

    func testAFailedDeleteTouchesNoFileAndItsRecordIsDroppedAtLaunch() throws {
        try seedFiles(of: gone)
        struct DeleteFailed: Error {}
        XCTAssertThrowsError(try purge().deleting(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone)) {
            throw DeleteFailed()
        }) { XCTAssertTrue($0 is DeleteFailed) }
        XCTAssertEqual(filesExist(of: gone).chunks, true)
        XCTAssertEqual(filesExist(of: gone).edition, true)
        XCTAssertEqual(journalCount(), 1, "kept: the throw may have come after the commit")
        let launch = purge().resumePending(recordsBefore: Date().addingTimeInterval(1), rowState: { _ in .present })
        XCTAssertEqual(launch.abandonedRecords, 1)
        XCTAssertEqual(filesExist(of: gone).chunks, true)
        XCTAssertEqual(journalCount(), 0)
    }

    func testAJournalThatCannotBeWrittenDoesNotStopTheDelete() async throws {
        try seedFiles(of: gone)
        try Data("a file where the journal folder should be".utf8).write(to: journal)
        var deleted = false
        let outcome = await (try purge().deleting(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone)) {
            deleted = true
        }).value
        XCTAssertTrue(deleted, "the listener's delete goes ahead")
        XCTAssertEqual(outcome, PermanentDeletePurge.Outcome())
        XCTAssertEqual(filesExist(of: gone).chunks, true, "with no record the files stay, as before")
    }

    func testNothingToRemoveJustRunsTheDelete() async throws {
        var deleted = false
        let outcome = await (try purge().deleting(itemIds: [gone], targets: []) { deleted = true }).value
        XCTAssertTrue(deleted)
        XCTAssertEqual(outcome, PermanentDeletePurge.Outcome())
        XCTAssertEqual(journalCount(), 0)
    }

    // MARK: An interrupted delete, finished at the next launch

    func testAKilledDeleteIsFinishedAtTheNextLaunchOnceTheRowsAreGone() throws {
        try seedFiles(of: gone); try seedFiles(of: kept)
        // The app is killed after the rows went and before the files did: the record is all that is left.
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        XCTAssertEqual(filesExist(of: gone).chunks, true)

        let outcome = purge().resumePending(recordsBefore: later, rowState: { _ in .absent })
        XCTAssertEqual(outcome.removed.count, 2)
        XCTAssertEqual(filesExist(of: gone).chunks, false)
        XCTAssertEqual(filesExist(of: gone).edition, false)
        XCTAssertEqual(filesExist(of: kept).chunks, true)
        XCTAssertEqual(journalCount(), 0)
    }

    func testAKillBeforeTheRowsWentRemovesNothing() throws {
        try seedFiles(of: gone)
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        let outcome = purge().resumePending(recordsBefore: later, rowState: { $0 == self.gone ? .present : .absent })
        XCTAssertEqual(outcome.abandonedRecords, 1)
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(filesExist(of: gone).chunks, true, "the item still has its row, so its files stay")
        XCTAssertEqual(filesExist(of: gone).edition, true)
        XCTAssertEqual(journalCount(), 0, "the record is dropped; a later delete writes a new one")
    }

    func testAFailedRemovalStaysInTheRecordAndIsRetried() async throws {
        try seedFiles(of: gone)
        let editionName = ItemOwnedFiles.listeningEditionFileName(itemId: gone)
        let stuck = purge(removeFile: { url in
            if url.lastPathComponent == editionName {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        })
        let outcome = await (try stuck.deleting(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone)) {}).value
        XCTAssertEqual(outcome.removed.map(\.root), [ItemOwnedFiles.preparedAudioRoot], "only the chunks went")
        XCTAssertEqual(outcome.kept.map(\.root), [ItemOwnedFiles.listeningEditionsRoot])
        XCTAssertEqual(filesExist(of: gone).chunks, false)
        XCTAssertEqual(filesExist(of: gone).edition, true)
        XCTAssertEqual(journalCount(), 1, "the failure is not swallowed: it is recorded")

        // Next launch, nothing in the way.
        let retry = purge().resumePending(recordsBefore: later, rowState: { _ in .absent })
        XCTAssertEqual(retry.removed.map(\.root), [ItemOwnedFiles.listeningEditionsRoot])
        XCTAssertEqual(filesExist(of: gone).edition, false)
        XCTAssertEqual(journalCount(), 0)
    }

    func testARowThatCannotBeReadKeepsTheRecordForTheNextLaunch() throws {
        try seedFiles(of: gone)
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        let busy = purge().resumePending(recordsBefore: later, rowState: { _ in .unknown })
        XCTAssertEqual(busy.deferredRecords, 1)
        XCTAssertTrue(busy.removed.isEmpty)
        XCTAssertEqual(filesExist(of: gone).chunks, true)
        XCTAssertEqual(journalCount(), 1, "not dropped: a busy database must not orphan the files")
        let next = purge().resumePending(recordsBefore: later, rowState: { _ in .absent })
        XCTAssertEqual(next.removed.count, 2)
        XCTAssertEqual(journalCount(), 0)
    }

    func testARecordMadeAfterTheLaunchBeganIsLeftToItsOwnDelete() throws {
        try seedFiles(of: gone)
        let launchBegan = Date().addingTimeInterval(-1)
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        // This process's own delete wrote it, rows still present at the moment resume looks.
        let outcome = purge().resumePending(recordsBefore: launchBegan, rowState: { _ in .present })
        XCTAssertEqual(outcome, PermanentDeletePurge.Outcome())
        XCTAssertEqual(journalCount(), 1)
        XCTAssertEqual(filesExist(of: gone).chunks, true)
    }

    func testAFileAlreadyGoneCountsAsRemoved() throws {
        let record = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        let outcome = purge().finish(record)
        XCTAssertEqual(outcome.removed.count, 2)
        XCTAssertEqual(journalCount(), 0)
    }

    func testAnUnreadableRecordIsDroppedAndTheRestStillRun() throws {
        try seedFiles(of: gone)
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        try Data("not json".utf8).write(to: journal.appending(path: "broken.json"))
        let outcome = purge().resumePending(recordsBefore: later, rowState: { _ in .absent })
        XCTAssertEqual(outcome.unreadableRecords, 1)
        XCTAssertEqual(outcome.removed.count, 2)
        XCTAssertEqual(journalCount(), 0)
    }

    // MARK: Only what is inside the roots

    func testATargetThatLeavesItsRootIsRefusedAndKept() throws {
        let outside = base.appending(path: "outside.txt")
        try Data("mine".utf8).write(to: outside)
        let attempts: [PermanentDeletePurge.Target] = [
            .init(root: ItemOwnedFiles.preparedAudioRoot, relativePath: "../outside.txt"),
            .init(root: ItemOwnedFiles.preparedAudioRoot, relativePath: "a/../../outside.txt"),
            .init(root: ItemOwnedFiles.preparedAudioRoot, relativePath: outside.path),
            .init(root: ItemOwnedFiles.preparedAudioRoot, relativePath: ""),
            .init(root: ItemOwnedFiles.preparedAudioRoot, relativePath: "/"),
            .init(root: ItemOwnedFiles.preparedAudioRoot, relativePath: "."),
            .init(root: "NoSuchRoot", relativePath: "outside.txt"),
        ]
        let record = try purge().begin(itemIds: [gone], targets: attempts)
        let outcome = purge().finish(record)
        XCTAssertTrue(outcome.removed.isEmpty, "\(outcome.removed)")
        XCTAssertEqual(outcome.kept.count, attempts.count)
        XCTAssertTrue(manager.fileExists(atPath: outside.path))
        XCTAssertTrue(manager.fileExists(atPath: prepared.path), "the root itself stays")
    }

    func testALinkInsideARootNeverLeadsTheRemovalOutOfIt() throws {
        let elsewhere = base.appending(path: "elsewhere", directoryHint: .isDirectory)
        try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: elsewhere.appending(path: "keep.txt"))
        try manager.createSymbolicLink(at: prepared.appending(path: "link"), withDestinationURL: elsewhere)

        // A path through the link is refused.
        let through = PermanentDeletePurge.Target(root: ItemOwnedFiles.preparedAudioRoot, relativePath: "link/keep.txt")
        let refused = purge().finish(try purge().begin(itemIds: [gone], targets: [through]))
        XCTAssertEqual(refused.kept, [through])
        XCTAssertTrue(manager.fileExists(atPath: elsewhere.appending(path: "keep.txt").path))

        // The link itself goes; what it points at stays.
        let link = PermanentDeletePurge.Target(root: ItemOwnedFiles.preparedAudioRoot, relativePath: "link")
        let removed = purge().finish(try purge().begin(itemIds: [gone], targets: [link]))
        XCTAssertEqual(removed.removed, [link])
        XCTAssertFalse((try? manager.destinationOfSymbolicLink(atPath: prepared.appending(path: "link").path)) != nil)
        XCTAssertTrue(manager.fileExists(atPath: elsewhere.appending(path: "keep.txt").path))
    }

    // MARK: Against a real store

    func testAgainstARealStoreTheRowsDecideWhetherARecordIsFinished() throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        for id in [gone, kept] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        try seedFiles(of: gone); try seedFiles(of: kept)

        // Killed before the delete: the row is still there.
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        XCTAssertEqual(purge().resumePending(recordsBefore: later, store: store).abandonedRecords, 1)
        XCTAssertTrue(filesExist(of: gone).chunks)

        // Killed after it: the row is gone, the files go.
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        try store.deleteItem(id: gone)
        XCTAssertEqual(purge().resumePending(recordsBefore: later, store: store).removed.count, 2)
        XCTAssertFalse(filesExist(of: gone).chunks)
        XCTAssertTrue(filesExist(of: kept).chunks)
    }

    // MARK: Which files an item owns

    func testWhichFilesAnItemOwns() {
        let table: [(id: String, prepared: Bool, note: String)] = [
            ("item-6f1c2d3e-0000-4000-8000-000000000001", true, "an id the app makes"),
            ("epub-6F1C2D3E-0000-4000-8000-000000000001", true, "upper case"),
            ("a_b", true, "an underscore"),
            ("a b", true, "a space"),
            ("café", true, "non-ASCII"),
            ("", false, "empty: no folder name"),
            (String(repeating: "x", count: 81), true, "cut at 80"),
            (String(repeating: "x", count: 80), true, "exactly 80"),
            ("a/b", true, "a slash becomes a hyphen, so it stays one name"),
            ("..", true, "dots become hyphens"),
            ("a\u{0301}", true, "a combining mark"),
        ]
        for row in table {
            let targets = ItemOwnedFiles.targets(forItem: row.id)
            XCTAssertEqual(targets.contains { $0.root == ItemOwnedFiles.preparedAudioRoot }, row.prepared, row.note)
            XCTAssertEqual(targets.filter { $0.root == ItemOwnedFiles.listeningEditionsRoot }.count, 1, row.note)
            for target in targets {
                XCTAssertFalse(target.relativePath.contains("/"), "\(row.note): one name under its root")
                if target.root == ItemOwnedFiles.preparedAudioRoot {
                    XCTAssertFalse(target.relativePath.contains("."), "\(row.note): no dots, so no climbing")
                }
                XCTAssertFalse(target.relativePath.isEmpty, row.note)
                XCTAssertEqual(target.itemId, row.id, row.note)
            }
        }
    }

    func testItemsDeletedTogetherNameEachDistinctFolderOnce() {
        // a_b and a-b map to one folder name; A-B maps to another (they are one directory only on a case-insensitive
        // volume, where removing the second finds the folder already gone). On a case-sensitive volume every folder
        // is in the record, so none is left behind with no record to retry it.
        let targets = ItemOwnedFiles.targets(forItems: ["a_b", "a-b", "A-B"])
        XCTAssertEqual(
            targets.filter { $0.root == ItemOwnedFiles.preparedAudioRoot }.map(\.relativePath), ["a-b", "A-B"])
        XCTAssertEqual(targets.filter { $0.root == ItemOwnedFiles.listeningEditionsRoot }.count, 3)
    }

    /// The same ids on both kinds of volume: `A-1` going while `a-1` stays.
    func testCaseSensitiveVolumesKeepTwoCasesApart() {
        let target = ItemOwnedFiles.targets(forItem: "A-1").first { $0.root == ItemOwnedFiles.preparedAudioRoot }!
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { ["a-1"] }, caseSensitiveNames: true),
            .absent, "two different folders: A-1's own is free, so its chunks go")
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { ["a-1"] }, caseSensitiveNames: false),
            .present, "one folder: a-1 still uses it, so it stays")
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { ["A-1"] }, caseSensitiveNames: true),
            .present, "the same name is the same folder on either kind of volume")
    }

    func testAVolumeThatDoesNotSayItsCaseRuleIsTreatedAsCaseInsensitive() {
        XCTAssertFalse(ItemOwnedFiles.volumeIsCaseSensitive(at: base.appending(path: "no-such-folder")))
    }

    /// Just before a folder goes, is it still free? A table of the ids that map to the same folder, and ones that don't.
    func testWhichIdsKeepAPreparedAudioFolder() {
        let gone = "a_b"
        let target = ItemOwnedFiles.targets(forItem: gone).first { $0.root == ItemOwnedFiles.preparedAudioRoot }!
        let table: [(others: [String], free: Bool, note: String)] = [
            ([], true, "no other item"),
            (["other", "a-c", "a--b"], true, "neighbours that map elsewhere"),
            (["a-b"], false, "a-b shares the folder"),
            (["A-B"], false, "case: APFS is case-insensitive"),
            (["a b"], false, "a space"),
            (["a!b"], false, "punctuation"),
        ]
        for row in table {
            let state = ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { row.others })
            XCTAssertEqual(state, row.free ? .absent : .present, row.note)
        }
        let long = String(repeating: "x", count: 81)
        let longTarget = ItemOwnedFiles.targets(forItem: long).first { $0.root == ItemOwnedFiles.preparedAudioRoot }!
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(longTarget, rowState: { _ in .absent }, allItemIds: { [long + "y"] }), .present,
            "an 80-character cut shared with a longer id")
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .absent }, allItemIds: { throw CocoaError(.fileReadUnknown) }),
            .unknown, "ids that can't be read keep the folder for the next launch")
        XCTAssertEqual(
            ItemOwnedFiles.stillFree(target, rowState: { _ in .present }, allItemIds: { [] }), .present,
            "the item's own row came back")
    }

    func testADeleteWithTheStoresRecheckNeverTakesAnotherItemsSharedFolder() async throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        for id in ["a-b", "a_b", "other"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        XCTAssertEqual(Set(try store.loadAllItemIds()), ["a-b", "a_b", "other"])
        try seedFiles(of: "a-b")   // the folder a_b maps to as well
        let outcome = await (try purge().deleting(
            itemIds: ["a_b"], targets: ItemOwnedFiles.targets(forItem: "a_b"), recheck: purge().storeRecheck(store: store)
        ) { try store.deleteItem(id: "a_b") }).value
        XCTAssertEqual(outcome.removed.map(\.root), [ItemOwnedFiles.listeningEditionsRoot], "a_b's edition only")
        XCTAssertEqual(outcome.reappeared.map(\.root), [ItemOwnedFiles.preparedAudioRoot])
        XCTAssertTrue(filesExist(of: "a-b").chunks, "a-b's chunks live in the folder a_b also maps to")
        XCTAssertEqual(journalCount(), 0, "nothing is left to retry")
    }

    func testAnUnsharedFolderGoesWithTheStoresRecheck() async throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        for id in [gone, kept] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        try seedFiles(of: gone); try seedFiles(of: kept)
        let outcome = await (try purge().deleting(
            itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone), recheck: purge().storeRecheck(store: store)
        ) { try store.deleteItem(id: gone) }).value
        XCTAssertEqual(outcome.removed.count, 2)
        XCTAssertFalse(filesExist(of: gone).chunks)
        XCTAssertTrue(filesExist(of: kept).chunks)
    }

    // MARK: A resumed delete checks again just before each removal

    func testAnItemThatComesBackWhileARecordIsFinishedKeepsItsFiles() throws {
        try seedFiles(of: gone); try seedFiles(of: kept)
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        // Absent when the record is read; imported again (same id) before the first removal.
        var lookups = 0
        let outcome = purge().resumePending(recordsBefore: later, rowState: { _ in
            lookups += 1
            return lookups == 1 ? .absent : .present
        })
        XCTAssertEqual(outcome.reappeared.count, 2)
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(filesExist(of: gone).chunks, true, "the re-imported item's files stay")
        XCTAssertEqual(filesExist(of: gone).edition, true)
        XCTAssertEqual(journalCount(), 0, "nothing is left to retry")
    }

    func testAnItemWhoseRowCannotBeReadAtTheSecondLookKeepsItsTarget() throws {
        try seedFiles(of: gone)
        _ = try purge().begin(itemIds: [gone], targets: ItemOwnedFiles.targets(forItem: gone))
        var lookups = 0
        let outcome = purge().resumePending(recordsBefore: later, rowState: { _ in
            lookups += 1
            return lookups == 1 ? .absent : .unknown
        })
        XCTAssertEqual(outcome.kept.count, 2)
        XCTAssertEqual(filesExist(of: gone).chunks, true)
        XCTAssertEqual(journalCount(), 1, "tried again at the next launch")
    }

    func testAFolderAnotherIdMapsToIsKeptWhenThatIdIsImportedAfterTheDelete() throws {
        let path = base.appending(path: "store.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        for id in ["a_b", "other"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        try seedFiles(of: "a_b")                                   // the folder a-b maps to as well
        _ = try purge().begin(itemIds: ["a_b"], targets: ItemOwnedFiles.targets(forItem: "a_b"))
        try store.deleteItem(id: "a_b")                            // the delete went through; the app was killed
        // Before the launch finishes the record, a friend's packet brings in a-b.
        try store.saveItem(Item(id: "a-b", title: "a-b", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        let outcome = purge().resumePending(recordsBefore: later, store: store)
        XCTAssertEqual(outcome.removed.map(\.root), [ItemOwnedFiles.listeningEditionsRoot], "a_b's edition went")
        XCTAssertEqual(outcome.reappeared.map(\.root), [ItemOwnedFiles.preparedAudioRoot], "the shared folder stays")
        XCTAssertTrue(filesExist(of: "a_b").chunks)
        XCTAssertEqual(journalCount(), 0)
    }

    func testAQuarantinedItemStillOwnsItsFolderAndItsRow() throws {
        let path = base.appending(path: "store.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try StoreRawSQL.execute([
            "INSERT INTO quarantined_records(kind,id,payload,decode_error) VALUES('item','a-b','not json','bad')",
        ], at: path)
        XCTAssertEqual(try store.loadAllItemIds(), ["a-b"])
        XCTAssertTrue(try store.hasItemRow(id: "a-b"))
        XCTAssertFalse(try store.hasItemRow(id: "a_b"))
        let target = ItemOwnedFiles.targets(forItem: "a_b").first { $0.root == ItemOwnedFiles.preparedAudioRoot }!
        XCTAssertEqual(purge().storeRecheck(store: store)(target), .present, "a-b's folder is not free")
    }

    // MARK: The episode-map run's last step

    private func commitInputs(itemId: String) -> (
        job: EpisodeMapPreparationJob, spine: EditionFingerprintSpineArtifact, sketch: TranscriptPhraseSketchArtifact,
        proposal: PortableListeningMapProposalArtifact, projection: ResolvedListeningMapProjection
    ) {
        (EpisodeMapPreparationJob(id: "job-\(itemId)", itemId: itemId, policy: .explicit, stage: .commit),
         EditionFingerprintSpineArtifact(id: "spine-\(itemId)", itemId: itemId, landmarks: []),
         TranscriptPhraseSketchArtifact(id: "sketch-\(itemId)", itemId: itemId, saltBase64: "c2FsdA==", windows: []),
         PortableListeningMapProposalArtifact(
            id: "proposal-\(itemId)", createdAt: Date(timeIntervalSince1970: 1_000), generator: "test",
            scenes: [.init(id: "scene-1", order: 0, title: "Part one", summaryText: "Overview.",
                           summaryProvenance: .senderAuthored, eligibility: .eligible, eligibilityReason: nil,
                           startAnchor: .init(anchorType: .media, mediaTimeMs: 0),
                           endAnchor: .init(anchorType: .media, mediaTimeMs: 30_000))]),
         ResolvedListeningMapProjection(
            id: "projection-\(itemId)", itemId: itemId, proposalId: "proposal-\(itemId)", points: [], intervals: []))
    }

    func testTheRunsLastStepWritesNothingForAnItemThatIsGone() throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        let inputs = commitInputs(itemId: gone)
        // The item was permanently deleted while the run finished: no row for it exists.
        XCTAssertFalse(try store.commitEpisodeMapRun(
            itemId: gone, job: inputs.job, spine: inputs.spine, sketch: inputs.sketch,
            proposal: inputs.proposal, projection: inputs.projection))
        XCTAssertNil(try store.loadEpisodeMapPreparationJob(id: inputs.job.id))
        XCTAssertNil(try store.loadEditionFingerprintSpine(itemId: gone))
        XCTAssertNil(try store.loadTranscriptPhraseSketch(itemId: gone))
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: gone), [])
        XCTAssertNil(try store.loadResolvedListeningMapProjection(itemId: gone))
    }

    func testTheRunsLastStepCommitsForAnItemThatStays() throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        try store.saveItem(Item(id: kept, title: "x", mediaType: "audio", text: "", externalReference: nil, status: "ready"))
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "asset-1", itemId: kept, category: .fingerprintMap, relativePath: "EpisodeMaps/a.sig", byteCount: 1,
            isReproducible: true, protections: [.activeEpisodeMapPreparation]))
        let inputs = commitInputs(itemId: kept)
        XCTAssertTrue(try store.commitEpisodeMapRun(
            itemId: kept, job: inputs.job, spine: inputs.spine, sketch: inputs.sketch,
            proposal: inputs.proposal, projection: inputs.projection))
        XCTAssertNotNil(try store.loadEpisodeMapPreparationJob(id: inputs.job.id))
        XCTAssertNotNil(try store.loadEditionFingerprintSpine(itemId: kept))
        XCTAssertNotNil(try store.loadTranscriptPhraseSketch(itemId: kept))
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: kept).count, 1)
        XCTAssertNotNil(try store.loadResolvedListeningMapProjection(itemId: kept))
        XCTAssertEqual(try store.loadOwnedOfflineAssets(itemId: kept).first?.protections, [], "the run's protection is released")
        // Then the item is permanently deleted: the commit's rows go with it, and a late repeat writes nothing.
        try store.deleteItem(id: kept)
        XCTAssertNil(try store.loadEditionFingerprintSpine(itemId: kept))
        XCTAssertFalse(try store.commitEpisodeMapRun(
            itemId: kept, job: inputs.job, spine: inputs.spine, sketch: inputs.sketch,
            proposal: inputs.proposal, projection: inputs.projection))
        XCTAssertNil(try store.loadEditionFingerprintSpine(itemId: kept))
        XCTAssertNil(try store.loadEpisodeMapPreparationJob(id: inputs.job.id))
    }

    // MARK: A late episode-map job save

    func testALateJobSaveDoesNotBringBackADeletedItemsJobRow() throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        try store.saveItem(Item(id: gone, title: "x", mediaType: "audio", text: "", externalReference: nil, status: "ready"))
        let job = EpisodeMapPreparationJob(id: "job-1", itemId: gone, policy: .explicit)
        XCTAssertTrue(try store.saveEpisodeMapPreparationJobIfItemExists(job))
        try store.deleteItem(id: gone)
        XCTAssertNil(try store.loadEpisodeMapPreparationJob(id: "job-1"), "the delete took the job")
        // The run finishes or is cancelled after the delete and records where it stopped.
        XCTAssertFalse(try store.saveEpisodeMapPreparationJobIfItemExists(job))
        XCTAssertNil(try store.loadEpisodeMapPreparationJob(id: "job-1"), "nothing came back")
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(itemId: gone), [])
    }

    func testARecordWithNoItemOnATargetIsRemovedAsWritten() throws {
        // The shape of a record written before targets named their item.
        try seedFiles(of: gone)
        let target = PermanentDeletePurge.Target(
            root: ItemOwnedFiles.listeningEditionsRoot, relativePath: ItemOwnedFiles.listeningEditionFileName(itemId: gone))
        let json = #"{"root":"\#(target.root)","relativePath":"\#(target.relativePath)"}"#
        XCTAssertEqual(try JSONDecoder().decode(PermanentDeletePurge.Target.self, from: Data(json.utf8)), target)
        _ = try purge().begin(itemIds: [gone], targets: [target])
        var lookups = 0
        let outcome = purge().resumePending(recordsBefore: later, rowState: { _ in
            lookups += 1
            return lookups == 1 ? .absent : .present
        })
        XCTAssertEqual(outcome.removed, [target], "no item named, so nothing to check")
        XCTAssertEqual(filesExist(of: gone).edition, false)
    }

    func testTheWritersFolderRuleIsUnchanged() {
        // The rule `PreparedAudioCoordinator` used before it called `ItemOwnedFiles`.
        func old(_ value: String) -> String {
            String(value.map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(80))
        }
        for id in ["item-1", "a_b", "café", "x y z", String(repeating: "é", count: 90), "", "a/b", "日本語-1"] {
            XCTAssertEqual(ItemOwnedFiles.preparedAudioDirectoryName(itemId: id), old(id), id)
        }
        XCTAssertEqual(
            ItemOwnedFiles.listeningEditionFileName(itemId: "edition-abc"),
            ListeningEdition.digest("edition-abc") + ".json")
    }
}
