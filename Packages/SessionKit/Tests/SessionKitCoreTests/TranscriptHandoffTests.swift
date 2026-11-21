import Foundation
import XCTest
import ZIPFoundation
@testable import SessionKit
@testable import SessionKitPersistence
@testable import SessionKitEPUB

/// #2997 PR 5b: a transcript shared to Spoken Margins. The share extension copies the file, unread, into the App Group
/// (`TranscriptHandoffFolder.save`), and the app imports it the next time it comes forward
/// (`TranscriptHandoffDrain.run`). Everything here uses real temporary folders and a real SQLite store.
final class TranscriptHandoffFolderTests: XCTestCase {
    private var root: URL!
    private var folder: TranscriptHandoffFolder!
    private var directory: URL { root.appendingPathComponent(TranscriptHandoffFolder.directoryName) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        folder = TranscriptHandoffFolder(baseDirectory: root.appendingPathComponent("group"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The folder lives under the group folder given to it.
    private var groupDirectory: URL { root.appendingPathComponent("group").appendingPathComponent(TranscriptHandoffFolder.directoryName) }

    @discardableResult
    private func source(_ name: String, _ data: Data) throws -> URL {
        let provider = root.appendingPathComponent("provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let url = provider.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: groupDirectory.path)) ?? []).sorted()
    }

    private func refusal(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) -> TranscriptImportMessage? {
        do { try body() } catch let message as TranscriptImportMessage { return message } catch {
            XCTFail("expected a TranscriptImportMessage, got \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: Which files

    func testWhichNamesAreTranscriptFiles() {
        let yes = ["a.vtt", "A.VTT", "Budget sync.srt", "notes.Docx", "a.b.vtt", "x.txt.vtt", "dir/meeting.srt", "Réunion – équipe.vtt",
                   String(repeating: "a", count: 300) + ".vtt", "line\nbreak.vtt"]
        let no = ["a.txt", "a.md", "a.pdf", "a.json", "a.spokenmargins", "a", "", ".vtt", "vtt", "a.vtt.txt", "a.vtt ", "a.docx.zip", "a.doc"]
        for name in yes { XCTAssertTrue(TranscriptHandoffFolder.isTranscriptFile(named: name), name) }
        for name in no { XCTAssertFalse(TranscriptHandoffFolder.isTranscriptFile(named: name), name) }
        XCTAssertFalse(TranscriptHandoffFolder.isTranscriptFile(named: nil))
    }

    /// The extension can't read `TranscriptImport`, so its copy of the cap and the extensions are kept equal here.
    func testTheExtensionsCapAndTypesAreTheImportsOwn() {
        XCTAssertEqual(TranscriptHandoffFolder.maximumBytes, TranscriptImport.maximumBytes)
        XCTAssertTrue(TranscriptHandoffFolder.fileExtensions.isSubset(of: TranscriptPickImport.candidateExtensions))
        XCTAssertEqual(TranscriptPickImport.candidateExtensions.subtracting(TranscriptHandoffFolder.fileExtensions), ["txt"],
                       "only a .txt takes the text route")
    }

    // MARK: The extension's side

    func testASharedFileIsCopiedWithItsBytesAndItsOriginalName() throws {
        let bytes = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nAlice: Hello.\n".utf8)
        let id = try folder.save(from: try source("provider-name.vtt", bytes), originalName: "Budget sync.vtt")
        XCTAssertEqual(names(), ["\(id).json", "\(id).vtt"])
        let entry = try XCTUnwrap(try folder.pending().first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.fileName, "Budget sync.vtt", "the name the share gave it, not the provider's temporary name")
        XCTAssertEqual(try Data(contentsOf: entry.dataURL), bytes)
    }

    func testTheNameIsKeptAsGivenAndNeverUsedAsAPath() throws {
        for name in ["Réunion – équipe.srt", "a b  c.docx", "../../escape.vtt", "dir/inner.srt", String(repeating: "é", count: 200) + ".vtt"] {
            let id = try folder.save(from: try source("x.bin", Data("x".utf8)), originalName: name)
            let entry = try XCTUnwrap(try folder.pending().first { $0.id == id })
            XCTAssertEqual(entry.fileName, (name as NSString).lastPathComponent, name)
            XCTAssertEqual(entry.dataURL.deletingLastPathComponent().path, groupDirectory.path, name)
            XCTAssertEqual(entry.dataURL.lastPathComponent, "\(id).\((name as NSString).pathExtension.lowercased())", name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.vtt").path))
    }

    func testEveryTypeTheExtensionCopiesIsAccepted() throws {
        for name in ["a.vtt", "a.SRT", "a.docx", "a.DocX"] {
            _ = try folder.save(from: try source(name, Data("x".utf8)), originalName: name)
        }
        XCTAssertEqual(try folder.pending().count, 4)
    }

    func testOtherTypesAreRefusedAndLeaveNothing() throws {
        for name in ["a.txt", "a.md", "a.pdf", "a", "a.vtt.txt", ".vtt"] {
            let message = refusal { try folder.save(from: try source("x.bin", Data("x".utf8)), originalName: name) }
            XCTAssertEqual(message?.kind, .unsupportedType, name)
        }
        XCTAssertEqual(names(), [])
    }

    func testAFileOverTheCapIsRefusedWithTheSizeSentenceAndTheFileJustUnderIsKept() throws {
        let over = try source("huge.vtt", Data(repeating: UInt8(ascii: "a"), count: TranscriptHandoffFolder.maximumBytes + 1))
        let message = try XCTUnwrap(refusal { try folder.save(from: over, originalName: "Quarterly all hands.vtt") })
        XCTAssertEqual(message.kind, .tooLarge)
        XCTAssertEqual(message.errorDescription, "\u{201C}Quarterly all hands.vtt\u{201D} is larger than 10 MB, so nothing was added.")
        XCTAssertEqual(names(), [], "nothing, not even a half copy, is left")

        let exactly = try source("edge.vtt", Data(repeating: UInt8(ascii: "a"), count: TranscriptHandoffFolder.maximumBytes))
        XCTAssertNoThrow(try folder.save(from: exactly, originalName: "edge.vtt"))
        XCTAssertEqual(try folder.pending().count, 1)
    }

    func testAFileThatIsNotThereIsRefusedAsUnreadableAndLeavesNothing() throws {
        let gone = root.appendingPathComponent("never-written.vtt")
        let message = refusal { try folder.save(from: gone, originalName: "gone.vtt") }
        XCTAssertEqual(message?.kind, .couldNotRead)
        XCTAssertEqual(names().filter { $0 != "." }, [])
        let directoryShared = try source("dir.vtt", Data())
        try FileManager.default.removeItem(at: directoryShared)
        try FileManager.default.createDirectory(at: directoryShared, withIntermediateDirectories: true)
        XCTAssertEqual(refusal { try folder.save(from: directoryShared, originalName: "dir.vtt") }?.kind, .couldNotRead, "a folder is not a file")
    }

    func testTheSizeSentenceReachesTheListenerUnchanged() {
        let message = TranscriptImportMessage(.tooLarge, fileName: "a.vtt")
        XCTAssertEqual(ListenerErrorText.message(for: message), message.errorDescription)
    }

    // MARK: The app's side

    func testEntriesComeOldestFirst() throws {
        var ids: [String] = []
        for name in ["first.vtt", "second.srt", "third.docx"] {
            ids.append(try folder.save(from: try source(name, Data("x".utf8)), originalName: name))
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(try folder.pending().map(\.id), ids)
    }

    func testAnEmptyOrMissingFolderHasNothing() throws {
        XCTAssertEqual(try folder.pending(), [])
        XCTAssertEqual(folder.sweepOrphans(), 0)
    }

    func testDeletingAnEntryRemovesItsBytesAndRecordAndIsSafeTwice() throws {
        _ = try folder.save(from: try source("keep.vtt", Data("x".utf8)), originalName: "keep.vtt")
        _ = try folder.save(from: try source("drop.srt", Data("x".utf8)), originalName: "drop.srt")
        let entries = try folder.pending()
        let drop = try XCTUnwrap(entries.first { $0.fileName == "drop.srt" })
        folder.delete(drop)
        folder.delete(drop)
        XCTAssertEqual(try folder.pending().map(\.fileName), ["keep.vtt"])
        XCTAssertEqual(names().count, 2)
    }

    // MARK: A kill in the middle

    /// A kill between the two writes leaves bytes with no record: never drained, swept an hour later.
    func testBytesWithNoRecordAreNotPendingAndAreSweptAfterAnHour() throws {
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        let orphan = groupDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).vtt")
        let staged = groupDirectory.appendingPathComponent(".\(UUID().uuidString.lowercased()).staged")
        try Data("half".utf8).write(to: orphan)
        try Data("half".utf8).write(to: staged)
        _ = try folder.save(from: try source("whole.srt", Data("x".utf8)), originalName: "whole.srt")

        XCTAssertEqual(try folder.pending().map(\.fileName), ["whole.srt"])
        XCTAssertEqual(folder.sweepOrphans(now: Date()), 0, "a share in progress is not an orphan")
        XCTAssertEqual(folder.sweepOrphans(now: Date().addingTimeInterval(TranscriptHandoffFolder.orphanLifetime + 60)), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try folder.pending().map(\.fileName), ["whole.srt"], "the complete entry is never swept")
        XCTAssertEqual(folder.sweepOrphans(now: Date().addingTimeInterval(86_400 * 30)), 0, "its bytes have a record beside them")
    }

    /// A copy keeps the source's modification date. A transcript last saved two days ago must not look abandoned to the sweep
    /// while the extension is still between its copy and its record.
    func testAFileWithAnOldModificationDateIsNotSweptWhileItsShareIsInProgress() throws {
        let old = try source("last-week.vtt", Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: old.path)
        let id = try folder.save(from: old, originalName: "last-week.vtt")
        let bytes = groupDirectory.appendingPathComponent("\(id).vtt")
        let record = groupDirectory.appendingPathComponent("\(id).json")
        try FileManager.default.removeItem(at: record) // the extension has not written its record yet
        XCTAssertEqual(folder.sweepOrphans(now: Date().addingTimeInterval(120)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bytes.path))
    }

    func testARecordWhoseBytesAreGoneIsDroppedAndARecordThisBuildCannotReadIsLeftAlone() throws {
        let id = try folder.save(from: try source("gone.vtt", Data("x".utf8)), originalName: "gone.vtt")
        try FileManager.default.removeItem(at: groupDirectory.appendingPathComponent("\(id).vtt"))
        let future = groupDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try Data(#"{"schema":"a-later-build"}"#.utf8).write(to: future)
        let mismatched = groupDirectory.appendingPathComponent("someone-else.json")
        try Data(#"{"id":"another","fileName":"a.vtt","savedAt":0}"#.utf8).write(to: mismatched)

        XCTAssertEqual(try folder.pending(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupDirectory.appendingPathComponent("\(id).json").path), "dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: future.path), "left for a later build")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatched.path))
    }
}

final class TranscriptHandoffDrainTests: XCTestCase {
    private var root: URL!
    private var path: String!
    private var store: SQLiteSessionStore!
    private var folder: TranscriptHandoffFolder!
    private let utc = TimeZone(identifier: "UTC")!
    private let docx: @Sendable (Data) throws -> String = { try DocxPlainText.text(from: $0) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-drain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: path)
        folder = TranscriptHandoffFolder(baseDirectory: root.appendingPathComponent("group"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func share(_ name: String, _ data: Data) throws -> String {
        let provider = root.appendingPathComponent("provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let url = provider.appendingPathComponent(name)
        try data.write(to: url)
        return try folder.save(from: url, originalName: name)
    }

    @discardableResult
    private func share(_ name: String, _ text: String) throws -> String { try share(name, Data(text.utf8)) }

    private func drain(
        folder: TranscriptHandoffFolder? = nil, store: SQLiteSessionStore? = nil, now: Date = Date(timeIntervalSince1970: 1_000),
        stillListening: Set<String> = []
    ) async -> TranscriptHandoffDrain.Report {
        await TranscriptHandoffDrain.run(
            folder: folder ?? self.folder, store: store ?? self.store, docxText: docx, now: now,
            stillListeningItemIds: stillListening, timeZone: utc)
    }

    private func itemCount() throws -> Int { try StoreRawSQL.ids(kind: "item", at: path).count }

    private func waiting() throws -> Int { try folder.pending().count }

    private func wordDocument(_ paragraphs: [String]) throws -> Data {
        let body = paragraphs.map { paragraph in
            let runs = paragraph.components(separatedBy: "\t").map { "<w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r>" }
            return "<w:p>" + runs.joined(separator: "<w:r><w:tab/></w:r>") + "</w:p>"
        }.joined()
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """.utf8)
        let url = root.appendingPathComponent("word-\(UUID().uuidString).docx")
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(xml.count)) { position, size in
            xml.subdata(in: Int(position)..<Int(position) + size)
        }
        return try Data(contentsOf: url)
    }

    private let teamsParagraphs = [
        "Budget sync-20260304_100000-Meeting Recording", "March 4, 2026, 10:00AM", "",
        "Alice Example\t0 minutes 3 seconds", "Welcome everyone, let's start with the budget.",
        "Ben Sample\t0 minutes 6 seconds", "Thanks. I have the draft numbers ready.",
    ]

    /// Different words from every fixture (which all say the same thing), so it is its own item.
    private let otherMeeting = """
    WEBVTT

    00:00:02.000 --> 00:00:05.000
    Carol Other: Let's review the hiring plan.

    00:00:05.500 --> 00:00:08.000
    Dev Another: Two roles are open this quarter.
    """

    // MARK: Every type

    func testEachTypeTheExtensionCopiesBecomesATranscriptItemWithItsTimes() async throws {
        let docxBytes = try wordDocument(teamsParagraphs)
        let cases: [(name: String, data: Data)] = [
            ("teams.vtt", Data(TranscriptFixtures.all["teams.vtt"]!.utf8)),
            ("generic.srt", Data(TranscriptFixtures.all["generic.srt"]!.utf8)),
            ("Budget sync.docx", docxBytes),
        ]
        for (name, data) in cases {
            // A store and a folder of their own per file: the fixtures say the same words, so in one store they'd be one item.
            let fileStore = try SQLiteSessionStore(path: root.appendingPathComponent("\(name).sqlite").path)
            let fileFolder = TranscriptHandoffFolder(baseDirectory: root.appendingPathComponent("group-\(name)"))
            let provider = root.appendingPathComponent("p-\(name)")
            try data.write(to: provider)
            try fileFolder.save(from: provider, originalName: name)

            let report = await drain(folder: fileFolder, store: fileStore)
            XCTAssertEqual(report.added.count, 1, name)
            XCTAssertEqual(report.refusals, [], name)
            XCTAssertEqual(report.keptForRetry, 0, name)
            let added = try XCTUnwrap(report.added.first, name)
            XCTAssertEqual(added.fileName, name)
            let item = try fileStore.loadItem(id: added.itemId)
            XCTAssertEqual(item.externalReferenceType, TranscriptItemText.referenceType, name)
            XCTAssertEqual(item.externalReference, name, "the shared name, not a temporary one")
            let times = try XCTUnwrap(try fileStore.loadTranscriptTimes(itemId: added.itemId), name)
            XCTAssertFalse(times.cueStartMs.isEmpty, name)
            XCTAssertEqual(try fileFolder.pending(), [], "the entry is gone once it has an answer: \(name)")
        }
    }

    /// Open In, Files, Quick Folder and the share sheet all call the one import: the same bytes are one item, whichever way in.
    func testTheSameBytesThroughTheShareSheetAndFilesAreOneItem() async throws {
        let text = TranscriptFixtures.all["zoom.vtt"]!
        let fromFile = try await TranscriptLibraryImport.importFile(
            name: "zoom.vtt", data: Data(text.utf8), store: store, docxText: docx, timeZone: utc)
        guard case .added(let fileId, _, false) = fromFile else { return XCTFail("\(fromFile)") }
        try share("zoom.vtt", text)
        let report = await drain()
        XCTAssertEqual(report.added.map(\.itemId), [fileId])
        XCTAssertEqual(report.added.first?.readded, true, "already there, so it is added again")
        XCTAssertEqual(try itemCount(), 1)
    }

    // MARK: Refusals

    func testARefusedFileIsRemovedAndReportedWithItsOwnSentence() async throws {
        try share("empty.vtt", "")
        try share("no-cues.vtt", "WEBVTT\n\nNOTE nothing was said here\n")
        try share("prose.docx", try wordDocument(["Minutes", "", "We agreed to meet again.", "Nothing here is a transcript."]))
        try share("broken.docx", "this is not a zip file")

        let report = await drain()
        XCTAssertEqual(report.added, [])
        XCTAssertEqual(report.refusals.map(\.kind), [.empty, .noTimedLines, .docxNotATranscript, .docxUnreadable])
        XCTAssertEqual(report.refusals.map(\.fileName), ["empty.vtt", "no-cues.vtt", "prose.docx", "broken.docx"])
        XCTAssertEqual(report.keptForRetry, 0)
        XCTAssertEqual(try waiting(), 0, "a refusal is an answer: nothing is retried forever")
        XCTAssertEqual(try itemCount(), 0)
    }

    func testOneRefusalDoesNotStopTheFilesAfterIt() async throws {
        try share("empty.vtt", "")
        try share("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let report = await drain()
        XCTAssertEqual(report.refusals.map(\.kind), [.empty])
        XCTAssertEqual(report.added.count, 1)
        XCTAssertEqual(try itemCount(), 1)
    }

    func testAFileWhoseBytesCannotBeReadIsRefusedAndRemoved() async throws {
        try share("a.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let entry = try XCTUnwrap(try folder.pending().first)
        try FileManager.default.removeItem(at: entry.dataURL)
        try FileManager.default.createDirectory(at: entry.dataURL, withIntermediateDirectories: false)
        let report = await drain()
        XCTAssertEqual(report.refusals.map(\.kind), [.couldNotRead])
        XCTAssertEqual(try waiting(), 0)
    }

    // MARK: Twice, in order, and killed

    func testDrainingTwiceImportsOnce() async throws {
        try share("teams.vtt", TranscriptFixtures.all["teams.vtt"]!)
        let first = await drain()
        let second = await drain()
        XCTAssertEqual(first.added.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try StoreRawSQL.ids(kind: TranscriptTimes.recordKind, at: path).count, 1)
    }

    func testTwoDrainsAtOnceImportEachFileOnce() async throws {
        try share("teams.vtt", TranscriptFixtures.all["teams.vtt"]!)
        try share("hiring.vtt", otherMeeting)
        let store = self.store!, folder = self.folder!, zone = utc, docx = self.docx
        let reports = await withTaskGroup(of: TranscriptHandoffDrain.Report.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    await TranscriptHandoffDrain.run(folder: folder, store: store, docxText: docx, timeZone: zone)
                }
            }
            var all: [TranscriptHandoffDrain.Report] = []
            for await report in group { all.append(report) }
            return all
        }
        XCTAssertEqual(try itemCount(), 2, "two files, two items, however the drains interleave")
        XCTAssertEqual(try waiting(), 0)
        XCTAssertEqual(Set(reports.flatMap(\.added).map(\.itemId)).count, 2)
    }

    func testTwoSharesOfTheSameWordsInOneDrainAreListedOnce() async throws {
        try share("meeting.srt", TranscriptFixtures.all["generic.srt"]!)
        try share("meeting copy.srt", TranscriptFixtures.all["generic.srt"]!)
        let report = await drain()
        XCTAssertEqual(report.added.count, 1, "the id comes from the words, so the banner counts one")
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try waiting(), 0)
    }

    /// `relaunch`: the app is killed after the extension saved and before it drained. The next launch, a new process with
    /// a new store over the same files, imports it exactly once.
    func testAShareWaitingWhenTheAppWasKilledIsImportedOnceAtTheNextLaunch() async throws {
        try share("teams.vtt", TranscriptFixtures.all["teams.vtt"]!)
        store = nil
        let relaunchedFolder = TranscriptHandoffFolder(baseDirectory: root.appendingPathComponent("group"))
        let relaunchedStore = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try relaunchedFolder.pending().count, 1)
        let first = await drain(folder: relaunchedFolder, store: relaunchedStore)
        let second = await drain(folder: relaunchedFolder, store: try SQLiteSessionStore(path: path))
        XCTAssertEqual(first.added.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertNotNil(try relaunchedStore.loadTranscriptTimes(itemId: try XCTUnwrap(first.added.first).itemId))
    }

    /// A kill between the import and the removal: the next drain imports the same file again, and the id (from the words)
    /// makes that the same item, so nothing doubles.
    func testAKillBetweenTheImportAndTheRemovalDoesNotDoubleTheItem() async throws {
        try share("teams.vtt", TranscriptFixtures.all["teams.vtt"]!)
        let entry = try XCTUnwrap(try folder.pending().first)
        let outcome = try await TranscriptLibraryImport.importFile(
            name: entry.fileName, data: try Data(contentsOf: entry.dataURL), store: store, docxText: docx, timeZone: utc)
        guard case .added(let firstId, _, false) = outcome else { return XCTFail("\(outcome)") }
        // ...killed here: the entry is still in the folder.
        let report = await drain()
        XCTAssertEqual(report.added.map(\.itemId), [firstId])
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try waiting(), 0)
    }

    /// A kill between the extension's two writes leaves bytes and no record, which the drain never imports.
    func testAShareKilledHalfWayIsNeverImported() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("group/\(TranscriptHandoffFolder.directoryName)"), withIntermediateDirectories: true)
        let orphan = root.appendingPathComponent("group/\(TranscriptHandoffFolder.directoryName)/\(UUID().uuidString.lowercased()).vtt")
        try Data(TranscriptFixtures.all["zoom.vtt"]!.utf8).write(to: orphan)
        let report = await drain()
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try itemCount(), 0)
        let late = await drain(now: Date().addingTimeInterval(TranscriptHandoffFolder.orphanLifetime + 60))
        XCTAssertTrue(late.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "swept once it is clearly abandoned")
    }

    // MARK: A store that cannot save

    /// A store that throws is not an answer: the file and the ones after it wait for the next drain, and nothing is lost.
    func testAStoreThatCannotSaveKeepsTheFilesForTheNextDrain() async throws {
        try share("teams.vtt", TranscriptFixtures.all["teams.vtt"]!)
        try share("hiring.vtt", otherMeeting)
        try StoreRawSQL.execute("""
            CREATE TRIGGER refuse_times BEFORE INSERT ON records WHEN NEW.kind = '\(TranscriptTimes.recordKind)'
            BEGIN SELECT RAISE(ABORT, 'times refused'); END;
            """, at: path)

        let failed = await drain()
        XCTAssertEqual(failed.added, [])
        XCTAssertEqual(failed.refusals, [])
        XCTAssertEqual(failed.keptForRetry, 2)
        XCTAssertNotNil(failed.storeError)
        XCTAssertEqual(try waiting(), 2)
        XCTAssertEqual(try itemCount(), 0)

        try StoreRawSQL.execute("DROP TRIGGER refuse_times;", at: path)
        let retried = await drain()
        XCTAssertEqual(retried.added.count, 2)
        XCTAssertNil(retried.storeError)
        XCTAssertEqual(try waiting(), 0)
        XCTAssertEqual(try itemCount(), 2)
    }

    // MARK: Starting states

    /// `first-run`: an empty store and a share waiting before the app ever opened it.
    func testAFirstRunStoreGetsTheItemItsTimesAndTheListeningStatus() async throws {
        try share("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        XCTAssertEqual(try itemCount(), 0)
        let report = await drain()
        let added = try XCTUnwrap(report.added.first)
        XCTAssertFalse(added.readded)
        XCTAssertEqual(try store.loadItem(id: added.itemId).status, "needs_listening_map")
        XCTAssertNotNil(try store.loadTranscriptTimes(itemId: added.itemId))
    }

    /// `returning`: an ordinary text item with the same file name is untouched; the transcript is a new row.
    func testAnOrdinaryItemWithTheSameFileNameIsUntouched() async throws {
        let plain = Item(id: "plain", title: "zoom.vtt", mediaType: "text", text: "Typed by hand.", externalReference: "zoom.vtt",
                         status: "needs_listening_map", createdAt: Date(timeIntervalSince1970: 10))
        try store.saveItem(plain)
        try share("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!)
        let report = await drain()
        XCTAssertEqual(report.added.count, 1)
        XCTAssertNotEqual(report.added.first?.itemId, "plain")
        XCTAssertEqual(try store.loadItem(id: "plain"), plain)
        XCTAssertEqual(try itemCount(), 2)
    }

    /// `finished`: the same transcript shared again after it was heard to the end is added again, unfinished (#4178).
    func testSharingAFinishedTranscriptAgainAddsItAgainUnfinished() async throws {
        let text = TranscriptFixtures.all["webex.vtt"]!
        try share("webex.vtt", text)
        let firstReport = await drain(now: Date(timeIntervalSince1970: 1_000))
        let first = try XCTUnwrap(firstReport.added.first)
        var item = try store.loadItem(id: first.itemId)
        item.sourceCompletedAt = Date(timeIntervalSince1970: 2_000)
        try store.saveItem(item)

        try share("webex.vtt", text)
        let againReport = await drain(now: Date(timeIntervalSince1970: 9_000))
        let again = try XCTUnwrap(againReport.added.first)
        XCTAssertEqual(again.itemId, first.itemId)
        XCTAssertTrue(again.readded)
        XCTAssertEqual(try itemCount(), 1)
        let stored = try store.loadItem(id: first.itemId)
        XCTAssertNil(stored.sourceCompletedAt)
        XCTAssertEqual(stored.addedAgainAt, Date(timeIntervalSince1970: 9_000))
    }

    /// `burst`: ten shares of the same file at once, as a double tap or several friends sending it, are one item.
    func testABurstOfTheSameFileIsOneItem() async throws {
        for _ in 0..<10 { try share("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!) }
        let report = await drain()
        XCTAssertEqual(report.added.count, 1)
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try waiting(), 0)
    }

    /// `long-source`: a ten-thousand-cue meeting copied and drained.
    func testATenThousandCueShareImportsQuickly() async throws {
        var lines = ["WEBVTT", ""]
        for index in 0..<10_000 {
            let seconds = index * 1
            let stamp = String(format: "%02d:%02d:%02d.000", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            let endStamp = String(format: "%02d:%02d:%02d.500", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            lines += ["\(stamp) --> \(endStamp)", "Speaker \(index % 4): Sentence number \(index) of the meeting.", ""]
        }
        try share("long.vtt", lines.joined(separator: "\n"))
        let started = Date()
        let report = await drain()
        XCTAssertEqual(report.added.count, 1)
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 0.5 s on a Mac in a debug build (2026-11-20); the ceiling is at
        // least 5x that and guards work per cue that grows with the number of cues.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

/// A shared `.txt` is asked, at drain, whether it is a transcript; only a text file from the share sheet is.
final class SharedTextFileTranscriptTests: XCTestCase {
    private func handoff(_ mode: BrowserTextCaptureMode = .plainTextFile, url: String, text: String = "words") -> BrowserTextHandoff {
        BrowserTextHandoff(captureMode: mode, source: BrowserTextSource(url: url, title: "t"), text: text)
    }

    private func encoded(_ name: String) -> String {
        SharedTextFileTranscript.sourcePrefix + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
    }

    func testTheFileNameComesBackDecodedFromTheSourceTheExtensionWrites() {
        for name in ["zoom.txt", "Budget sync.txt", "Réunion – équipe.txt", "100% done #1 ?.txt", "A.TXT", "a.b.txt"] {
            XCTAssertEqual(SharedTextFileTranscript.fileName(for: handoff(url: encoded(name))), name, name)
        }
    }

    func testOnlyATextFileFromTheShareSheetIsAsked() {
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(.markdownFile, url: encoded("notes.txt"))), "Markdown keeps today's import")
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(.readablePage, url: "https://example.com/a.txt")))
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(.selectedText, url: "shared-text://share-sheet")), "shared text is never asked")
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(url: SharedTextIntake.sourceURL)))
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(url: encoded("notes.md"))))
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(url: encoded("noextension"))))
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(url: SharedTextFileTranscript.sourcePrefix)))
    }

    func testAFileOverTheCapIsNotAskedAsInAPickFromFiles() {
        let atCap = String(repeating: "a", count: TranscriptImport.maximumBytes)
        XCTAssertNotNil(SharedTextFileTranscript.fileName(for: handoff(url: encoded("big.txt"), text: atCap)))
        XCTAssertNil(SharedTextFileTranscript.fileName(for: handoff(url: encoded("big.txt"), text: atCap + "a")))
    }

    /// What the extension writes and what the app decides, end to end on the text: a transcript is one, prose is not.
    func testATranscriptTextIsATranscriptAndProseIsNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-txt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let utc = TimeZone(identifier: "UTC")!

        let zoom = handoff(url: encoded("zoom.txt"), text: TranscriptFixtures.all["zoom-captions.txt"]!)
        let name = try XCTUnwrap(SharedTextFileTranscript.fileName(for: zoom))
        let outcome = try await TranscriptLibraryImport.importText(name: name, text: zoom.text, store: store, timeZone: utc)
        guard case .added(let id, _, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try store.loadItem(id: id).externalReference, "zoom.txt")

        let essay = handoff(url: encoded("essay.txt"), text: "A short essay about nothing in particular.\n\nIt has two paragraphs.")
        let essayName = try XCTUnwrap(SharedTextFileTranscript.fileName(for: essay))
        let essayOutcome = try await TranscriptLibraryImport.importText(name: essayName, text: essay.text, store: store, timeZone: utc)
        XCTAssertEqual(essayOutcome, .notTranscript(text: essay.text), "today's text import takes it")
    }
}
