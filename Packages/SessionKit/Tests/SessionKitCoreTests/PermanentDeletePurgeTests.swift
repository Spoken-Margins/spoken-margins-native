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
        let table: [(id: String, others: [String], prepared: Bool, note: String)] = [
            ("item-6f1c2d3e-0000-4000-8000-000000000001", [], true, "an id the app makes"),
            ("epub-6F1C2D3E-0000-4000-8000-000000000001", [], true, "upper case"),
            ("a_b", [], true, "an underscore, alone in its folder"),
            ("a_b", ["a-b"], false, "an underscore shares a folder with a-b, which stays"),
            ("a-b", ["a_b"], false, "the same, the other way round"),
            ("a-b", ["a-c", "a--b"], true, "neighbours that map elsewhere"),
            ("a b", ["a-b"], false, "a space shares with a-b"),
            ("café", [], true, "non-ASCII, alone"),
            ("café!", ["café-"], false, "non-ASCII letters kept, punctuation shares"),
            ("", [], false, "empty"),
            (String(repeating: "x", count: 81), [], true, "cut at 80, alone"),
            (String(repeating: "x", count: 81), [String(repeating: "x", count: 82)], false, "cut at 80, shared"),
            (String(repeating: "x", count: 80), [String(repeating: "x", count: 80) + "y"], false, "80 shares with a longer one"),
            ("a/b", [], true, "a slash becomes a hyphen, so it stays one name"),
            ("..", [], true, "dots become hyphens"),
            ("a\u{0301}", [], true, "a combining mark"),
        ]
        for row in table {
            let targets = ItemOwnedFiles.targets(forItem: row.id, otherItemIds: row.others)
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

    func testItemsDeletedTogetherDoNotBlockEachOthersFolders() {
        // a_b and a-b share a folder and both go: the folder is named once. A third item that maps there keeps it.
        let both = ItemOwnedFiles.targets(forItems: ["a_b", "a-b"], existingItemIds: ["a_b", "a-b", "z"])
        XCTAssertEqual(both.filter { $0.root == ItemOwnedFiles.preparedAudioRoot }.map(\.relativePath), ["a-b"])
        let blocked = ItemOwnedFiles.targets(forItems: ["a_b", "a-b"], existingItemIds: ["a_b", "a-b", "a b"])
        XCTAssertTrue(blocked.filter { $0.root == ItemOwnedFiles.preparedAudioRoot }.isEmpty)
        let unread = ItemOwnedFiles.targets(forItems: ["item-1"], existingItemIds: [], namingPreparedAudio: false)
        XCTAssertEqual(unread.map(\.root), [ItemOwnedFiles.listeningEditionsRoot], "ids that couldn't be read: the edition only")
    }

    func testAPurgeNeverTakesAnotherItemsSharedFolder() async throws {
        let store = try SQLiteSessionStore(path: base.appending(path: "store.sqlite").path)
        for id in ["a-b", "a_b", "other"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        XCTAssertEqual(Set(try store.loadAllItemIds()), ["a-b", "a_b", "other"])
        try seedFiles(of: "a-b")   // the folder a_b maps to as well
        let targets = ItemOwnedFiles.targets(forItems: ["a_b"], existingItemIds: try store.loadAllItemIds())
        let outcome = await (try purge().deleting(itemIds: ["a_b"], targets: targets) { try store.deleteItem(id: "a_b") }).value
        XCTAssertEqual(outcome.removed.map(\.root), [ItemOwnedFiles.listeningEditionsRoot], "a_b's edition only")
        XCTAssertTrue(filesExist(of: "a-b").chunks, "a-b's chunks live in the folder a_b also maps to")
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

    func testARecordWithNoItemOnATargetIsRemovedAsWritten() throws {
        // The shape of a record written before targets named their item.
        try seedFiles(of: gone)
        let target = PermanentDeletePurge.Target(
            root: ItemOwnedFiles.listeningEditionsRoot, relativePath: ItemOwnedFiles.listeningEditionFileName(itemId: gone))
        let json = #"{"root":"\#(target.root)","relativePath":"\#(target.relativePath)"}"#
        XCTAssertEqual(try JSONDecoder().decode(PermanentDeletePurge.Target.self, from: Data(json.utf8)), target)
        let record = try purge().begin(itemIds: [gone], targets: [target])
        let outcome = purge().finish(record, recheck: { _ in .present })
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
