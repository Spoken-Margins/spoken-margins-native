import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #469: a shared Margin the listener hasn't heard is new to them, until its voice first plays.
final class SharedMarginFirstHeardTests: XCTestCase {
    private let firstPlay = Date(timeIntervalSince1970: 1_800_000_000)
    private let secondPlay = Date(timeIntervalSince1970: 1_800_000_600)

    private func layer() -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func margin(_ id: String) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer", packageScopedId: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Listen to this part.",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000
        )
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "first-heard-\(UUID().uuidString).sqlite").path
    }

    private func assertHeardOnceAndKept(in repository: some ListeningSessionRepository, file: StaticString = #filePath, line: UInt = #line) throws {
        _ = try repository.importCommentaryLayer(layer(), interjections: [margin("heard"), margin("other")])
        let imported = try repository.loadImportedCommentaryInterjections(layerId: "layer")
        XCTAssertEqual(imported.map(\.firstHeardAt), [nil, nil], "unset after import", file: file, line: line)
        XCTAssertTrue(imported.allSatisfy(\.isNewToListener), file: file, line: line)

        let first = try repository.markImportedCommentaryInterjectionHeard(id: "heard", at: firstPlay)
        XCTAssertEqual(first?.firstHeardAt, firstPlay, "set on the first play", file: file, line: line)
        let second = try repository.markImportedCommentaryInterjectionHeard(id: "heard", at: secondPlay)
        XCTAssertEqual(second?.firstHeardAt, firstPlay, "a second play keeps the first time", file: file, line: line)
        XCTAssertNil(try repository.markImportedCommentaryInterjectionHeard(id: "missing", at: firstPlay), file: file, line: line)

        let stored = Dictionary(uniqueKeysWithValues: try repository.loadImportedCommentaryInterjections(layerId: "layer").map { ($0.id, $0) })
        XCTAssertEqual(stored["heard"]?.firstHeardAt, firstPlay, file: file, line: line)
        XCTAssertEqual(stored["heard"]?.isNewToListener, false, file: file, line: line)
        XCTAssertNil(stored["other"]?.firstHeardAt, "hearing one Margin leaves the others new", file: file, line: line)

        // Review on #469: the podcast anchor pass loads the records, resolves them for a while,
        // then saves its copies back. A Margin heard in between must stay heard.
        var staleCopy = imported.first { $0.id == "heard" }!
        XCTAssertNil(staleCopy.firstHeardAt)
        staleCopy.resolution = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1)
        try repository.saveImportedCommentaryInterjection(staleCopy)
        let resolved = try repository.loadImportedCommentaryInterjections(layerId: "layer").first { $0.id == "heard" }
        XCTAssertEqual(resolved?.firstHeardAt, firstPlay, "a stale save keeps the first time", file: file, line: line)
        XCTAssertEqual(resolved?.resolution.localMediaTimeMs, 1_000, "and still stores the new resolution", file: file, line: line)
    }

    func testTheInMemoryStoreRecordsTheFirstPlayOnce() throws {
        try assertHeardOnceAndKept(in: InMemorySessionRepository())
    }

    func testTheSQLiteStoreRecordsTheFirstPlayOnceAndKeepsItAcrossAReopen() throws {
        let path = temporaryDatabasePath()
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        try assertHeardOnceAndKept(in: try SQLiteSessionStore(path: path))

        let reopened = try SQLiteSessionStore(path: path)
        let stored = Dictionary(uniqueKeysWithValues: try reopened.loadImportedCommentaryInterjections(layerId: "layer").map { ($0.id, $0) })
        XCTAssertEqual(stored["heard"]?.firstHeardAt, firstPlay, "kept across a reopen")
        XCTAssertNil(stored["other"]?.firstHeardAt)
        XCTAssertEqual(try reopened.markImportedCommentaryInterjectionHeard(id: "heard", at: secondPlay)?.firstHeardAt, firstPlay)
    }

    func testMarginsImportedBeforeThisBuildReadAsNew() throws {
        // Owner data: records written before #469 have no firstHeardAt key, so every one
        // shows as new until it's heard.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try encoder.encode(margin("old"))
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("firstHeardAt"), "an unheard record keeps the old shape")
        XCTAssertTrue(try decoder.decode(ImportedCommentaryInterjection.self, from: old).isNewToListener)
    }

    func testTheItemsCopyOfAHeardMarginIsReplacedInPlace() {
        var heard = margin("heard")
        heard.firstHeardAt = firstPlay
        let records = ["layer": [margin("before"), margin("heard"), margin("after")], "other": [margin("x")]]
        let replaced = SharedMarginHearing.replacing(heard, in: records)
        XCTAssertEqual(replaced["layer"]?.map(\.id), ["before", "heard", "after"], "order is kept")
        XCTAssertEqual(replaced["layer"]?.map(\.isNewToListener), [true, false, true])
        XCTAssertEqual(replaced["other"], records["other"])
    }

    func testTheCueChimeIsAPlayableWAV() {
        // Moved out of Gate1AppModel for the hot-file ratchet; it must still be a 16-bit mono WAV.
        let data = SharedMarginCue.doubleChimeWAVData()
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data.dropFirst(8).prefix(8), as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(data.count, 44 + 2 * (3_528 + 3_528 + 4_851))
    }
}
