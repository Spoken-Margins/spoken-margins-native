import Foundation
import XCTest
@testable import SessionKit

/// #3770 Design PR 5 (as amended by #4274 section 3b item 12): more than one Quick Folder on Following. Each folder lists its
/// own newest files minus its own dismissals, a file keeps an id that is unique across folders, dismissing it lands in its own
/// folder's set, and the rows have a stable order.
final class QuickFolderListFollowingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let clippings = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Clippings"
    private let work = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Work/Clippings"
    private let notes = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Notes"

    private func file(_ id: String, at seconds: TimeInterval = 100) -> QuickAccessFile {
        QuickAccessFile(id: id, name: id, relativePath: id, modifiedAt: Date(timeIntervalSince1970: seconds), modifiedAtDescription: "")
    }

    private func list(_ paths: [String]) -> QuickFolderList {
        var list = QuickFolderList()
        for (index, path) in paths.enumerated() {
            XCTAssertEqual(list.add(id: "f\(index + 1)", bookmark: Data(path.utf8), name: (path as NSString).lastPathComponent, path: path, now: t0), .added("f\(index + 1)"))
        }
        return list
    }

    /// Two folders holding a file of the same name: both are listed, entry 1's with its plain id (as one folder always had) and
    /// folder 2's with its folder prefix, so Following's rows never share an id. Each keeps its own relative path.
    func testTwoFoldersWithTheSameFileNameAreBothListedWithDistinctIDs() {
        let list = list([clippings, work])
        let listed = list.listedFiles(pools: ["f1": [file("a.md")], "f2": [file("a.md"), file("b.md", at: 50)]])
        XCTAssertEqual(listed.map(\.id), ["a.md", "f2/a.md", "f2/b.md"])
        XCTAssertEqual(listed.map(\.relativePath), ["a.md", "a.md", "b.md"])
        XCTAssertEqual(Set(listed.map(\.id)).count, listed.count)
        XCTAssertEqual(list.counts(of: listed), ["f1": 1, "f2": 2])
    }

    /// A dismissal in folder 2 hides only folder 2's file, and is stored unprefixed in folder 2's own set; the same file name in
    /// entry 1 stays listed.
    func testADismissalLandsInItsOwnFolderAndHidesOnlyThatFile() throws {
        var list = list([clippings, work])
        let pools = ["f1": [file("a.md")], "f2": [file("a.md")]]
        let second = try XCTUnwrap(list.listedFiles(pools: pools).first { $0.id == "f2/a.md" })
        let target = try XCTUnwrap(list.dismissal(of: second))
        XCTAssertEqual(target.folderID, "f2")
        XCTAssertEqual(target.key, file("a.md").dismissalKey, "stored as entry 1 always stored a key: no folder prefix")
        list.update(target.folderID) { $0.dismissedKeys.insert(target.key) }
        XCTAssertEqual(list.listedFiles(pools: pools).map(\.id), ["a.md"])
        XCTAssertEqual(list.entry("f1")?.dismissedKeys, [])
    }

    /// Entry 1's files and dismissal keys are exactly what one folder had before the list, so nothing an older build dismissed
    /// comes back.
    func testEntryOneKeepsItsPlainIDsAndKeys() throws {
        var list = list([clippings])
        list.update("f1") { $0.dismissedKeys = [file("old.md").dismissalKey] }
        let listed = list.listedFiles(pools: ["f1": [file("old.md"), file("new.md", at: 200)]])
        XCTAssertEqual(listed.map(\.id), ["new.md"])
        XCTAssertEqual(try XCTUnwrap(list.dismissal(of: listed[0])).key, file("new.md", at: 200).dismissalKey)
    }

    /// Removing entry 1 makes folder 2 entry 1: its files take plain ids, and its dismissals (stored unprefixed) still hide them.
    func testRemovingEntryOneKeepsTheNextFoldersDismissalsWorking() throws {
        var list = list([clippings, work])
        let pools = ["f1": [file("x.md")], "f2": [file("a.md"), file("b.md", at: 50)]]
        let a = try XCTUnwrap(list.listedFiles(pools: pools).first { $0.id == "f2/a.md" })
        let target = try XCTUnwrap(list.dismissal(of: a))
        list.update(target.folderID) { $0.dismissedKeys.insert(target.key) }
        list.remove("f1")
        XCTAssertEqual(list.listedFiles(pools: pools).map(\.id), ["b.md"])
        XCTAssertEqual(list.dismissal(of: file("b.md", at: 50))?.folderID, "f2")
    }

    /// Each folder lists at most its own eight, so a busy folder can't crowd another off Following.
    func testEachFolderListsAtMostItsOwnEight() {
        let list = list([clippings, work])
        let busy = (0..<12).map { file(String(format: "f%02d.md", $0), at: 1_000 - Double($0)) }
        let listed = list.listedFiles(pools: ["f1": busy, "f2": [file("quiet.md")]])
        XCTAssertEqual(list.counts(of: listed), ["f1": 8, "f2": 1])
        XCTAssertTrue(listed.contains { $0.id == "f2/quiet.md" })
    }

    /// An id whose prefix names no folder (a removed one) is not dismissed anywhere, and a folder with no pool lists nothing.
    func testAFileOfARemovedFolderIsNotDismissedIntoAnother() {
        let list = list([clippings, work])
        XCTAssertNil(list.dismissal(of: file("gone/a.md")))
        XCTAssertEqual(list.listedFiles(pools: [:]), [])
        XCTAssertEqual(QuickFolderList().listedFiles(pools: ["f1": [file("a.md")]]), [])
    }

    /// Following's rows: by name (ignoring case, numbers in order), then by location, then by id.
    func testFollowingOrderIsByNameThenLocationThenID() {
        var list = list([work, notes, clippings])
        XCTAssertEqual(list.followingOrder.map(\.id), ["f3", "f1", "f2"], "Clippings (Obsidian), Clippings (Work), Notes")
        list.update("f2") { $0.name = "clippings" }
        list.update("f2") { $0.path = nil }
        XCTAssertEqual(list.followingOrder.map(\.id), ["f2", "f3", "f1"], "no location sorts first among equal names")
        var twins = QuickFolderList()
        twins.add(id: "b", bookmark: Data([1]), name: "Same", path: "/x/one/Same", now: t0)
        twins.add(id: "a", bookmark: Data([2]), name: "Same", path: "/y/two/Same", now: t0)
        twins.update("b") { $0.path = nil }
        twins.update("a") { $0.path = nil }
        XCTAssertEqual(twins.followingOrder.map(\.id), ["a", "b"], "last by id")
    }

    func testTheLimitWordsNameTheLimit() {
        XCTAssertEqual(QuickFolderStatus.limitFootnote, "Up to 5 Quick Folders.")
        XCTAssertEqual(QuickFolderStatus.duplicateFolderMessage, "That folder is already a Quick Folder.")
    }
}
