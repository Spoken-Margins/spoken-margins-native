import Foundation
import XCTest
@testable import SessionKit

/// #3770 Design PR 4 (amended by #4274 section 3b item 11): the list of Quick Folders, its upgrade from the single keys, the
/// launch reconcile after an older build changed those keys, the mirror back into them, removing with retired dismissals, the
/// five-folder limit and the duplicate path.
final class QuickFolderListTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_700_100_000)
    private let clippings = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Clippings"
    private let work = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Work/Clippings"

    private func ids(_ names: String...) -> () -> String {
        var queue = names
        return { queue.removeFirst() }
    }

    private func bookmark(_ text: String) -> Data { Data(text.utf8) }

    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "QuickFolderListTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func listWith(_ paths: [String]) -> QuickFolderList {
        var list = QuickFolderList()
        for (index, path) in paths.enumerated() {
            XCTAssertEqual(list.add(id: "f\(index + 1)", bookmark: bookmark(path), name: (path as NSString).lastPathComponent, path: path, now: t0), .added("f\(index + 1)"))
        }
        return list
    }

    // MARK: Upgrade

    func testAnUpgradeBuildsEntryOneFromTheSingleKeys() {
        let legacy = QuickFolderList.LegacyKeys(
            bookmark: bookmark("b1"), name: "Clippings", path: clippings, lastCheckedAt: t0, problem: .cantOpen,
            dismissedKeys: ["a.md|1", "b.pdf|2"], chosenAt: t0
        )
        let list = QuickFolderList.reconciled(stored: nil, legacy: legacy, now: later, newID: ids("f1"))
        XCTAssertEqual(list.folders, [QuickFolderList.Entry(
            id: "f1", bookmark: bookmark("b1"), name: "Clippings", path: clippings, chosenAt: t0, lastCheckedAt: t0, problem: .cantOpen,
            dismissedKeys: ["a.md|1", "b.pdf|2"]
        )])
    }

    func testAnUpgradeFromABuildWithNoPathOrChosenDateFloorsAtNow() {
        let legacy = QuickFolderList.LegacyKeys(bookmark: bookmark("b1"), name: "Clippings")
        let list = QuickFolderList.reconciled(stored: nil, legacy: legacy, now: later, newID: ids("f1"))
        XCTAssertNil(list.folders.first?.path)
        XCTAssertEqual(list.folders.first?.chosenAt, later, "a long-lived folder's old files must not come back as new")
        XCTAssertEqual(list.entriesMissingPath, ["f1"])
    }

    func testNoFolderChosenGivesAnEmptyList() {
        let list = QuickFolderList.reconciled(stored: nil, legacy: .init(dismissedKeys: ["a.md|1"]), now: t0, newID: ids())
        XCTAssertTrue(list.folders.isEmpty)
        XCTAssertEqual(list.mirror(keepingDismissed: ["a.md|1"]).dismissedKeys, ["a.md|1"], "removing the one folder always kept them")
    }

    // MARK: Mirror

    func testEntryOneWritesTheSingleKeysAndTheOthersDoNot() {
        var list = listWith([clippings, work])
        list.update("f1") { $0.dismissedKeys = ["a.md|1"]; $0.lastCheckedAt = later }
        list.update("f2") { $0.dismissedKeys = ["z.md|9"] }
        let mirror = list.mirror(keepingDismissed: [])
        XCTAssertEqual(mirror, QuickFolderList.LegacyKeys(
            bookmark: bookmark(clippings), name: "Clippings", path: clippings, lastCheckedAt: later, problem: nil,
            dismissedKeys: ["a.md|1"], chosenAt: t0
        ))
    }

    func testFileIDsArePlainForEntryOneAndPrefixedForTheRest() {
        let list = listWith([clippings, work])
        XCTAssertEqual(list.qualifiedFileID("a.md", in: "f1"), "a.md")
        XCTAssertEqual(list.qualifiedFileID("a.md", in: "f2"), "f2/a.md")
        XCTAssertEqual(list.folderAndFileID("a.md")?.folderID, "f1")
        XCTAssertEqual(list.folderAndFileID("f2/a.md")?.folderID, "f2")
        XCTAssertEqual(list.folderAndFileID("f2/a.md")?.fileID, "a.md")
        XCTAssertNil(list.folderAndFileID("gone/a.md"), "a prefix naming no folder")
        XCTAssertNil(list.folderAndFileID("f1/a.md"), "entry 1 is never prefixed")
        XCTAssertNil(QuickFolderList().folderAndFileID("a.md"))
    }

    // MARK: Reconcile after a downgrade

    func testAnOlderBuildsDismissalsAreMergedIntoEntryOne() {
        var stored = listWith([clippings, work])
        stored.update("f1") { $0.dismissedKeys = ["a.md|1"] }
        var legacy = stored.mirror(keepingDismissed: [])
        legacy.dismissedKeys.insert("b.md|2") // dismissed in the older build
        legacy.dismissedKeys.remove("a.md|1") // an older build can't un-dismiss: the union keeps it
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later, newID: ids())
        XCTAssertEqual(list.folders[0].dismissedKeys, ["a.md|1", "b.md|2"])
        XCTAssertEqual(list.folders[1], stored.folders[1], "only entry 1 is mirrored")
    }

    func testAnOlderBuildThatChoseAnotherFolderMovesEntryOne() {
        var stored = listWith([clippings, work])
        stored.update("f1") { $0.lastCheckedAt = self.t0; $0.problem = .cantOpen }
        // A build with #3770 PR 2 clears the path when it chooses a different folder; one with #4274 PR 2 stores its chosen date.
        let legacy = QuickFolderList.LegacyKeys(bookmark: bookmark("reading"), name: "Reading", path: nil, chosenAt: later)
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later.addingTimeInterval(60), newID: ids())
        let first = list.folders[0]
        XCTAssertEqual(first.id, "f1")
        XCTAssertEqual(first.bookmark, bookmark("reading"))
        XCTAssertEqual(first.name, "Reading")
        XCTAssertNil(first.path)
        XCTAssertNil(first.lastCheckedAt)
        XCTAssertNil(first.problem)
        XCTAssertEqual(first.chosenAt, later, "the older build's chosen date")
    }

    func testAnOlderBuildWithoutAChosenDateThatChoseAnotherFolderFloorsAtNow() {
        let stored = listWith([clippings])
        var legacy = stored.mirror(keepingDismissed: [])
        legacy.bookmark = bookmark("reading")
        legacy.name = "Reading" // the stale mirrored path and chosen date are still there: that build knew neither key
        let now = later
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: now, newID: ids())
        XCTAssertEqual(list.folders[0].name, "Reading")
        XCTAssertNil(list.folders[0].path)
        XCTAssertEqual(list.folders[0].chosenAt, now)
    }

    func testARefreshedBookmarkForTheSameFolderKeepsWhatTheScanLearned() {
        var stored = listWith([clippings])
        stored.update("f1") { $0.lastCheckedAt = self.t0 }
        var legacy = stored.mirror(keepingDismissed: [])
        legacy.bookmark = bookmark("refreshed")
        legacy.lastCheckedAt = later // the older build scanned since
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later, newID: ids())
        let first = list.folders[0]
        XCTAssertEqual(first.bookmark, bookmark("refreshed"))
        XCTAssertEqual(first.path, clippings)
        XCTAssertEqual(first.chosenAt, t0)
        XCTAssertEqual(first.lastCheckedAt, later)
    }

    func testAnOlderBuildThatRemovedTheFolderRemovesEntryOne() {
        var stored = listWith([clippings, work])
        stored.update("f1") { $0.dismissedKeys = ["a.md|1"] }
        let legacy = QuickFolderList.LegacyKeys(dismissedKeys: ["a.md|1"])
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later, newID: ids())
        XCTAssertEqual(list.folders.map(\.id), ["f2"])
        XCTAssertEqual(list.retiredDismissals[QuickFolderReconnectRule.standardized(clippings)], ["a.md|1"])
    }

    func testAnOlderBuildThatDismissedAndThenRemovedAFolderWithNoStoredPathKeepsEveryDismissal() {
        let stored = QuickFolderList(folders: [.init(id: "f1", bookmark: bookmark("1"), name: "Clippings", dismissedKeys: ["a.md|1"])])
        // The older build dismissed one more file, then removed the folder; it still had the path key from a scan.
        let legacy = QuickFolderList.LegacyKeys(path: clippings, dismissedKeys: ["a.md|1", "x.md|5"])
        var list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later, newID: ids())
        XCTAssertTrue(list.folders.isEmpty)
        XCTAssertEqual(list.retiredDismissals[QuickFolderReconnectRule.standardized(clippings)], ["a.md|1", "x.md|5"])
        list.add(id: "f2", bookmark: bookmark("again"), name: "Clippings", path: clippings, now: later)
        XCTAssertEqual(list.entry("f2")?.dismissedKeys, ["a.md|1", "x.md|5"])
    }

    func testASameNamedFolderChosenByABuildThatNeverWroteThePathIsAnotherFolder() {
        var stored = listWith([clippings])
        stored.update("f1") { $0.lastCheckedAt = self.t0 }
        var legacy = stored.mirror(keepingDismissed: [])
        legacy.bookmark = bookmark("work clippings") // same name "Clippings"; the stale mirrored path and time are untouched
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later, newID: ids())
        XCTAssertNil(list.folders[0].path, "no scan proved it is the same folder")
        XCTAssertNil(list.folders[0].lastCheckedAt)
        XCTAssertEqual(list.folders[0].chosenAt, later)
        XCTAssertEqual(list.folders[0].bookmark, bookmark("work clippings"))
    }

    func testAnOlderBuildThatChoseAFolderAfterEveryFolderWasRemovedGivesANewEntryOne() {
        var stored = listWith([clippings])
        stored.update("f1") { $0.dismissedKeys = ["a.md|1"] }
        stored.remove("f1")
        let legacy = QuickFolderList.LegacyKeys(bookmark: bookmark("reading"), name: "Reading")
        let list = QuickFolderList.reconciled(stored: stored, legacy: legacy, now: later, newID: ids("f9"))
        XCTAssertEqual(list.folders.map(\.id), ["f9"])
        XCTAssertEqual(list.folders[0].chosenAt, later)
        XCTAssertEqual(list.retiredDismissals.count, 1, "the removed folder's dismissals are kept")
    }

    func testNothingChangedLeavesTheListAlone() {
        var stored = listWith([clippings, work])
        stored.update("f1") { $0.dismissedKeys = ["a.md|1"]; $0.lastCheckedAt = self.later }
        let list = QuickFolderList.reconciled(stored: stored, legacy: stored.mirror(keepingDismissed: []), now: later, newID: ids())
        XCTAssertEqual(list, stored)
    }

    // MARK: Adding, re-pointing and removing

    func testRemovingEntryOneMakesTheNextFolderTheMirroredOne() {
        var list = listWith([clippings, work])
        list.update("f1") { $0.dismissedKeys = ["a.md|1"] }
        list.update("f2") { $0.dismissedKeys = ["z.md|9"] }
        XCTAssertTrue(list.remove("f1"))
        let mirror = list.mirror(keepingDismissed: ["a.md|1"])
        XCTAssertEqual(mirror.bookmark, bookmark(work))
        XCTAssertEqual(mirror.path, work)
        XCTAssertEqual(mirror.dismissedKeys, ["z.md|9"], "the old keys are rewritten from folder 2")
        XCTAssertEqual(list.retiredDismissals[QuickFolderReconnectRule.standardized(clippings)], ["a.md|1"], "folder 1's set retired first")
        XCTAssertEqual(list.qualifiedFileID("z.md", in: "f2"), "z.md")
    }

    func testAddingARemovedFolderAgainKeepsItsDismissedFiles() {
        var list = listWith([clippings])
        list.update("f1") { $0.dismissedKeys = ["a.md|1"] }
        list.remove("f1")
        // The same folder, spelled as iOS sometimes gives it, with a trailing slash.
        let respelled = clippings.replacingOccurrences(of: "/private/var", with: "/var") + "/"
        XCTAssertEqual(list.add(id: "f2", bookmark: bookmark("again"), name: "Clippings", path: respelled, now: later), .added("f2"))
        XCTAssertEqual(list.entry("f2")?.dismissedKeys, ["a.md|1"])
        XCTAssertEqual(list.entry("f2")?.chosenAt, later)
        XCTAssertTrue(list.retiredDismissals.isEmpty)
    }

    func testRemovingAFolderWithNoKnownPathKeepsItsDismissalsForEveryLaterFolder() {
        var list = QuickFolderList(folders: [
            .init(id: "f1", bookmark: bookmark("1"), name: "Clippings", dismissedKeys: ["a.md|1"]),
            .init(id: "f2", bookmark: bookmark("2"), name: "Other", dismissedKeys: ["b.md|2"]),
        ])
        list.remove("f1", resolvedPath: clippings)
        XCTAssertEqual(list.retiredDismissals[QuickFolderReconnectRule.standardized(clippings)], ["a.md|1"])
        list.remove("f2")
        XCTAssertEqual(list.retiredDismissals[QuickFolderList.unknownPathKey], ["b.md|2"])
        XCTAssertFalse(list.remove("f2"))
        list.add(id: "f3", bookmark: bookmark("3"), name: "Other", path: "/folders/Other", now: t0)
        list.add(id: "f4", bookmark: bookmark("4"), name: "Clippings", path: clippings, now: t0)
        XCTAssertEqual(list.entry("f3")?.dismissedKeys, ["b.md|2"])
        XCTAssertEqual(list.entry("f4")?.dismissedKeys, ["a.md|1", "b.md|2"])
    }

    func testTheListHoldsAtMostFiveFolders() {
        var list = listWith((1...5).map { "/folders/\($0)" })
        XCTAssertTrue(list.isFull)
        XCTAssertEqual(list.add(id: "f6", bookmark: bookmark("6"), name: "6", path: "/folders/6", now: t0), .full)
        XCTAssertEqual(list.folders.count, 5)
        let fromALaterBuild = QuickFolderList(folders: (1...7).map { .init(id: "\($0)", bookmark: bookmark("\($0)"), name: "\($0)") })
        XCTAssertEqual(fromALaterBuild.folders.count, 7, "a list a later build saved with more folders loses none")
        var copy = fromALaterBuild
        XCTAssertEqual(copy.add(id: "8", bookmark: bookmark("8"), name: "8", path: "/folders/8", now: t0), .full)
    }

    func testTheSameFolderCantBeAddedTwice() {
        var list = listWith([clippings, work])
        let rows = [clippings, clippings + "/", "file://" + clippings.replacingOccurrences(of: " ", with: "%20"), clippings.replacingOccurrences(of: "/private/var", with: "/var")]
        for path in rows {
            XCTAssertEqual(list.add(id: "dup", bookmark: bookmark("x"), name: "Clippings", path: path, now: t0), .duplicate(of: "f1"), path)
        }
        // A duplicate is checked before the limit, so a full list still names the folder already there.
        list = listWith((1...4).map { "/folders/\($0)" } + [clippings])
        XCTAssertEqual(list.add(id: "dup", bookmark: bookmark("x"), name: "Clippings", path: clippings, now: t0), .duplicate(of: "f5"))
        XCTAssertEqual(list.add(id: "new", bookmark: bookmark("x"), name: "Clippings", path: clippings.lowercased(), now: t0), .full)
    }

    func testRepointingToTheSameFolderKeepsWhatTheScanLearnedAndAnyOtherStartsOver() {
        var list = listWith([clippings, work])
        list.update("f1") { $0.lastCheckedAt = self.t0; $0.problem = .cantOpen; $0.dismissedKeys = ["a.md|1"] }
        XCTAssertEqual(list.repoint("f1", bookmark: bookmark("again"), name: "Clippings", path: clippings + "/", now: later), .added("f1"))
        XCTAssertEqual(list.entry("f1")?.lastCheckedAt, t0)
        XCTAssertEqual(list.entry("f1")?.chosenAt, t0)
        XCTAssertEqual(list.entry("f1")?.bookmark, bookmark("again"))

        XCTAssertEqual(list.repoint("f1", bookmark: bookmark("r"), name: "Reading", path: "/folders/Reading", now: later), .added("f1"))
        let entry = list.entry("f1")
        XCTAssertEqual(entry?.name, "Reading")
        XCTAssertEqual(entry?.path, "/folders/Reading", "stored at once, so the duplicate check knows it before a scan")
        XCTAssertNil(entry?.lastCheckedAt)
        XCTAssertNil(entry?.problem)
        XCTAssertEqual(entry?.chosenAt, later)
        XCTAssertEqual(entry?.dismissedKeys, ["a.md|1"], "the dismissed set stays, as it always has")

        XCTAssertEqual(list.repoint("f1", bookmark: bookmark("w"), name: "Clippings", path: work, now: later), .duplicate(of: "f2"))
        XCTAssertNil(list.repoint("missing", bookmark: bookmark("w"), name: "x", path: "/x", now: later))
        XCTAssertEqual(list.add(id: "f3", bookmark: bookmark("r2"), name: "Reading", path: "/folders/Reading/", now: later), .duplicate(of: "f1"))
    }

    func testUpdateCantChangeAnEntrysID() {
        var list = listWith([clippings])
        XCTAssertTrue(list.update("f1") { $0.name = "Renamed" })
        XCTAssertEqual(list.folders.map(\.id), ["f1"])
        XCTAssertFalse(list.update("missing") { $0.name = "x" })
    }

    // MARK: UserDefaults

    func testTheStoreUpgradesSavesAndReloadsWithTheMirror() {
        let defaults = scratchDefaults()
        typealias Keys = QuickFolderList.LegacyKeys
        defaults.set(bookmark("b1"), forKey: Keys.bookmarkKey)
        defaults.set("Clippings", forKey: Keys.nameKey)
        defaults.set(["a.md|1"], forKey: Keys.dismissedKey)
        defaults.set(true, forKey: "quickFolderFeedsQueueV1")

        var list = QuickFolderListStore.load(from: defaults, now: t0, newID: ids("f1"))
        XCTAssertEqual(list.folders.map(\.id), ["f1"])
        XCTAssertNotNil(defaults.data(forKey: QuickFolderListStore.listKey))
        XCTAssertEqual(defaults.object(forKey: Keys.chosenAtKey) as? Date, t0)
        XCTAssertEqual(defaults.object(forKey: "quickFolderFeedsQueueV1") as? Bool, true, "entry 1 never writes or takes over the queue key")

        list.add(id: "f2", bookmark: bookmark("b2"), name: "Work", path: work, now: t0)
        list.update("f1") { $0.path = self.clippings; $0.problem = .cantOpen }
        QuickFolderListStore.save(list, to: defaults)
        XCTAssertEqual(defaults.string(forKey: Keys.pathKey), clippings)
        XCTAssertEqual(defaults.string(forKey: Keys.problemKey), "cantOpen")

        let reloaded = QuickFolderListStore.load(from: defaults, now: later, newID: ids())
        XCTAssertEqual(reloaded, list)

        list.remove("f1")
        list.remove("f2")
        QuickFolderListStore.save(list, to: defaults)
        XCTAssertNil(defaults.data(forKey: Keys.bookmarkKey))
        XCTAssertNil(defaults.string(forKey: Keys.nameKey))
        XCTAssertNil(defaults.string(forKey: Keys.pathKey))
        XCTAssertNil(defaults.string(forKey: Keys.problemKey))
        XCTAssertNil(defaults.object(forKey: Keys.chosenAtKey))
        XCTAssertEqual(defaults.stringArray(forKey: Keys.dismissedKey), ["a.md|1"], "the last folder's dismissed set stays in the old key")
        let empty = QuickFolderListStore.load(from: defaults, now: later, newID: ids())
        XCTAssertTrue(empty.folders.isEmpty)
        XCTAssertEqual(empty.retiredDismissals[QuickFolderReconnectRule.standardized(clippings)], ["a.md|1"])
    }

    func testAnUnreadableListIsRebuiltFromTheSingleKeys() {
        let defaults = scratchDefaults()
        defaults.set(Data("not json".utf8), forKey: QuickFolderListStore.listKey)
        defaults.set(bookmark("b1"), forKey: QuickFolderList.LegacyKeys.bookmarkKey)
        defaults.set("Clippings", forKey: QuickFolderList.LegacyKeys.nameKey)
        let list = QuickFolderListStore.load(from: defaults, now: t0, newID: ids("f1"))
        XCTAssertEqual(list.folders.map(\.name), ["Clippings"])
    }

    func testAnUnreadableListKeepsTheRetiredDismissals() {
        let defaults = scratchDefaults()
        defaults.set(Data("not json".utf8), forKey: QuickFolderListStore.listKey)
        defaults.set(["/folders/Old": ["a.md|1"]], forKey: QuickFolderListStore.retiredDismissalsKey)
        let list = QuickFolderListStore.load(from: defaults, now: t0, newID: ids())
        XCTAssertEqual(list.retiredDismissals["/folders/Old"], ["a.md|1"])
        XCTAssertEqual(QuickFolderListStore.retiredDismissals(in: defaults)["/folders/Old"], ["a.md|1"], "load saved them back, not an empty set")
    }

    func testAStoredListWithFieldsFromALaterBuildStillDecodes() throws {
        let defaults = scratchDefaults()
        let json = #"{"folders":[{"id":"f1","bookmark":"YjE=","name":"Clippings","dismissedKeys":[],"someLaterField":3}],"version":9}"#
        defaults.set(Data(json.utf8), forKey: QuickFolderListStore.listKey)
        let stored = try XCTUnwrap(QuickFolderListStore.storedList(in: defaults))
        XCTAssertEqual(stored.folders.first?.bookmark, bookmark("b1"))
    }
}
