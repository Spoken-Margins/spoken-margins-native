import XCTest
@testable import SessionKit

/// #3217: one Import from Files tile, and the file's type picks the import.
final class AddFromFilesPlanTests: XCTestCase {
    private func plan(_ names: [String], folders: Set<String> = []) -> AddFromFilesPlan {
        let urls = names.map { URL(fileURLWithPath: "/tmp/picked/\($0)") }
        return AddFromFilesPlan(picking: urls) { folders.contains($0.lastPathComponent) }
    }

    func testEachFileTypeTakesItsOwnRoute() {
        let result = plan(["talk.spokenmargins", "book.m4b", "essay.pdf", "novel.epub", "notes.md", "plain.txt", "pack.json"])
        XCTAssertEqual(result.packets.map(\.lastPathComponent), ["talk.spokenmargins"])
        XCTAssertEqual(result.audio.map(\.lastPathComponent), ["book.m4b"])
        XCTAssertEqual(result.collections.map(\.lastPathComponent), ["pack.json"])
        XCTAssertEqual(result.documents.map(\.lastPathComponent), ["essay.pdf", "novel.epub", "notes.md", "plain.txt"])
        XCTAssertTrue(result.folders.isEmpty)
    }

    func testEveryAudioTypeTheOldAudiobookTileAllowedStillRoutesToAudio() {
        let result = plan(["a.mp3", "b.m4a", "c.m4b", "d.mp4"])
        XCTAssertEqual(result.audio.count, 4)
        XCTAssertTrue(result.documents.isEmpty)
    }

    func testTheExtensionIsReadWithoutRegardToCase() {
        let result = plan(["SHARED.SpokenMargins", "BOOK.M4B", "Song.MP3", "EDITION.JSON", "Paper.PDF"])
        XCTAssertEqual(result.packets.count, 1)
        XCTAssertEqual(result.audio.count, 2)
        XCTAssertEqual(result.collections.count, 1)
        XCTAssertEqual(result.documents.count, 1)
    }

    func testOnlyTheLastExtensionCounts() {
        let result = plan(["notes.mp3.txt", "chapter.spokenmargins.pdf", "export.json.md", "a.b.m4a"])
        XCTAssertEqual(result.documents.map(\.lastPathComponent), ["notes.mp3.txt", "chapter.spokenmargins.pdf", "export.json.md"])
        XCTAssertEqual(result.audio.map(\.lastPathComponent), ["a.b.m4a"])
        XCTAssertTrue(result.packets.isEmpty)
        XCTAssertTrue(result.collections.isEmpty)
    }

    func testAFileWithNoExtensionOrAnUnknownOneStaysADocumentSoTheOldImporterAnswersIt() {
        let result = plan(["README", "weird.xyz", ".hidden", "trailingdot."])
        XCTAssertEqual(result.documents.count, 4)
        XCTAssertTrue(result.audio.isEmpty)
        XCTAssertTrue(result.packets.isEmpty)
    }

    func testAFolderWinsOverItsName() {
        let result = plan(["Editions", "tunes.mp3", "Book.spokenmargins"], folders: ["Editions", "Book.spokenmargins"])
        XCTAssertEqual(result.folders.map(\.lastPathComponent), ["Editions", "Book.spokenmargins"])
        XCTAssertEqual(result.audio.map(\.lastPathComponent), ["tunes.mp3"])
        XCTAssertTrue(result.packets.isEmpty)
    }

    func testAMixedPickKeepsTheOrderPickedInsideEachGroup() {
        let result = plan(["b.pdf", "x.mp3", "a.pdf", "y.mp3", "c.json"])
        XCTAssertEqual(result.documents.map(\.lastPathComponent), ["b.pdf", "a.pdf"])
        XCTAssertEqual(result.audio.map(\.lastPathComponent), ["x.mp3", "y.mp3"])
        XCTAssertEqual(result.documentsAndCollections.map(\.lastPathComponent), ["b.pdf", "a.pdf", "c.json"])
    }

    func testNothingPickedIsEmpty() {
        XCTAssertTrue(plan([]).isEmpty)
        XCTAssertFalse(plan(["a.pdf"]).isEmpty)
        XCTAssertEqual(plan([]).documentsAndCollections, [])
    }

    func testThePacketExtensionIsTheOneThePacketArchiveWrites() {
        XCTAssertEqual(AddFromFilesPlan.packetExtension, "spokenmargins")
    }
}
