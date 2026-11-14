import Foundation
import XCTest
import ZIPFoundation
@testable import SessionKit
@testable import SessionKitPersistence
@testable import SessionKitEPUB

/// #2997 PR 3: a transcript file becomes a Library item and a `transcript_times` record on a real SQLite store, in one
/// transaction, with the same id for the same bytes. Nothing here fakes the store: the rows are read back with plain SQL.
final class TranscriptLibraryImportTests: XCTestCase {
    private var root: URL!
    private var path: String!
    private var store: SQLiteSessionStore!
    private let utc = TimeZone(identifier: "UTC")!
    private let docx: @Sendable (Data) throws -> String = { try DocxPlainText.text(from: $0) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = root.appendingPathComponent("library.sqlite").path
        store = try SQLiteSessionStore(path: path)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func importFile(_ name: String, _ text: String, now: Date = Date(timeIntervalSince1970: 1_000), stillListening: Set<String> = []) async throws -> TranscriptLibraryImport.Outcome {
        try await TranscriptLibraryImport.importFile(
            name: name, data: Data(text.utf8), store: store, docxText: docx, now: now,
            stillListeningItemIds: stillListening, timeZone: utc)
    }

    private func added(_ outcome: TranscriptLibraryImport.Outcome, file: StaticString = #filePath, line: UInt = #line) throws -> (id: String, title: String, readded: Bool) {
        guard case .added(let id, let title, let readded) = outcome else {
            XCTFail("expected an added item, got \(outcome)", file: file, line: line)
            throw CancellationError()
        }
        return (id, title, readded)
    }

    private func itemCount() throws -> Int {
        try StoreRawSQL.ids(kind: "item", at: path).count
    }

    // MARK: Every format

    func testEveryFixtureImportsAsATranscriptItemWithItsTimes() async throws {
        for (name, text) in TranscriptFixtures.all.sorted(by: { $0.key < $1.key }) {
            // A store of its own per file: the fixtures all say the same words, so in one store they are one item.
            let fixtureStore = try SQLiteSessionStore(path: root.appendingPathComponent("\(name).sqlite").path)
            let result = try added(try await TranscriptLibraryImport.importFile(
                name: name, data: Data(text.utf8), store: fixtureStore, docxText: docx, now: Date(timeIntervalSince1970: 1_000), timeZone: utc))
            XCTAssertFalse(result.readded, name)
            XCTAssertTrue(result.id.hasPrefix("item-transcript-"), name)
            XCTAssertEqual(result.id.count, "item-transcript-".count + 24, name)

            let item = try fixtureStore.loadItem(id: result.id)
            XCTAssertEqual(item.mediaType, "text", name)
            XCTAssertEqual(item.externalReferenceType, TranscriptItemText.referenceType, name)
            XCTAssertEqual(item.externalReference, name, name)
            XCTAssertEqual(item.status, "needs_listening_map", name)
            XCTAssertFalse((item.text ?? "").isEmpty, name)
            XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_000), name)

            let times = try XCTUnwrap(try fixtureStore.loadTranscriptTimes(itemId: result.id), name)
            XCTAssertEqual(times.itemId, result.id, name)
            XCTAssertEqual(times.cueStartChars.count, 3, name)
            XCTAssertEqual(times.cueStartMs.count, 3, name)
            XCTAssertEqual(times.cueStartChars, times.cueStartChars.sorted(), name)
            XCTAssertEqual(times.summary.speakers.first, "Alice Example", name)
            XCTAssertEqual(times.clockMs(atCharacter: 0), times.cueStartMs.first, name)
        }
    }

    /// The same words in another layout (an .srt and a .vtt of one meeting) are one item: the id comes from the text.
    func testTheSameWordsInAnotherLayoutAreTheSameItemWithTheNewTimes() async throws {
        let first = try added(try await importFile("generic.srt", TranscriptFixtures.all["generic.srt"]!))
        let second = try added(try await importFile("meet.txt", TranscriptFixtures.all["meet.txt"]!))
        XCTAssertEqual(second.id, first.id)
        XCTAssertTrue(second.readded)
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try store.loadItem(id: first.id).externalReference, "generic.srt", "the first import's name is kept")
        XCTAssertEqual(try store.loadTranscriptTimes(itemId: first.id)?.cueStartMs, [3_000, 6_000, 9_000], "the new file's times")
    }

    func testTheStoredTimesCarryNoCueText() async throws {
        let result = try added(try await importFile("generic.srt", TranscriptFixtures.all["generic.srt"]!))
        let payload = try XCTUnwrap(try StoreRawSQL.rows(
            "SELECT payload FROM records WHERE kind = ? AND id = ?;", bindings: [TranscriptTimes.recordKind, result.id], at: path).first?.first ?? nil)
        for words in ["budget", "draft numbers", "share them"] {
            XCTAssertFalse(payload.contains(words), "the times record must not copy what was said: \(words)")
        }
        let row = try XCTUnwrap(try StoreRawSQL.rows(
            "SELECT item_id, session_id FROM records WHERE kind = ? AND id = ?;", bindings: [TranscriptTimes.recordKind, result.id], at: path).first)
        XCTAssertEqual(row[0], result.id, "scoped to its item, so deleting the item deletes the times")
        XCTAssertNil(row[1])
    }

    func testAWordFileGivesTheSameItemAsItsPlainText() async throws {
        let paragraphs = [
            "Budget sync-20260304_100000-Meeting Recording", "March 4, 2026, 10:00AM", "",
            "Alice Example\t0 minutes 3 seconds", "Welcome everyone, let's start with the budget.",
            "Ben Sample\t0 minutes 6 seconds", "Thanks. I have the draft numbers ready.",
        ]
        let body = paragraphs.map { paragraph in
            let runs = paragraph.components(separatedBy: "\t").map { "<w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r>" }
            return "<w:p>" + runs.joined(separator: "<w:r><w:tab/></w:r>") + "</w:p>"
        }.joined()
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """.utf8)
        let url = root.appendingPathComponent("meeting.docx")
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "word/document.xml", type: .file, uncompressedSize: Int64(xml.count)) { position, size in
            xml.subdata(in: Int(position)..<Int(position) + size)
        }
        let data = try Data(contentsOf: url)
        let outcome = try await TranscriptLibraryImport.importFile(
            name: "meeting.docx", data: data, store: store, docxText: docx, now: Date(), timeZone: utc)
        let first = try added(outcome)
        let item = try store.loadItem(id: first.id)
        XCTAssertEqual(item.externalReference, "meeting.docx")
        XCTAssertEqual(try store.loadTranscriptTimes(itemId: first.id)?.summary.speakers, ["Alice Example", "Ben Sample"])
        XCTAssertEqual(try store.loadTranscriptTimes(itemId: first.id)?.cueStartMs, [3_000, 6_000])

        // The same bytes again are the same item, whatever the route.
        let again = try added(try await TranscriptLibraryImport.importFile(
            name: "meeting.docx", data: data, store: store, docxText: docx, now: Date(), timeZone: utc))
        XCTAssertEqual(again.id, first.id)
        XCTAssertTrue(again.readded)
        XCTAssertEqual(try itemCount(), 1)
    }

    func testTextAndFileRoutesGiveTheSameId() async throws {
        let text = TranscriptFixtures.all["zoom.vtt"]!
        let fromFile = try added(try await importFile("zoom.vtt", text))
        let fromText = try added(try await TranscriptLibraryImport.importText(
            name: "zoom.vtt", text: text, store: store, now: Date(), timeZone: utc))
        XCTAssertEqual(fromText.id, fromFile.id)
        XCTAssertTrue(fromText.readded)
        XCTAssertEqual(try itemCount(), 1)
    }

    func testAFolderPathKeepsOnlyTheFileName() async throws {
        let result = try added(try await importFile("Meetings/2026/zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!))
        XCTAssertEqual(try store.loadItem(id: result.id).externalReference, "zoom.vtt")
    }

    // MARK: What is not added

    func testOrdinaryTextIsHandedBack() async throws {
        let text = "Just a paragraph of notes.\n\nAnother one."
        let outcome = try await importFile("notes.txt", text)
        XCTAssertEqual(outcome, .notTranscript(text: text))
        let viaText = try await TranscriptLibraryImport.importText(name: "notes.txt", text: text, store: store, timeZone: utc)
        XCTAssertEqual(viaText, .notTranscript(text: text))
        XCTAssertEqual(try itemCount(), 0)
        XCTAssertEqual(try StoreRawSQL.ids(kind: TranscriptTimes.recordKind, at: path), [])
    }

    func testAnEmptyFileIsRefusedAndAddsNothing() async throws {
        let outcome = try await TranscriptLibraryImport.importFile(
            name: "empty.vtt", data: Data(), store: store, docxText: docx, timeZone: utc)
        guard case .failed(let message) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertEqual(message.kind, .empty)
        XCTAssertEqual(try itemCount(), 0)
    }

    func testAFileOverTenMegabytesIsRefusedWithItsSentence() async throws {
        let data = Data(repeating: UInt8(ascii: "a"), count: TranscriptImport.maximumBytes + 1)
        let outcome = try await TranscriptLibraryImport.importFile(
            name: "huge.vtt", data: data, store: store, docxText: docx, timeZone: utc)
        guard case .failed(let message) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertEqual(message.kind, .tooLarge)
        XCTAssertTrue((message.errorDescription ?? "").contains("larger than 10 MB"), message.errorDescription ?? "")
        XCTAssertEqual(try itemCount(), 0)
    }

    // MARK: Twice, and at once

    func testASecondImportOfTheSameFileIsOneItemAddedAgain() async throws {
        let text = TranscriptFixtures.all["teams.vtt"]!
        let first = try added(try await importFile("teams.vtt", text, now: Date(timeIntervalSince1970: 1_000)))
        let second = try added(try await importFile("teams.vtt", text, now: Date(timeIntervalSince1970: 5_000)))
        XCTAssertEqual(second.id, first.id)
        XCTAssertTrue(second.readded)
        XCTAssertEqual(try itemCount(), 1)
        let item = try store.loadItem(id: first.id)
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 1_000), "the first-added date is kept")
        XCTAssertEqual(item.addedAgainAt, Date(timeIntervalSince1970: 5_000))
    }

    func testTwoImportsAtOnceGiveOneItemAndOneTimesRecord() async throws {
        let text = TranscriptFixtures.all["otter.txt"]!
        let store = self.store!, zone = utc, docx = self.docx
        let outcomes = try await withThrowingTaskGroup(of: TranscriptLibraryImport.Outcome.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await TranscriptLibraryImport.importFile(
                        name: "otter.txt", data: Data(text.utf8), store: store, docxText: docx, timeZone: zone)
                }
            }
            var all: [TranscriptLibraryImport.Outcome] = []
            for try await outcome in group { all.append(outcome) }
            return all
        }
        let ids = Set(try outcomes.map { try added($0).id })
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try outcomes.filter { try !added($0).readded }.count, 1, "exactly one of them is the first add")
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try StoreRawSQL.ids(kind: TranscriptTimes.recordKind, at: path).count, 1)
    }

    func testAnImportWhileABackgroundReadIsOpenStillLands() async throws {
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let store = self.store!
        Thread.detachNewThread {
            try? store.readTexts("SELECT 'row';", [], name: "held_read") { _ in
                holding.signal()
                _ = release.wait(timeout: .now() + 30)
            }
            done.signal()
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 10), .success)
        let outcome = try await importFile("meet.txt", TranscriptFixtures.all["meet.txt"]!)
        release.signal()
        _ = done.wait(timeout: .now() + 10)
        let result = try added(outcome)
        XCTAssertNotNil(try store.loadTranscriptTimes(itemId: result.id))
    }

    func testTheItemAndItsTimesSurviveReopeningTheDatabase() async throws {
        let result = try added(try await importFile("zoom-captions.txt", TranscriptFixtures.all["zoom-captions.txt"]!))
        let before = try XCTUnwrap(try store.loadTranscriptTimes(itemId: result.id))
        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.loadItem(id: result.id).externalReferenceType, TranscriptItemText.referenceType)
        XCTAssertEqual(try reopened.loadTranscriptTimes(itemId: result.id), before)
    }

    // MARK: First run, returning, finished, deleted

    func testAnOrdinaryTextItemWithTheSameFileNameIsUntouched() async throws {
        let plain = Item(id: "plain", title: "zoom.vtt", mediaType: "text", text: "Typed by hand.", externalReference: "zoom.vtt",
                         status: "needs_listening_map", createdAt: Date(timeIntervalSince1970: 10))
        try store.saveItem(plain)
        let result = try added(try await importFile("zoom.vtt", TranscriptFixtures.all["zoom.vtt"]!))
        XCTAssertNotEqual(result.id, "plain")
        XCTAssertEqual(try store.loadItem(id: "plain"), plain)
        XCTAssertNil(try store.loadTranscriptTimes(itemId: "plain"))
    }

    func testAddingAFinishedTranscriptAgainClearsTheFinishedMark() async throws {
        let text = TranscriptFixtures.all["webex.vtt"]!
        let first = try added(try await importFile("webex.vtt", text, now: Date(timeIntervalSince1970: 1_000)))
        var item = try store.loadItem(id: first.id)
        item.sourceCompletedAt = Date(timeIntervalSince1970: 2_000)
        try store.saveItem(item)

        let again = try added(try await importFile("webex.vtt", text, now: Date(timeIntervalSince1970: 9_000)))
        XCTAssertTrue(again.readded)
        let stored = try store.loadItem(id: first.id)
        XCTAssertNil(stored.sourceCompletedAt, "a finished item added again reads as unfinished (#4178)")
        XCTAssertEqual(stored.addedAgainAt, Date(timeIntervalSince1970: 9_000))
    }

    func testAnItemTheListenerIsStillInIsLeftAsItIs() async throws {
        let text = TranscriptFixtures.all["webex.vtt"]!
        let first = try added(try await importFile("webex.vtt", text, now: Date(timeIntervalSince1970: 1_000)))
        var item = try store.loadItem(id: first.id)
        item.sourceCompletedAt = Date(timeIntervalSince1970: 2_000)
        try store.saveItem(item)

        let again = try added(try await importFile("webex.vtt", text, now: Date(timeIntervalSince1970: 9_000), stillListening: [first.id]))
        XCTAssertTrue(again.readded)
        let stored = try store.loadItem(id: first.id)
        XCTAssertEqual(stored.sourceCompletedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNil(stored.addedAgainAt)
    }

    func testAnItemInRecentlyDeletedComesBackWithTheListenersTitle() async throws {
        let text = TranscriptFixtures.all["teams.vtt"]!
        let first = try added(try await importFile("teams.vtt", text, now: Date(timeIntervalSince1970: 1_000)))
        var item = try store.loadItem(id: first.id)
        item.title = "My own name for it"
        try store.saveItem(item)
        try store.moveItemToTrash(id: first.id, at: Date(timeIntervalSince1970: 3_000))
        XCTAssertNotNil(try store.loadItem(id: first.id).deletedAt)

        // The times are replaced by the new file's, so make the old ones differ.
        var stale = try XCTUnwrap(try store.loadTranscriptTimes(itemId: first.id))
        stale.cueStartMs = stale.cueStartMs.map { $0 + 1 }
        try store.save(kind: TranscriptTimes.recordKind, id: first.id, sessionId: nil, itemId: first.id, value: stale)

        let again = try added(try await importFile("teams.vtt", text, now: Date(timeIntervalSince1970: 9_000)))
        XCTAssertTrue(again.readded)
        XCTAssertEqual(again.title, "My own name for it")
        let stored = try store.loadItem(id: first.id)
        XCTAssertNil(stored.deletedAt)
        XCTAssertEqual(stored.title, "My own name for it")
        XCTAssertEqual(stored.createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertNotEqual(try store.loadTranscriptTimes(itemId: first.id)?.cueStartMs, stale.cueStartMs)
    }

    // MARK: Deleting and quarantine

    func testDeletingTheItemForGoodRemovesItsTimes() async throws {
        let result = try added(try await importFile("generic.srt", TranscriptFixtures.all["generic.srt"]!))
        try store.deleteItem(id: result.id)
        XCTAssertEqual(try StoreRawSQL.ids(kind: TranscriptTimes.recordKind, at: path), [])
        XCTAssertNil(try store.loadTranscriptTimes(itemId: result.id))
    }

    func testAQuarantinedTimesRowComesBackOnReopenAndGoesWithItsItem() async throws {
        let result = try added(try await importFile("generic.srt", TranscriptFixtures.all["generic.srt"]!))
        let before = try store.loadTranscriptTimes(itemId: result.id)
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, 'older build could not decode this row', '2026-02-03 04:05:06'
            FROM records WHERE kind = ? AND id = ?;
            """, bindings: [TranscriptTimes.recordKind, result.id], at: path)
        try StoreRawSQL.execute("DELETE FROM records WHERE kind = ? AND id = ?;", bindings: [TranscriptTimes.recordKind, result.id], at: path)
        XCTAssertEqual(try StoreRawSQL.ids(kind: TranscriptTimes.recordKind, at: path), [])

        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.loadTranscriptTimes(itemId: result.id), before)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)

        // And a row still set aside is removed with its item, not left to come back to a deleted item.
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, 'x', '2026-02-03 04:05:06' FROM records WHERE kind = ? AND id = ?;
            """, bindings: [TranscriptTimes.recordKind, result.id], at: path)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 1)
        try reopened.deleteItem(id: result.id)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
    }

    func testATimesRecordThisBuildCannotReadIsNotAnError() async throws {
        let result = try added(try await importFile("generic.srt", TranscriptFixtures.all["generic.srt"]!))
        try StoreRawSQL.execute("UPDATE records SET payload = '{\"future\":true}' WHERE kind = ? AND id = ?;",
                                bindings: [TranscriptTimes.recordKind, result.id], at: path)
        XCTAssertNil(try store.loadTranscriptTimes(itemId: result.id))
    }

    // MARK: Where it shows

    func testAMarginOnATranscriptShowsTheMeetingClock() async throws {
        let result = try added(try await importFile("meet.txt", TranscriptFixtures.all["meet.txt"]!))
        let item = try store.loadItem(id: result.id)
        let times = try XCTUnwrap(try store.loadTranscriptTimes(itemId: result.id))
        let secondCue = times.cueStartChars[1]
        let session = Session(
            id: "session-t", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id, position: Position(charOffset: secondCue),
            completionPercent: 10, playbackRate: 1)
        try store.saveSession(session)
        try store.saveInterjection(Interjection(
            id: "margin-t", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: secondCue, endChar: secondCue + 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A written Margin", status: "active"))

        let entries = try MarginRowsReading.item(item.id, store: store)
        let place = try XCTUnwrap(entries.privateRows.first?.place)
        XCTAssertEqual(place.meetingClockMs, times.cueStartMs[1])
        XCTAssertEqual(place.meetingClockMs, 6_000)
        let line = MarginRowWording.placeLine(
            placeName: place.chapterName, mediaTimeMs: nil, meetingClockMs: place.meetingClockMs, paragraph: place.paragraph,
            roughPercent: 10, createdAt: Date(timeIntervalSince1970: 1), now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(line.hasPrefix("00:06"), line)
    }

    func testTheItemScreenGetsTheMeetingLineAndTheTranscriptNoun() async throws {
        let result = try added(try await importFile("meet.txt", TranscriptFixtures.all["meet.txt"]!))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = try ItemDetailLoader.load(
            id: result.id, store: store, snapshotItemId: nil, snapshotSessionId: nil,
            placementPasses: SharedMarginPlacementPasses(), now: now)
        let times = try XCTUnwrap(try store.loadTranscriptTimes(itemId: result.id))
        XCTAssertEqual(state.meetingLine, times.meetingLine(now: now))
        XCTAssertFalse(try XCTUnwrap(state.meetingLine).isEmpty)
        XCTAssertEqual(state.sourceNoun, .transcript)

        // An ordinary text item has no meeting line.
        try store.saveItem(Item(id: "plain", title: "Plain", mediaType: "text", text: "Hello there.", externalReference: "plain.txt",
                                status: "needs_listening_map", createdAt: Date(timeIntervalSince1970: 10)))
        let plain = try ItemDetailLoader.load(
            id: "plain", store: store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
        XCTAssertNil(plain.meetingLine)
    }

    // MARK: Atomic, and across store instances

    func testAFailedTimesSaveLeavesNoItemBehind() throws {
        try StoreRawSQL.execute("""
            CREATE TRIGGER refuse_times BEFORE INSERT ON records WHEN NEW.kind = '\(TranscriptTimes.recordKind)'
            BEGIN SELECT RAISE(ABORT, 'times refused'); END;
            """, at: path)
        let transcript = try TranscriptImport.parse(text: TranscriptFixtures.all["generic.srt"]!, timeZone: utc)
        let built = TranscriptItemText.build(transcript, fileName: "generic.srt", timeZone: utc)
        let item = Item(id: built.id, title: built.title, mediaType: "text", text: built.text, externalReference: "generic.srt",
                        status: "needs_listening_map", externalReferenceType: TranscriptItemText.referenceType, createdAt: Date())
        XCTAssertThrowsError(try store.saveTranscriptItem(
            item, times: TranscriptTimes(transcript: transcript, built: built), readdedAt: Date()))
        XCTAssertEqual(try itemCount(), 0, "the item and its times are one transaction")
    }

    func testTwoStoreInstancesSavingTheSameTranscriptAtOnceGiveOneItem() throws {
        let other = try SQLiteSessionStore(path: path)
        let transcript = try TranscriptImport.parse(text: TranscriptFixtures.all["zoom.vtt"]!, timeZone: utc)
        let built = TranscriptItemText.build(transcript, fileName: "zoom.vtt", timeZone: utc)
        let times = TranscriptTimes(transcript: transcript, built: built)
        let item = Item(id: built.id, title: built.title, mediaType: "text", text: built.text, externalReference: "zoom.vtt",
                        status: "needs_listening_map", externalReferenceType: TranscriptItemText.referenceType, createdAt: Date())
        let stores = [store!, other]
        let results = LockedBox<[TranscriptItemSave]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            if let saved = try? stores[index % 2].saveTranscriptItem(item, times: times, readdedAt: Date()) {
                results.withValue { $0.append(saved) }
            }
        }
        let saves = results.withValue { $0 }
        XCTAssertEqual(saves.count, 8)
        XCTAssertEqual(saves.filter { !$0.readded }.count, 1, "exactly one save is the first add")
        XCTAssertEqual(try itemCount(), 1)
        XCTAssertEqual(try StoreRawSQL.ids(kind: TranscriptTimes.recordKind, at: path).count, 1)
    }

    func testAddingAgainKeepsTheSessionAndMargin() async throws {
        let text = TranscriptFixtures.all["meet.txt"]!
        let first = try added(try await importFile("meet.txt", text))
        try store.saveSession(Session(
            id: "session-keep", itemId: first.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
            currentTargetId: first.id, position: Position(charOffset: 3), completionPercent: 10, playbackRate: 1))
        try store.saveInterjection(Interjection(
            id: "margin-keep", itemId: first.id, sessionId: "session-keep", targetType: .item, targetId: first.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "Keep me", status: "active"))
        try store.moveItemToTrash(id: first.id)
        _ = try added(try await importFile("meet.txt", text))
        XCTAssertNotNil(try store.loadSession(id: "session-keep"))
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-keep").map(\.id), ["margin-keep"])
    }

    func testATranscriptMarginGetsTheMeetingClockEvenWithoutAListeningMap() async throws {
        let result = try added(try await importFile("meet.txt", TranscriptFixtures.all["meet.txt"]!))
        let item = try store.loadItem(id: result.id)
        let times = try XCTUnwrap(try store.loadTranscriptTimes(itemId: result.id))
        let offset = times.cueStartChars[2]
        let margin = Interjection(
            id: "margin-nomap", itemId: item.id, sessionId: "session-nomap", targetType: .item, targetId: item.id,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: offset, endChar: offset + 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "No map", status: "active")
        let session = Session(
            id: "session-nomap", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
            currentTargetId: item.id, position: Position(charOffset: offset), completionPercent: 10, playbackRate: 1)
        let entries = try MarginCollection.build(
            items: [item], sessions: [session],
            loadTranscriptTimes: { try? self.store.loadTranscriptTimes(itemId: $0) },
            loadInterjections: { _ in [margin] }, loadImportedLayers: { [] }, loadImportedInterjections: { _ in [] })
        let place = try XCTUnwrap(entries.privateRows.first?.place)
        XCTAssertEqual(place.meetingClockMs, 9_000)
        XCTAssertNil(place.paragraph)
        XCTAssertNil(place.chapterName)
    }

    // MARK: A long meeting

    private func longVTT(cues: Int, words: String = "This is sentence number") -> String {
        var lines = ["WEBVTT", ""]
        for index in 0..<cues {
            let start = index * 1_000
            func stamp(_ ms: Int) -> String {
                String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1_000 % 60, ms % 1_000)
            }
            lines.append("\(stamp(start)) --> \(stamp(start + 900))")
            lines.append("Speaker \(index % 4): \(words) \(index) of a long meeting.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func testATenThousandCueMeetingImportsQuicklyAndItsTimesReadBackQuickly() async throws {
        let vtt = longVTT(cues: 10_000)
        let began = Date()
        let result = try added(try await importFile("long.vtt", vtt))
        XCTAssertLessThan(Date().timeIntervalSince(began), 15, "parse, build and save of 10,000 cues (a loose bound, so a loaded machine does not flake it)")

        let times = try XCTUnwrap(try store.loadTranscriptTimes(itemId: result.id))
        XCTAssertEqual(times.cueStartChars.count, 10_000)
        XCTAssertEqual(times.cueStartMs.count, 10_000)
        XCTAssertEqual(times.summary.speakers.count, 4)

        let readBegan = Date()
        _ = try store.loadTranscriptTimes(itemId: result.id)
        XCTAssertLessThan(Date().timeIntervalSince(readBegan), 1, "the 10,000-cue record decodes in milliseconds")
        let bytes = try XCTUnwrap(try StoreRawSQL.rows(
            "SELECT length(payload) FROM records WHERE kind = ? AND id = ?;", bindings: [TranscriptTimes.recordKind, result.id], at: path).first?.first ?? nil)
        XCTAssertLessThan(Int(bytes) ?? .max, 400_000, "two integer arrays and a summary, no cue text")
    }

    func testAFileJustUnderTheSizeLimitWithFewLongCuesImports() async throws {
        let filler = String(repeating: "word ", count: 38_000)
        var lines = ["WEBVTT", ""]
        for index in 0..<50 {
            lines.append("00:\(String(format: "%02d", index)):00.000 --> 00:\(String(format: "%02d", index)):30.000")
            lines.append("Speaker \(index % 2): \(filler)")
            lines.append("")
        }
        var data = Data(lines.joined(separator: "\n").utf8)
        XCTAssertLessThanOrEqual(data.count, TranscriptImport.maximumBytes)
        // Pad with trailing blank lines up to just under the limit.
        data.append(Data(repeating: UInt8(ascii: "\n"), count: max(0, TranscriptImport.maximumBytes - 100 - data.count)))
        XCTAssertLessThanOrEqual(data.count, TranscriptImport.maximumBytes)
        let outcome = try await TranscriptLibraryImport.importFile(
            name: "big.vtt", data: data, store: store, docxText: docx, timeZone: utc)
        let result = try added(outcome)
        XCTAssertEqual(try store.loadTranscriptTimes(itemId: result.id)?.cueStartChars.count, 50)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    @discardableResult
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
