import Foundation
import XCTest
@testable import SessionKit

/// #3769: what picking a folder again does to its Library folder. Every row is a pure merge of a walk with a record.
final class LibraryFolderMergeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let later = Date(timeIntervalSince1970: 1_790_100_000)
    private let path = "/Users/x/Documents/Daily Brief"

    // MARK: Fixtures

    private func file(_ key: String, _ sha: String?, kind: LibraryFolderWalk.Kind = .pdf) -> LibraryFolderWalk.Member {
        .init(key: key, kind: kind, size: 10, sha256: sha, url: URL(fileURLWithPath: "/tmp/\(key)"), address: nil, title: nil,
              isNotDownloaded: sha == nil)
    }

    private func link(_ key: String, _ address: String, title: String? = nil) -> LibraryFolderWalk.Member {
        .init(key: key, kind: .link, size: 0, sha256: nil, url: nil, address: address, title: title, isNotDownloaded: false)
    }

    private func walk(_ members: [LibraryFolderWalk.Member], notAdded: [LibraryFolderWalk.NotAdded] = [], other: Int = 0,
                      filesCapped: Bool = false, entriesCapped: Bool = false, deeper: Bool = false) -> LibraryFolderWalk.Result {
        .init(members: members, notAdded: notAdded, skippedOtherCount: other, filesCapped: filesCapped,
              entriesCapped: entriesCapped, hasDeeperFolders: deeper)
    }

    private var counter = 0
    private func nextID() -> String { counter += 1; return "item-\(counter)" }

    private func run(_ result: LibraryFolderWalk.Result, existing: LibraryFolderRecord? = nil, at: String? = nil,
                      date: Date? = nil) -> LibraryFolderMerge.Result {
        LibraryFolderMerge.merge(walk: result, pickedPath: at ?? path, bookmark: nil, source: .files, existing: existing,
                                 folderID: "folder", now: date ?? now, makeItemID: { self.nextID() })
    }

    private func member(_ key: String, _ sha: String?, id: String?, state: LibraryFolderRecord.MemberState = .added,
                        kind: LibraryFolderWalk.Kind = .pdf, copyOf: String? = nil, address: String? = nil) -> LibraryFolderRecord.Member {
        .init(key: key, kind: kind, name: (key as NSString).lastPathComponent, sha256: sha, address: address, itemID: id,
              addedAt: now, state: state, reason: state == .failed ? "Couldn't be opened" : nil,
              retryable: state == .failed, updatedCopyOf: copyOf)
    }

    private func record(_ members: [LibraryFolderRecord.Member], trashed: Bool = false, at: String? = nil) -> LibraryFolderRecord {
        LibraryFolderRecord(id: "folder", sourcePath: at ?? path, importedAt: now, trashedAt: trashed ? now : nil, members: members)
    }

    // MARK: A new folder

    func testANewFolderHoldsEveryFileInOrderWithItsIDsAssignedFirst() {
        let result = run(walk([file("1.pdf", "a"), file("2.txt", "b", kind: .text), file("ed.json", nil, kind: .edition),
                               link("zlist.json#001", "https://example.com/x", title: "X")], other: 3, filesCapped: true))
        XCTAssertEqual(result.record.id, "folder")
        XCTAssertEqual(result.record.sourcePath, path)
        XCTAssertEqual(result.record.members.map(\.key), ["1.pdf", "2.txt", "ed.json", "zlist.json#001"])
        XCTAssertEqual(result.record.members.map(\.itemID), ["item-1", "item-2", nil, nil], "an edition's and a link's ID come later")
        XCTAssertTrue(result.record.members.allSatisfy { $0.state == .adding })
        XCTAssertEqual(result.record.members.last?.name, "X")
        XCTAssertEqual(result.record.members.last?.address, "https://example.com/x")
        XCTAssertEqual(result.jobs.map(\.memberKey), result.record.members.map(\.key))
        XCTAssertEqual(result.jobs.map(\.itemID), ["item-1", "item-2", nil, nil])
        XCTAssertEqual(result.record.skippedOtherCount, 3)
        XCTAssertTrue(result.record.capped)
        XCTAssertEqual(result.record.importedAt, now)
    }

    func testEachCapFlagMarksTheFolderCapped() {
        XCTAssertFalse(run(walk([])).record.capped)
        XCTAssertTrue(run(walk([], filesCapped: true)).record.capped)
        XCTAssertTrue(run(walk([], entriesCapped: true)).record.capped)
        XCTAssertTrue(run(walk([], deeper: true)).record.capped)
    }

    func testAnEmptyFolderIsStillAFolderAndWalkLevelNotesAreKept() {
        let result = run(walk([], notAdded: [.init(key: "p.spokenmargins", name: "p.spokenmargins", reason: "Margins packets open on their own")]))
        XCTAssertTrue(result.record.members.isEmpty)
        XCTAssertTrue(result.jobs.isEmpty)
        XCTAssertEqual(result.record.notAdded.map(\.name), ["p.spokenmargins"])
    }

    func testTwoFilesWithTheSameBytesInOnePickAddTheFirstAndNameTheSecond() {
        let result = run(walk([file("a.pdf", "same"), file("copy of a.pdf", "same"), file("b.pdf", "other")]))
        XCTAssertEqual(result.jobs.map(\.memberKey), ["a.pdf", "b.pdf"])
        XCTAssertEqual(result.record.notAdded, [.init(key: "copy of a.pdf", name: "copy of a.pdf", reason: "Same file as “a.pdf”")])
    }

    func testTheSameLinkTwiceInOnePickIsAddedOnce() {
        let result = run(walk([link("a.json#001", "https://example.com/x"), link("b.json#001", "https://example.com/x")]))
        XCTAssertEqual(result.jobs.map(\.memberKey), ["a.json#001"])
        XCTAssertEqual(result.skipped, [.repeatedInThisPick(walkKey: "b.json#001")])
    }

    // MARK: The same folder again

    func testSameBytesAgainAddsNothing() {
        let existing = record([member("1.pdf", "a", id: "i1")])
        let result = run(walk([file("1.pdf", "a")]), existing: existing)
        XCTAssertTrue(result.jobs.isEmpty)
        XCTAssertEqual(result.skipped, [.alreadyInFolder(memberKey: "1.pdf")])
        XCTAssertEqual(result.record.members, existing.members)
    }

    func testSameBytesAtANewPathAddsNothingAndKeepsTheMember() {
        let existing = record([member("1.pdf", "a", id: "i1")])
        let result = run(walk([file("moved/1.pdf", "a")]), existing: existing)
        XCTAssertTrue(result.jobs.isEmpty)
        XCTAssertEqual(result.record.members.map(\.key), ["moved/1.pdf"], "the member follows its file")
        XCTAssertEqual(result.record.members.map(\.itemID), ["i1"])
    }

    func testAFileThatMovedAndThenChangesIsANewerCopyAtItsNewPlace() {
        let moved = run(walk([file("moved/1.pdf", "a")]), existing: record([member("1.pdf", "a", id: "i1")])).record
        let changed = run(walk([file("moved/1.pdf", "a2")]), existing: moved)
        XCTAssertEqual(changed.record.members.map(\.key), ["moved/1.pdf", "moved/1.pdf#updated-2"])
        XCTAssertEqual(changed.record.members.last?.updatedCopyOf, "moved/1.pdf")
        // And a different file now at the old path is new, not a copy of the one that left.
        let other = run(walk([file("1.pdf", "unrelated")]), existing: moved)
        XCTAssertEqual(other.record.members.map(\.key), ["1.pdf", "moved/1.pdf"].sorted { NaturalPathOrder.areInIncreasingOrder($0, $1) })
        XCTAssertNil(other.record.members.first { $0.key == "1.pdf" }?.updatedCopyOf)
    }

    func testABackupThatSortsAheadDoesNotTakeTheMembersKeyOrMakeItsFileTheDuplicate() {
        let existing = record([member("brief.pdf", "a", id: "i1")])
        let picked = run(walk([file("Archive/brief.pdf", "a"), file("brief.pdf", "a")]), existing: existing)
        XCTAssertEqual(picked.record.members.map(\.key), ["brief.pdf"], "the member stays at its own file")
        XCTAssertEqual(picked.record.notAdded.map(\.key), ["Archive/brief.pdf"], "the backup is the duplicate")
        XCTAssertEqual(picked.record.notAdded.first?.reason, "Same file as “brief.pdf”")
        XCTAssertTrue(picked.jobs.isEmpty)
        // Later the member's own file changes: that is its newer copy, not an unrelated file.
        let changed = run(walk([file("Archive/brief.pdf", "a"), file("brief.pdf", "b")]), existing: picked.record)
        XCTAssertEqual(changed.record.members.map(\.key), ["brief.pdf", "brief.pdf#updated-2"])
        XCTAssertEqual(changed.record.members.last?.updatedCopyOf, "brief.pdf")
    }

    func testABackupThatSortsAheadOfAnUpdatedMembersFileIsTheDuplicateOnEveryPick() {
        let existing = record([member("brief.pdf", "a", id: "i1"), member("brief.pdf#updated-2", "a2", id: "i2", copyOf: "brief.pdf")])
        let result = run(walk([file("Archive/brief.pdf", "a2"), file("brief.pdf", "a2")]), existing: existing)
        XCTAssertEqual(result.record.notAdded.map(\.key), ["Archive/brief.pdf"])
        XCTAssertEqual(result.record.members.map(\.key), ["brief.pdf", "brief.pdf#updated-2"])
        XCTAssertTrue(result.jobs.isEmpty)
    }

    func testAMemberWithNoHashYetIsJudgedByItsPathWhenABackupSortsAhead() {
        let existing = record([member("brief.pdf", nil, id: "i1")])
        let result = run(walk([file("Archive/brief.pdf", "a"), file("brief.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.record.notAdded.map(\.key), ["Archive/brief.pdf"])
        XCTAssertEqual(result.record.members.map(\.key), ["brief.pdf"])
        XCTAssertEqual(result.record.members.first?.sha256, "a", "the hash is filled in from the member's own file")
    }

    func testACopyAheadOfAFileThatMovedAwayStillLetsTheMemberFollowTheFirstCopy() {
        // The file is gone from its old path, so the first copy in the walk is where it went.
        let existing = record([member("brief.pdf", "a", id: "i1")])
        let result = run(walk([file("Archive/brief.pdf", "a"), file("Archive/brief 2.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.record.members.map(\.key), ["Archive/brief.pdf"])
        XCTAssertTrue(result.jobs.isEmpty)
    }

    func testAChangedFileAtTheMembersPathKeepsItsKeyWhileAnUnchangedBackupIsSkipped() {
        let existing = record([member("brief.pdf", "a", id: "i1")])
        let result = run(walk([file("Archive/brief.pdf", "a"), file("brief.pdf", "b")]), existing: existing)
        XCTAssertEqual(result.record.members.map(\.key), ["brief.pdf", "brief.pdf#updated-2"])
        XCTAssertEqual(result.record.members.last?.updatedCopyOf, "brief.pdf")
        XCTAssertEqual(result.jobs.map(\.memberKey), ["brief.pdf#updated-2"])
    }

    func testAMemberWithCopiesStaysPutWhenTheSameBytesShowUpElsewhere() {
        let existing = record([member("1.pdf", "a", id: "i1"), member("1.pdf#updated-2", "a2", id: "i1b", copyOf: "1.pdf")])
        let result = run(walk([file("elsewhere/1.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.record.members.map(\.key), ["1.pdf", "1.pdf#updated-2"])
        XCTAssertTrue(result.jobs.isEmpty)
    }

    func testANewFileJoinsInItsPlaceInOrder() {
        let existing = record([member("1.pdf", "a", id: "i1"), member("3.pdf", "c", id: "i3"), member("z.pdf", "z", id: "iz")])
        let result = run(walk([file("1.pdf", "a"), file("2.pdf", "b"), file("3.pdf", "c"), file("10.pdf", "t"), file("z.pdf", "z"), file("zz.pdf", "q")]),
                         existing: existing)
        XCTAssertEqual(result.record.members.map(\.key), ["1.pdf", "2.pdf", "3.pdf", "10.pdf", "z.pdf", "zz.pdf"])
        XCTAssertEqual(result.jobs.map(\.memberKey), ["2.pdf", "10.pdf", "zz.pdf"])
        XCTAssertEqual(result.record.members.first?.addedAt, now, "an old member keeps its time")
    }

    func testAChangedFileAtTheSamePathIsANewerCopyRightAfterTheOldOne() {
        let existing = record([member("1.pdf", "a", id: "i1"), member("2.pdf", "b", id: "i2")])
        let result = run(walk([file("1.pdf", "a2"), file("2.pdf", "b")]), existing: existing, date: later)
        XCTAssertEqual(result.record.members.map(\.key), ["1.pdf", "1.pdf#updated-2", "2.pdf"])
        let copy = result.record.members[1]
        XCTAssertEqual(copy.updatedCopyOf, "1.pdf")
        XCTAssertEqual(copy.name, "1.pdf")
        XCTAssertEqual(copy.sha256, "a2")
        XCTAssertEqual(copy.itemID, "item-1")
        XCTAssertEqual(result.record.members[0], existing.members[0], "the old item and its member are untouched")
        XCTAssertEqual(result.jobs.map(\.memberKey), ["1.pdf#updated-2"])
        XCTAssertEqual(copy.addedAt, later)
    }

    func testAFileChangedAgainAfterACopyMakesAThirdAndSameBytesAsTheCopyAddsNothing() {
        let existing = record([member("1.pdf", "a", id: "i1"), member("1.pdf#updated-2", "a2", id: "i1b", copyOf: "1.pdf")])
        let again = run(walk([file("1.pdf", "a2")]), existing: existing)
        XCTAssertTrue(again.jobs.isEmpty, "the same bytes as the copy")
        let third = run(walk([file("1.pdf", "a3")]), existing: existing)
        XCTAssertEqual(third.record.members.map(\.key), ["1.pdf", "1.pdf#updated-2", "1.pdf#updated-3"])
        XCTAssertEqual(third.record.members.last?.updatedCopyOf, "1.pdf#updated-2")
        let backToOriginal = run(walk([file("1.pdf", "a")]), existing: existing)
        XCTAssertTrue(backToOriginal.jobs.isEmpty, "bytes the folder already has, wherever they now sit")
    }

    func testANewFileSortsBesideACopyWhereItsOriginalSorts() {
        let existing = record([member("1.pdf", "a", id: "i1"), member("1.pdf#updated-2", "a2", id: "i1b", copyOf: "1.pdf"), member("5.pdf", "e", id: "i5")])
        let result = run(walk([file("1.pdf", "a2"), file("3.pdf", "c"), file("5.pdf", "e")]), existing: existing)
        XCTAssertEqual(result.record.members.map(\.key), ["1.pdf", "1.pdf#updated-2", "3.pdf", "5.pdf"])
    }

    func testAFileGoneFromDiskStaysInTheFolder() {
        let existing = record([member("1.pdf", "a", id: "i1"), member("2.pdf", "b", id: "i2")])
        let result = run(walk([file("1.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.record.members.map(\.key), ["1.pdf", "2.pdf"])
        XCTAssertEqual(result.record.members[1].state, .added)
        XCTAssertTrue(result.jobs.isEmpty)
    }

    func testAFailedMemberIsTriedAgainWithTheSameIDAndTheFileAsItIsNow() {
        let existing = record([member("1.pdf", "old", id: "i1", state: .failed)])
        let result = run(walk([file("1.pdf", "new")]), existing: existing)
        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertTrue(result.jobs[0].isRetry)
        XCTAssertEqual(result.jobs[0].itemID, "i1")
        XCTAssertEqual(result.record.members.count, 1, "no second member")
        XCTAssertEqual(result.record.members[0].state, .adding)
        XCTAssertNil(result.record.members[0].reason)
        XCTAssertEqual(result.record.members[0].sha256, "new")
    }

    func testAFailedMemberWhoseFileMovedIsTriedAgainAtItsNewPath() {
        let existing = record([member("1.pdf", "a", id: "i1", state: .failed)])
        let result = run(walk([file("sub/1.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.jobs.map(\.memberKey), ["sub/1.pdf"], "the member follows its file")
        XCTAssertEqual(result.record.members.map(\.key), ["sub/1.pdf"])
        XCTAssertEqual(result.jobs.first?.itemID, "i1")
    }

    func testAFailedMemberThatNeverHadAnIDGetsOneForAFileKind() {
        let existing = record([member("1.pdf", "a", id: nil, state: .failed)])
        let result = run(walk([file("1.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.jobs.first?.itemID, "item-1")
    }

    func testAFailedMemberWhoseFileIsGoneStaysFailed() {
        let existing = record([member("1.pdf", "a", id: "i1", state: .failed)])
        let result = run(walk([]), existing: existing)
        XCTAssertEqual(result.record.members[0].state, .failed)
        XCTAssertTrue(result.jobs.isEmpty)
    }

    func testARemovedMemberIsNeverAdoptedBackWhateverHappensToTheFile() {
        let existing = record([member("1.pdf", "a", id: "i1", state: .removed)])
        XCTAssertTrue(run(walk([file("1.pdf", "a")]), existing: existing).jobs.isEmpty, "same bytes, same path")
        XCTAssertTrue(run(walk([file("elsewhere/1.pdf", "a")]), existing: existing).jobs.isEmpty, "same bytes, new path")
        XCTAssertEqual(run(walk([file("1.pdf", "a")]), existing: existing).skipped, [.removedFromFolder(memberKey: "1.pdf")])
        XCTAssertEqual(run(walk([file("1.pdf", "a")]), existing: existing).record.members.map(\.state), [.removed])
    }

    func testNewContentAtARemovedMembersPathIsANewerCopyButTheRemovedBytesNeverReturn() {
        // A daily file re-exported under one name must not be lost forever because today's was removed.
        let existing = record([member("brief.pdf", "monday", id: "i1", state: .removed)])
        let tuesday = run(walk([file("brief.pdf", "tuesday")]), existing: existing)
        XCTAssertEqual(tuesday.record.members.map(\.key), ["brief.pdf", "brief.pdf#updated-2"])
        XCTAssertEqual(tuesday.record.members.map(\.state), [.removed, .adding])
        // The listener removes Tuesday's copy too; Wednesday's file is still new, and Monday's bytes still are not.
        var removedBoth = tuesday.record
        removedBoth.members[1].state = .removed
        let wednesday = run(walk([file("brief.pdf", "wednesday")]), existing: removedBoth)
        XCTAssertEqual(wednesday.record.members.last?.updatedCopyOf, "brief.pdf#updated-2")
        XCTAssertEqual(wednesday.record.members.count, 3)
        XCTAssertTrue(run(walk([file("brief.pdf", "monday")]), existing: removedBoth).jobs.isEmpty)
    }

    func testAnICloudPlaceholderIsJudgedByItsPath() {
        let placeholder = file("1.pdf", nil)
        XCTAssertEqual(run(walk([placeholder])).jobs.count, 1, "new")
        let present = record([member("1.pdf", "a", id: "i1")])
        XCTAssertTrue(run(walk([placeholder]), existing: present).jobs.isEmpty, "the file is already a member")
        let failed = record([member("1.pdf", nil, id: "i1", state: .failed)])
        XCTAssertEqual(run(walk([placeholder]), existing: failed).jobs.first?.isRetry, true)
    }

    func testAPlaceholderThatHasDownloadedFillsInItsHashAndIsNotAddedAgainElsewhere() {
        let existing = record([member("1.pdf", nil, id: "i1")])
        let downloaded = run(walk([file("1.pdf", "a")]), existing: existing)
        XCTAssertTrue(downloaded.jobs.isEmpty)
        XCTAssertEqual(downloaded.record.members.first?.sha256, "a")
        XCTAssertTrue(run(walk([file("copy/1.pdf", "a")]), existing: downloaded.record).jobs.isEmpty, "same bytes elsewhere now match")
    }

    func testAMemberStillAddingCountsAsPresent() {
        let existing = record([member("1.pdf", "a", id: "i1", state: .adding)])
        XCTAssertTrue(run(walk([file("1.pdf", "a")]), existing: existing).jobs.isEmpty)
    }

    // MARK: Links

    func testALinkListThatGainsEntriesAddsOnlyTheNewAddresses() {
        let existing = record([
            member("brief.json#001", nil, id: "L1", kind: .link, address: "https://example.com/1"),
            member("brief.json#002", nil, id: "L2", kind: .link, address: "https://example.com/2"),
        ])
        let result = run(walk([link("brief.json#001", "https://example.com/1"), link("brief.json#002", "https://example.com/2"),
                               link("brief.json#003", "https://example.com/3")]), existing: existing)
        XCTAssertEqual(result.jobs.map(\.memberKey), ["brief.json#003"])
        XCTAssertEqual(result.record.members.map(\.key), ["brief.json#001", "brief.json#002", "brief.json#003"])
    }

    func testAReorderedLinkListAddsNothingAndEntriesNeverBecomeUpdatedCopies() {
        let existing = record([
            member("brief.json#001", nil, id: "L1", kind: .link, address: "https://example.com/1"),
            member("brief.json#002", nil, id: "L2", kind: .link, address: "https://example.com/2"),
        ])
        let result = run(walk([link("brief.json#001", "https://example.com/2", title: "Changed title"),
                               link("brief.json#002", "https://example.com/1")]), existing: existing)
        XCTAssertTrue(result.jobs.isEmpty)
        XCTAssertFalse(result.record.members.contains { $0.updatedCopyOf != nil })
        XCTAssertEqual(result.record.members.count, 2)
    }

    func testAnEditedListThatReusesANumberGetsAFreeKeyForTheNewEntry() {
        // [A, B] became [B, C]: B is #001 now, and C is #002 while B's member still holds #002.
        let existing = record([
            member("brief.json#001", nil, id: "L1", kind: .link, address: "https://example.com/a"),
            member("brief.json#002", nil, id: "L2", kind: .link, address: "https://example.com/b"),
        ])
        let result = run(walk([link("brief.json#001", "https://example.com/b"), link("brief.json#002", "https://example.com/c", title: "C")]),
                         existing: existing)
        let keys = result.record.members.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "keys stay unique")
        XCTAssertEqual(result.jobs.count, 1)
        let job = result.jobs[0]
        XCTAssertEqual(result.record.members.filter { $0.key == job.memberKey }.map(\.address), ["https://example.com/c"])
        XCTAssertEqual(result.record.members.first { $0.address == "https://example.com/b" }?.itemID, "L2", "B is untouched")
    }

    func testAFailedLinkIsTriedAgainAndARemovedOneIsNot() {
        let existing = record([
            member("l.json#001", nil, id: nil, state: .failed, kind: .link, address: "https://example.com/1"),
            member("l.json#002", nil, id: "L2", state: .removed, kind: .link, address: "https://example.com/2"),
        ])
        let result = run(walk([link("l.json#001", "https://example.com/1"), link("l.json#002", "https://example.com/2")]), existing: existing)
        XCTAssertEqual(result.jobs.map(\.memberKey), ["l.json#001"])
        XCTAssertEqual(result.jobs.first?.isRetry, true)
        XCTAssertNil(result.jobs.first?.itemID)
        XCTAssertEqual(result.skipped, [.removedFromFolder(memberKey: "l.json#002")])
    }

    // MARK: Which folder

    func testTheSameFolderIsTheSameStandardizedPathAndNotADeletedOne() {
        let live = record([], at: path)
        let deleted = LibraryFolderRecord(id: "gone", sourcePath: path, importedAt: now, trashedAt: now)
        XCTAssertEqual(LibraryFolderMerge.sameFolder(pickedPath: path, in: [deleted, live])?.id, "folder")
        XCTAssertNil(LibraryFolderMerge.sameFolder(pickedPath: path, in: [deleted]), "a deleted folder never matches")
        XCTAssertNil(LibraryFolderMerge.sameFolder(pickedPath: "/Users/x/Documents/Other", in: [live]), "a different location")
        XCTAssertNil(LibraryFolderMerge.sameFolder(pickedPath: path, in: []))
    }

    func testTwoLiveFoldersAtOnePathChooseTheOldest() {
        let older = LibraryFolderRecord(id: "b", sourcePath: path, importedAt: now)
        let newer = LibraryFolderRecord(id: "a", sourcePath: path, importedAt: later)
        XCTAssertEqual(LibraryFolderMerge.sameFolder(pickedPath: path, in: [newer, older])?.id, "b")
    }

    func testPickedPathsAreStandardizedAndInNFC() {
        let composed = LibraryFolderRecord.standardizedPath(of: URL(fileURLWithPath: "/Users/x/Café/../Café/Brief"))
        let decomposed = LibraryFolderRecord.standardizedPath(of: URL(fileURLWithPath: "/Users/x/Cafe\u{301}/Brief/"))
        XCTAssertEqual(composed, decomposed)
        XCTAssertEqual(composed, "/Users/x/Café/Brief")
    }

    func testAPickOfADeletedFoldersPathMakesANewFolder() {
        let deleted = LibraryFolderRecord(id: "gone", sourcePath: path, importedAt: now, trashedAt: now,
                                          members: [member("1.pdf", "a", id: "i1")])
        let existing = LibraryFolderMerge.sameFolder(pickedPath: path, in: [deleted])
        let result = run(walk([file("1.pdf", "a")]), existing: existing)
        XCTAssertEqual(result.record.id, "folder")
        XCTAssertEqual(result.jobs.count, 1)
    }

    func testMergingAgainReplacesWalkNotesAndKeepsAdoptedCountAndSource() {
        var existing = record([member("1.pdf", "a", id: "i1")])
        existing.adoptedCount = 4
        existing.skippedOtherCount = 9
        existing.notAdded = [.init(key: "old", name: "old", reason: "old")]
        existing.source = .quickFolder(name: "Clippings")
        let result = run(walk([file("1.pdf", "a")], other: 1), existing: existing)
        XCTAssertEqual(result.record.adoptedCount, 4)
        XCTAssertEqual(result.record.skippedOtherCount, 1)
        XCTAssertTrue(result.record.notAdded.isEmpty)
        XCTAssertEqual(result.record.source, .quickFolder(name: "Clippings"))
        XCTAssertEqual(result.record.importedAt, now)
    }

    // MARK: Naming

    func testNameClashesGetANumberWhateverTheCaseAndAccents() {
        func collection(_ name: String) -> ItemCollection { ItemCollection(id: name, name: name, createdAt: now) }
        XCTAssertEqual(LibraryFolderNaming.uniqueName("Daily Brief", in: []), "Daily Brief")
        XCTAssertEqual(LibraryFolderNaming.uniqueName("Daily Brief", in: [collection("daily brief")]), "Daily Brief 2")
        XCTAssertEqual(LibraryFolderNaming.uniqueName("Café", in: [collection("Cafe")]), "Café 2")
        XCTAssertEqual(LibraryFolderNaming.uniqueName("  Daily   Brief ", in: [collection("Daily Brief"), collection("Daily Brief 2")]), "Daily Brief 3")
        XCTAssertNil(LibraryFolderNaming.uniqueName("   ", in: []))
    }

    func testALongNameIsCutSoTheNumberFits() throws {
        let long = String(repeating: "a", count: ItemCollectionEditing.maximumNameCharacters)
        let taken = [ItemCollection(id: "x", name: long, createdAt: now)]
        let unique = try XCTUnwrap(LibraryFolderNaming.uniqueName(long, in: taken))
        XCTAssertEqual(unique.count, ItemCollectionEditing.maximumNameCharacters)
        XCTAssertTrue(unique.hasSuffix(" 2"))
        XCTAssertFalse(ItemCollectionEditing.isNameTaken(unique, in: taken))
    }

    func testADeletedFoldersNameStillClashes() {
        // A deleted folder keeps its collection, so passing every collection covers it.
        let trashed = ItemCollection(id: "gone", name: "Brief", createdAt: now)
        XCTAssertEqual(LibraryFolderNaming.uniqueName("Brief", in: [trashed]), "Brief 2")
    }

    // MARK: Launch and orphans

    func testLaunchSettlesInterruptedMembersAndHonoursAnOlderBuildsEdits() {
        let folder = LibraryFolderRecord(id: "folder", sourcePath: path, importedAt: now, members: [
            member("a.pdf", "a", id: "ia", state: .added),
            member("b.pdf", "b", id: "ib", state: .adding),          // saved, then the app ended
            member("c.pdf", "c", id: "ic", state: .adding),          // never saved
            member("d.json", nil, id: nil, state: .adding, kind: .edition),  // ID not known yet
            member("e.pdf", "e", id: "ie", state: .added),           // an older build took it out of the collection
            member("f.pdf", "f", id: "if", state: .failed),
            member("g.pdf", "g", id: "ig", state: .removed),
        ])
        let collection = ItemCollection(id: "folder", name: "Brief", itemIDs: ["ia", "other", "if", "ig"], createdAt: now)
        let resolution = LibraryFolderLaunchRule.resolved(folder, collection: collection, existingItemIDs: ["ia", "ib", "ie", "if", "ig", "other"])
        XCTAssertEqual(resolution.record.members.map(\.state), [.added, .added, .failed, .failed, .removed, .failed, .removed])
        XCTAssertEqual(resolution.record.members[2].reason, LibraryFolderRecord.stoppedReason)
        XCTAssertTrue(resolution.record.members[2].retryable)
        XCTAssertEqual(resolution.record.members[3].reason, LibraryFolderRecord.stoppedReason)
        XCTAssertNil(resolution.record.members[1].reason)
        XCTAssertEqual(resolution.collection.itemIDs, ["ia", "other", "if", "ig", "ib"], "the saved item joins the collection")
        XCTAssertEqual(resolution.record.members[5].reason, "Couldn't be opened", "a failure keeps its own reason")
    }

    func testLaunchChangesNothingWhenNothingIsOff() {
        let folder = record([member("a.pdf", "a", id: "ia"), member("b.pdf", "b", id: "ib", state: .failed)])
        let collection = ItemCollection(id: "folder", name: "Brief", itemIDs: ["ia", "ib"], createdAt: now)
        let resolution = LibraryFolderLaunchRule.resolved(folder, collection: collection, existingItemIDs: ["ia", "ib"])
        XCTAssertEqual(resolution.record, folder)
        XCTAssertEqual(resolution.collection, collection)
    }

    func testARecordWithoutItsCollectionIsAnOrphan() {
        let kept = LibraryFolderRecord(id: "kept", sourcePath: path, importedAt: now)
        let orphan = LibraryFolderRecord(id: "orphan", sourcePath: path, importedAt: now)
        let collections = [ItemCollection(id: "kept", name: "Kept", createdAt: now), ItemCollection(id: "plain", name: "Plain", createdAt: now)]
        XCTAssertEqual(LibraryFolderOrphanRule.orphanedFolderIDs(folders: [kept, orphan], collections: collections), ["orphan"])
        XCTAssertEqual(LibraryFolderOrphanRule.orphanedFolderIDs(folders: [], collections: collections), [])
    }
}
