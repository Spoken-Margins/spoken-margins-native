import XCTest
@testable import SessionKit

final class ListeningEditionBatchTests: XCTestCase {
    private func edition(_ title: String, text: String, summary: String = "Summary") -> ListeningEdition {
        ListeningEdition(title: title, text: text, generator: "External model", overview: "Overview",
                         scenes: [.init(title: "A", description: "Description", summary: summary, startBlock: 1, endBlock: 1)])
    }

    /// A stand-in for the store: the editions already saved, by source item ID.
    private final class Store {
        var saved: [String: ListeningEdition] = [:]
        var imported: [String] = []
        func existing(_ edition: ListeningEdition) -> ListeningEditionBatch.Existing {
            guard let previous = saved[edition.itemID] else { return .none }
            return previous == edition ? .identical : .different
        }
        func importOne(_ edition: ListeningEdition) { saved[edition.itemID] = edition; imported.append(edition.title) }
    }

    func testBatchOfValidMalformedAndConflictingFilesReportsEachAndImportsTheRest() throws {
        let store = Store()
        let kept = edition("Kept", text: "Source already in the Library")
        store.saved[kept.itemID] = kept
        let valid = edition("Fresh", text: "A fresh article")
        var conflicting = kept
        conflicting.scenes[0].summary = "A different map for the same source"
        let entries = [
            ListeningEditionBatch.Entry(id: 0, name: "fresh.json", data: try valid.encoded()),
            ListeningEditionBatch.Entry(id: 1, name: "broken.json", data: Data("not json at all".utf8)),
            ListeningEditionBatch.Entry(id: 2, name: "conflict.json", data: try conflicting.encoded()),
        ]
        let lines = ListeningEditionBatch.run(entries, existing: store.existing, importOne: store.importOne)

        XCTAssertEqual(lines[0].outcome, .imported)
        XCTAssertEqual(lines[0].message, "Imported Fresh.")
        guard case .failed = lines[1].outcome else { return XCTFail("malformed file should fail, got \(lines[1].outcome)") }
        XCTAssertTrue(lines[1].message.hasPrefix("broken.json: "), lines[1].message)
        XCTAssertEqual(lines[2].outcome, .keptExistingMap)
        XCTAssertTrue(lines[2].message.contains("already has a different map"), lines[2].message)
        // The bad file did not stop the others, and the conflicting map was not replaced.
        XCTAssertEqual(store.imported, ["Fresh"])
        XCTAssertEqual(store.saved[kept.itemID], kept)
    }

    func testIdenticalEditionIsAlreadyImportedAndIsNotImportedAgain() throws {
        let store = Store()
        let one = edition("One", text: "Same source")
        store.saved[one.itemID] = one
        let lines = ListeningEditionBatch.run([.init(id: 0, name: "one.json", data: try one.encoded())],
                                              existing: store.existing, importOne: store.importOne)
        XCTAssertEqual(lines.map(\.outcome), [.alreadyImported])
        XCTAssertTrue(store.imported.isEmpty)
        XCTAssertTrue(lines[0].outcome.isSuccess)
    }

    func testEntriesAreCheckedInOrderSoARepeatedSourceIsSeenAsAlreadyImported() throws {
        // The same file picked twice, and two different maps for one source in the same batch.
        let store = Store()
        let first = edition("Twice", text: "One source")
        var second = first
        second.scenes[0].summary = "Another map"
        let entries = [
            ListeningEditionBatch.Entry(id: 0, name: "a.json", edition: first),
            ListeningEditionBatch.Entry(id: 1, name: "b.json", edition: first),
            ListeningEditionBatch.Entry(id: 2, name: "c.json", edition: second),
        ]
        let lines = ListeningEditionBatch.run(entries, existing: store.existing, importOne: store.importOne)
        XCTAssertEqual(lines.map(\.outcome), [.imported, .alreadyImported, .keptExistingMap])
        XCTAssertEqual(store.imported, ["Twice"])
    }

    func testAFailureWhileImportingOneFileIsThatFilesLineOnly() throws {
        struct Refused: LocalizedError { var errorDescription: String? { "Pause playback before importing a map for the current item." } }
        let store = Store()
        let playing = edition("Playing", text: "Currently playing source")
        let other = edition("Other", text: "Some other source")
        let lines = ListeningEditionBatch.run(
            [.init(id: 0, name: "playing.json", edition: playing), .init(id: 1, name: "other.json", edition: other)],
            existing: store.existing,
            importOne: { if $0.title == "Playing" { throw Refused() }; store.importOne($0) })
        XCTAssertEqual(lines[0].outcome, .failed("Pause playback before importing a map for the current item."))
        XCTAssertEqual(lines[1].outcome, .imported)
        XCTAssertEqual(store.imported, ["Other"])
        // A throw while looking up the existing edition is also only that file's failure.
        struct Unreadable: Error, LocalizedError { var errorDescription: String? { "The saved edition could not be read." } }
        let lookup = ListeningEditionBatch.run(
            [.init(id: 0, name: "x.json", edition: other), .init(id: 1, name: "y.json", edition: playing)],
            existing: { if $0.title == "Other" { throw Unreadable() }; return .none }, importOne: { _ in })
        XCTAssertEqual(lookup.map(\.outcome), [.failed("The saved edition could not be read."), .imported])
    }

    func testEntryDetailShowsTitleAndSceneCountOrTheDecodeError() throws {
        let one = edition("Chapter one", text: "Body")
        XCTAssertEqual(ListeningEditionBatch.Entry(id: 0, name: "a.json", data: try one.encoded()).detail, "Chapter one · 1 scene")
        var two = one
        two.text = "Body\n\nMore body"
        two.scenes = [.init(title: "A", description: "d", summary: "s", startBlock: 1, endBlock: 1),
                      .init(title: "B", description: "d", summary: "s", startBlock: 2, endBlock: 2)]
        let valid = ListeningEditionBatch.Entry(id: 1, name: "b.json", data: try two.encoded())
        XCTAssertEqual(valid.detail, "Chapter one · 2 scenes")
        XCTAssertTrue(valid.isValid)

        // Neighbouring bad inputs all become a readable error rather than a crash or a silent skip.
        let bad: [(String, Data)] = [("empty", Data()), ("whitespace", Data(" \n\t".utf8)), ("not UTF-8", Data([0xff, 0xfe, 0x00])),
                                     ("truncated", Data(#"{"title":"x""#.utf8)), ("a Listening Map only", Data(#"{"overview":"o","scenes":[]}"#.utf8)),
                                     ("wrong version", Data(#"{"schemaVersion":"other"}"#.utf8))]
        for (name, data) in bad {
            let entry = ListeningEditionBatch.Entry(id: 9, name: "bad.json", data: data)
            XCTAssertFalse(entry.isValid, name)
            XCTAssertFalse(entry.detail.isEmpty, name)
            XCTAssertThrowsError(try ListeningEdition.decode(data), name) { XCTAssertEqual(entry.error, $0.localizedDescription, name) }
        }
        let mapOnly = ListeningEditionBatch.Entry(id: 9, name: "map.json", data: Data(#"{"overview":"o","scenes":[]}"#.utf8))
        XCTAssertTrue(mapOnly.detail.contains("Listening Map response"), mapOnly.detail)
    }

    func testAnOversizedFileIsRefusedWithTheSingleFilePathsMessage() {
        let huge = Data(repeating: 0x20, count: 8_000_001)
        let entry = ListeningEditionBatch.Entry(id: 0, name: "huge.json", data: huge)
        XCTAssertEqual(entry.error, "Listening edition exceeds 8 MB.")
    }

    func testButtonTitleCountsTheEditions() {
        XCTAssertEqual(ListeningEditionBatch.buttonTitle(count: 0), "Import Editions")
        XCTAssertEqual(ListeningEditionBatch.buttonTitle(count: 1), "Import 1 edition")
        XCTAssertEqual(ListeningEditionBatch.buttonTitle(count: 12), "Import 12 editions")
    }
}

/// #2373: the Add sheet's Files route has no results list, so a set of result lines becomes one message.
final class ListeningEditionBatchSummaryTests: XCTestCase {
    private func line(_ id: Int, _ outcome: ListeningEditionBatch.Outcome, name: String = "file.json", title: String? = nil) -> ListeningEditionBatch.Line {
        .init(id: id, name: name, title: title, outcome: outcome)
    }

    func testOneImportedEditionSaysWhatWasImported() {
        let summary = ListeningEditionBatch.summary(of: [line(0, .imported, title: "Fresh")])
        XCTAssertEqual(summary, .init(message: "Imported Fresh.", isFailure: false))
    }

    func testSeveralImportedAndAlreadyThereAreCountedAndNotAFailure() {
        let summary = ListeningEditionBatch.summary(of: [line(0, .imported), line(1, .imported), line(2, .alreadyImported)])
        XCTAssertEqual(summary, .init(message: "Imported 2 editions. 1 already in your Library.", isFailure: false))
    }

    func testANonEditionJSONFileIsAClearFailureNamingTheFile() throws {
        let entry = ListeningEditionBatch.Entry(id: 0, name: "notes.json", data: Data(#"{"hello": "world"}"#.utf8))
        let lines = ListeningEditionBatch.run([entry], existing: { _ in .none }, importOne: { _ in XCTFail("must not import") })
        let summary = ListeningEditionBatch.summary(of: lines)
        XCTAssertTrue(summary.isFailure)
        XCTAssertTrue(summary.message.hasPrefix("notes.json: "), summary.message)
    }

    func testAMixedBatchSaysHowManyWentInAndNamesTheRest() {
        let summary = ListeningEditionBatch.summary(of: [
            line(0, .imported, title: "Fresh"),
            line(1, .failed("not an edition"), name: "broken.json"),
            line(2, .keptExistingMap, title: "Kept"),
        ])
        XCTAssertTrue(summary.isFailure)
        XCTAssertTrue(summary.message.hasPrefix("Imported 1 of 3 files. "), summary.message)
        XCTAssertTrue(summary.message.contains("broken.json: not an edition"), summary.message)
        XCTAssertTrue(summary.message.contains("Kept: this source already has a different map"), summary.message)
    }

    func testSeveralFilesThatAllFailSaySoFirst() {
        let summary = ListeningEditionBatch.summary(of: [line(0, .failed("bad"), name: "a.json"), line(1, .failed("worse"), name: "b.json")])
        XCTAssertTrue(summary.isFailure)
        XCTAssertTrue(summary.message.hasPrefix("None of the 2 files could be imported as a Listening Edition."), summary.message)
    }
}
