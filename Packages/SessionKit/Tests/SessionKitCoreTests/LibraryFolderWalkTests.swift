import CryptoKit
import XCTest
@testable import SessionKit

/// #3769 PR 1: what a picked folder lists, in what order, and where it stops. Every case uses real files in a
/// real temporary folder, so the walk's own file reading is what is tested.
final class LibraryFolderWalkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "library-folder-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func write(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func walk(maxFiles: Int = 200, maxDepth: Int = 4, maxEntries: Int = 2_000) -> LibraryFolderWalk.Result {
        LibraryFolderWalk.walk(root, maxFiles: maxFiles, maxDepth: maxDepth, maxEntries: maxEntries)
    }

    private func keys(_ result: LibraryFolderWalk.Result) -> [String] { result.members.map(\.key) }

    private let linkVersion = LinkListFile.schemaVersion
    private func linkList(_ urls: String...) -> String {
        let entries = urls.map { #"{"url": "\#($0)"}"# }.joined(separator: ",")
        return #"{"schemaVersion": "\#(linkVersion)", "title": "Brief", "entries": [\#(entries)]}"#
    }
    private let editionJSON = #"{"schemaVersion": "\#(ListeningEdition.version)", "title": "An edition"}"#

    // MARK: Order: names

    func testNumbersInNamesAreOrderedAsNumbersNotLetters() throws {
        for name in ["10.pdf", "2.pdf", "1.pdf", "Chapter 11.txt", "Chapter 9.txt"] { try write(name) }
        XCTAssertEqual(keys(walk()), ["1.pdf", "2.pdf", "10.pdf", "Chapter 9.txt", "Chapter 11.txt"])
    }

    func testSubfolderOrderIsByPathComponentNotByWholeString() throws {
        for path in ["Disc 1.5/y.mp3", "Disc 1/x.mp3", "Disc 2/a.mp3", "Disc 10/a.mp3", "Disc 1/b.mp3"] { try write(path) }
        XCTAssertEqual(keys(walk()), ["Disc 1/b.mp3", "Disc 1/x.mp3", "Disc 1.5/y.mp3", "Disc 2/a.mp3", "Disc 10/a.mp3"])
    }

    func testAFolderSortsBesideAFileOfTheSameStem() throws {
        try write("a/x.pdf"); try write("a.pdf"); try write("b.pdf")
        XCTAssertEqual(keys(walk()), ["a/x.pdf", "a.pdf", "b.pdf"])
    }

    func testOrderComparisonNeighbours() {
        // (lhs, rhs, expected)
        let table: [(String, String, ComparisonResult)] = [
            ("2", "10", .orderedAscending),
            ("a/b", "a", .orderedDescending),            // a prefix comes first
            ("a", "a/b", .orderedAscending),
            ("Disc 1/x", "Disc 1.5/y", .orderedAscending),
            ("caf\u{E9}.pdf", "cafe\u{301}.pdf", .orderedSame), // NFC and NFD spellings are the same name
            ("", "", .orderedSame),
            ("a/", "a", .orderedSame),                   // a trailing slash adds no component
        ]
        for (lhs, rhs, expected) in table {
            XCTAssertEqual(NaturalPathOrder.compare(lhs, rhs), expected, "\(lhs) vs \(rhs)")
        }
        // Whatever the answer for spacing and case variants, it is a strict, repeatable order: never both ways.
        for (lhs, rhs) in [("a  b", "a b"), ("a.pdf", "A.pdf"), ("x-1", "x_1"), ("é", "e")] {
            let forward = NaturalPathOrder.compare(lhs, rhs)
            let backward = NaturalPathOrder.compare(rhs, lhs)
            XCTAssertNotEqual(forward, .orderedSame, "\(lhs) vs \(rhs) should still be ordered")
            XCTAssertNotEqual(forward, backward, "\(lhs) vs \(rhs) must not order both ways")
        }
    }

    func testCaseVariantsAreBothKeptInARepeatableOrder() throws {
        // APFS here is case-insensitive by default, so use names that differ by more than case.
        try write("a.pdf"); try write("A2.pdf"); try write("a10.pdf")
        let first = keys(walk())
        XCTAssertEqual(first, keys(walk()))
        XCTAssertEqual(first, ["a.pdf", "A2.pdf", "a10.pdf"])
    }

    func testPunctuationAndSpacesInNamesAreKept() throws {
        for name in ["01 - Intro.mp3", "02 – Part, one.mp3", "03 (final) .mp3"] { try write(name) }
        XCTAssertEqual(keys(walk()), ["01 - Intro.mp3", "02 – Part, one.mp3", "03 (final) .mp3"])
    }

    // MARK: Skips and placeholders

    func testHiddenFilesAndPackagesAreSkippedButIcloudPlaceholdersAreListed() throws {
        try write("keep.pdf")
        try write(".hidden.pdf")
        try write(".DS_Store")
        try write(".Report.pdf.icloud")                       // placeholder for Report.pdf
        try write("Folder.app/Contents/note.txt")             // a package: skipped whole
        try write("Plain/inside.txt")
        let result = walk()
        XCTAssertEqual(keys(result), ["keep.pdf", "Plain/inside.txt", "Report.pdf"])
        let placeholder = try XCTUnwrap(result.members.last)
        XCTAssertEqual(placeholder.availability, .notDownloaded)
        XCTAssertNil(placeholder.sha256, "A file that isn't on the device has no hash yet")
        XCTAssertEqual(result.placeholders.map(\.key), ["Report.pdf"])
        XCTAssertEqual(result.members[0].availability, .local)
    }

    func testAPlaceholderIsListedAtTheNameItWillHaveWhenDownloaded() throws {
        try write("2.pdf"); try write(".1.pdf.icloud"); try write("3.pdf")
        XCTAssertEqual(keys(walk()), ["1.pdf", "2.pdf", "3.pdf"])
    }

    func testSpokenMarginsPacketsAreNamedNotListedFileOrPackage() throws {
        try write("note.pdf")
        try write("friend.spokenmargins", "{}")
        try write("Packet.spokenmargins/manifest.json", "{}")   // a package-style packet
        try write("deep/another.SpokenMargins", "{}")
        let result = walk()
        XCTAssertEqual(keys(result), ["note.pdf"])
        XCTAssertEqual(result.packets.sorted(), ["Packet.spokenmargins", "deep/another.SpokenMargins", "friend.spokenmargins"])
    }

    // MARK: Limits

    func testDepthFourIsReadAndDepthFiveIsNot() throws {
        try write("a/b/c/d/four.txt")
        try write("a/b/c/d/e/five.txt")
        XCTAssertEqual(keys(walk()), ["a/b/c/d/four.txt"])
    }

    func testTwoHundredFilesFitAndTheTwoHundredFirstIsFlagged() throws {
        for index in 1...200 { try write(String(format: "f%03d.txt", index)) }
        var result = walk()
        XCTAssertEqual(result.members.count, 200)
        XCTAssertFalse(result.truncated)
        try write("f201.txt")
        result = walk()
        XCTAssertEqual(result.members.count, 200)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.members.last?.key, "f200.txt", "The first 200 in order are kept")
    }

    func testLinksDoNotCountTowardTheTwoHundredFiles() throws {
        try write("00 list.json", linkList("https://example.com/1", "https://example.com/2", "https://example.com/3"))
        for index in 1...200 { try write(String(format: "f%03d.txt", index)) }
        let result = walk()
        XCTAssertEqual(result.members.filter { $0.kind == .link }.count, 3)
        XCTAssertEqual(result.members.filter { $0.kind != .link }.count, 200)
        XCTAssertFalse(result.truncated)
    }

    func testEntryLimitStopsTheWalkAndSaysSo() throws {
        for index in 1...2_001 { try write(String(format: "image-%04d.png", index)) }
        let result = walk()
        XCTAssertTrue(result.entryLimitReached)
        XCTAssertEqual(result.skippedOthers, 2_000, "Entries past the limit are never looked at")
        // Exactly 2,000 entries is fine.
        try FileManager.default.removeItem(at: root.appending(path: "image-2001.png"))
        let atLimit = walk()
        XCTAssertFalse(atLimit.entryLimitReached)
        XCTAssertEqual(atLimit.skippedOthers, 2_000)
    }

    // MARK: Contents

    func testAnEmptyFolderGivesNothingAndIsNotUnreadable() {
        let result = walk()
        XCTAssertEqual(result.members, [])
        XCTAssertFalse(result.folderUnreadable)
        XCTAssertEqual(result.skippedOthers, 0)
    }

    func testImagesAndUnknownFilesAreCountedNotListed() throws {
        for name in ["a.png", "b.JPG", "c.heic", "d.docx", "noextension"] { try write(name) }
        let result = walk()
        XCTAssertEqual(result.members, [])
        XCTAssertEqual(result.skippedOthers, 5)
        XCTAssertEqual(result.problems, [])
    }

    func testAFolderThatDoesNotExistIsUnreadable() {
        let result = LibraryFolderWalk.walk(root.appending(path: "missing"))
        XCTAssertTrue(result.folderUnreadable)
        XCTAssertEqual(result.members, [])
    }

    func testEveryKindIsRecognisedByExtensionInAnyCase() throws {
        let names = ["a.pdf": LibraryFolderWalk.Kind.pdf, "b.TXT": .text, "c.text": .text, "d.md": .markdown,
                     "e.markdown": .markdown, "f.epub": .epub, "g.mp3": .audio, "h.M4A": .audio, "i.m4b": .audio,
                     "j.mp4": .audio]
        for name in names.keys { try write(name) }
        let result = walk()
        XCTAssertEqual(result.members.count, names.count)
        for member in result.members { XCTAssertEqual(member.kind, names[member.key], member.key) }
    }

    func testALinkListBecomesOneMemberPerLinkAtTheListsPlace() throws {
        try write("1 intro.pdf")
        try write("2 reading.json", linkList("https://example.com/a", "https://example.com/b"))
        try write("3 outro.pdf")
        let result = walk()
        XCTAssertEqual(keys(result), ["1 intro.pdf", "2 reading.json#001", "2 reading.json#002", "3 outro.pdf"])
        let link = result.members[1]
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.linkURL, "https://example.com/a")
        XCTAssertNil(link.sha256, "A link's identity is its address, not a hash")
        XCTAssertEqual(link.url.lastPathComponent, "2 reading.json")
    }

    func testALinkListWithABadEntryNamesItAndKeepsTheRest() throws {
        try write("list.json", #"{"schemaVersion": "\#(linkVersion)", "entries": [{"url": "https://example.com/a"}, {"url": "ftp://nope"}]}"#)
        let result = walk()
        XCTAssertEqual(keys(result), ["list.json#001"])
        XCTAssertEqual(result.problems.count, 1)
        XCTAssertEqual(result.problems.first?.key, "list.json#002")
    }

    func testAListingEditionIsAMemberWithAHash() throws {
        try write("edition.json", editionJSON)
        let result = walk()
        XCTAssertEqual(keys(result), ["edition.json"])
        XCTAssertEqual(result.members[0].kind, .edition)
        XCTAssertEqual(result.members[0].sha256, SHA256.hash(data: Data(editionJSON.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    func testOtherJSONIsNamedAsUnreadableAndDoesNotCountAsAFile() throws {
        try write("manifest.json", #"{"name": "x", "version": "1.0.0"}"#)
        try write("array.json", "[1, 2]")
        try write("broken.json", "{not json")
        try write("future.json", #"{"schemaVersion": "spoken-margins.link-list.v9", "entries": []}"#)
        let result = walk()
        XCTAssertEqual(result.members, [])
        XCTAssertEqual(result.problems.map(\.key).sorted(), ["array.json", "broken.json", "future.json", "manifest.json"])
        XCTAssertEqual(result.problems.first { $0.key == "manifest.json" }?.reason, "Not a file the app can read")
        XCTAssertTrue(result.problems.first { $0.key == "future.json" }?.reason.contains("can't read") == true)
    }

    func testAJSONIsClassifiedByContentNotName() throws {
        try write("looks-like-a-list.json", editionJSON)
        try write("looks-like-an-edition.json", linkList("https://example.com/a"))
        let result = walk()
        XCTAssertEqual(result.members.first { $0.key == "looks-like-a-list.json" }?.kind, .edition)
        XCTAssertEqual(result.members.first { $0.key == "looks-like-an-edition.json#001" }?.kind, .link)
    }

    func testAnOversizeJSONIsNotReadAndIsNamed() throws {
        let url = try write("huge.json", "{}")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(LibraryFolderWalk.maxJSONBytes) + 1)
        try handle.close()
        let result = walk()
        XCTAssertEqual(result.members, [])
        XCTAssertEqual(result.problems.map(\.key), ["huge.json"])
    }

    // MARK: Hashing

    func testTheHashMatchesTheBytesAndCoversAFileLargerThanOnePiece() throws {
        let url = root.appending(path: "big.mp3")
        let bytes = Data((0..<(3 * (1 << 20) + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: url)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let member = try XCTUnwrap(walk().members.first)
        XCTAssertEqual(member.sha256, expected)
        XCTAssertEqual(member.size, Int64(bytes.count))
    }

    func testTheSameBytesAtTwoPathsHaveTheSameHash() throws {
        try write("a/one.pdf", "same bytes"); try write("b/two.pdf", "same bytes"); try write("c/three.pdf", "other bytes")
        let hashes = walk().members.map(\.sha256)
        XCTAssertEqual(hashes[0], hashes[1])
        XCTAssertNotEqual(hashes[0], hashes[2])
    }

    func testAFileOverTheCapIsNotHashed() throws {
        for index in 1...3 { try write("f\(index).txt") }
        let result = walk(maxFiles: 2)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.members.count, 2)
        XCTAssertTrue(result.members.allSatisfy { $0.sha256 != nil })
    }
}
