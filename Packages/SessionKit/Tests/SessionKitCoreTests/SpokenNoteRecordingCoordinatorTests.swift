import Foundation
import XCTest
@testable import SessionKit

/// #3108: recording takes into a spoken note. The note, its folder and `note.json` are real temporary files; only the
/// microphone and the speech recognizer are stand-ins, and the stand-in recorder writes a real file.
final class SpokenNoteRecordingCoordinatorTests: XCTestCase {
    private var support: URL!
    private var started: SpokenNoteStarter.Started!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        started = try SpokenNoteStarter.start(in: support, now: Date(timeIntervalSince1970: 1), makeId: { "n1" })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: Stand-ins

    private final class FakeRecorder: SpokenNoteTakeRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        private var handler: (@Sendable () -> Void)?
        var durationMs = 4_000
        var failBegin = false
        var writesFile = true

        func begin(writingTo url: URL) async throws {
            if failBegin { throw NSError(domain: "mic", code: 1) }
            if writesFile { try Data([1, 2, 3]).write(to: url) }
            lock.withLock { self.url = url }
        }

        func end() async throws -> Int {
            guard lock.withLock({ url }) != nil else { throw NSError(domain: "mic", code: 2) }
            lock.withLock { url = nil }
            return durationMs
        }

        func setStoppedBySystemHandler(_ handler: (@Sendable () -> Void)?) {
            lock.withLock { self.handler = handler }
        }

        func systemStops() { lock.withLock { handler }?() }
        var hasHandler: Bool { lock.withLock { handler != nil } }
    }

    private final class FakeTranscriber: SpokenNoteTranscribing, @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [String] = []
        private let gate = ReleaseLatch()
        var holds = false
        var fails = false
        var words: [AlignedTranscriptSegment] = [
            AlignedTranscriptSegment(id: "w0", text: "Call", startMs: 0, endMs: 300),
            AlignedTranscriptSegment(id: "w1", text: "the", startMs: 400, endMs: 600),
            AlignedTranscriptSegment(id: "w2", text: "plumber.", startMs: 700, endMs: 1_200)
        ]

        var requestedFiles: [String] { lock.withLock { requested } }

        func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment] {
            lock.withLock { requested.append(url.lastPathComponent) }
            if holds { await gate.wait() }
            if fails { throw NSError(domain: "speech", code: 1) }
            return words
        }

        func release() { gate.release() }
    }

    private final class SavedItems: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Item] = []
        var failNext = false
        var all: [Item] { lock.withLock { items } }

        func save(_ item: Item) throws {
            try lock.withLock {
                if failNext { failNext = false; throw NSError(domain: "db", code: 1) }
                items.append(item)
            }
        }
    }

    private final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [SpokenNoteRecordingSnapshot] = []
        func add(_ snapshot: SpokenNoteRecordingSnapshot) { lock.withLock { list.append(snapshot) } }
        var all: [SpokenNoteRecordingSnapshot] { lock.withLock { list } }
    }

    private final class Ids: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        func make() -> String { lock.withLock { next += 1; return "t\(next)" } }
    }

    private func makeCoordinator(
        recorder: FakeRecorder = FakeRecorder(),
        transcriber: FakeTranscriber = FakeTranscriber(),
        saved: SavedItems = SavedItems(),
        itemIsSaved: Bool = false
    ) -> (SpokenNoteRecordingCoordinator, FakeRecorder, FakeTranscriber, SavedItems) {
        let ids = Ids()
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store, item: started.item, itemIsSaved: itemIsSaved,
            recorder: recorder, transcriber: transcriber,
            saveItem: { item, _ in try saved.save(item) },
            now: { Date(timeIntervalSince1970: 100) },
            makeTakeId: { ids.make() }
        )
        return (coordinator, recorder, transcriber, saved)
    }

    // MARK: Tests

    /// #3663: the note is named for its day until words arrive, then for its first words; a rename is the recording's own.
    func testTheTitleFollowsTheWordsUntilTheListenerRenamesTheNote() async throws {
        let transcriber = FakeTranscriber()
        transcriber.holds = true
        let (coordinator, _, _, saved) = makeCoordinator(transcriber: transcriber)

        let before = await coordinator.snapshot().title
        XCTAssertTrue(before.hasPrefix("Spoken note,"), before)

        try await coordinator.startTake()
        _ = try await coordinator.stopTake()
        XCTAssertEqual(saved.all.last?.title, before, "the row is created with the day-and-time name while the words are awaited")

        transcriber.release()
        await coordinator.waitForTranscripts()
        let named = await coordinator.snapshot().title
        XCTAssertTrue(named.hasSuffix("· Call the plumber"), named)
        XCTAssertEqual(saved.all.last?.title, named, "the row the recording saves carries the same name")

        await coordinator.adoptTitle("Plumber call")
        let renamed = await coordinator.snapshot().title
        XCTAssertEqual(renamed, "Plumber call")
        await coordinator.flushItem()
        XCTAssertEqual(saved.all.last?.title, named, "adopting a title writes nothing itself: the rename was written by the store")
    }

    func testAStoppedTakeIsInTheNoteBeforeAnyTranscriptExistsAndTheRowIsCreatedWithIt() async throws {
        let transcriber = FakeTranscriber()
        transcriber.holds = true
        let (coordinator, _, _, saved) = makeCoordinator(transcriber: transcriber)

        try await coordinator.startTake()
        XCTAssertTrue(saved.all.isEmpty, "recording alone makes no Library row")
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.store.folderURL.appendingPathComponent("take-t1.m4a").path))
        let note = try await coordinator.stopTake()

        XCTAssertEqual(note.takes.map(\.id), ["t1"])
        XCTAssertEqual(note.takes[0].audioFileName, "take-t1.m4a")
        XCTAssertEqual(note.takes[0].durationMs, 4_000)
        XCTAssertFalse(note.takes[0].hasTranscript)
        // On disk too, with the transcriber still working.
        XCTAssertEqual(started.store.load().takes.map(\.id), ["t1"])
        XCTAssertEqual(saved.all.map(\.id), [started.item.id])
        XCTAssertEqual(saved.all[0].text, "")
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.transcribingTakeIds, ["t1"])
        XCTAssertFalse(snapshot.isRecording)

        transcriber.release()
        await coordinator.waitForTranscripts()
    }

    /// #3616: the transcript runs in its own task, so a test's release can come before that task reaches the
    /// transcriber. This forces that order. A stand-in that forgets the release parks the task for good, and with it
    /// `waitForTranscripts`; the deadline turns that hang into a failure here.
    func testAReleaseThatComesBeforeTheTranscriberIsReachedStillLetsTheTranscriptFinish() async throws {
        let transcriber = FakeTranscriber()
        transcriber.holds = true
        transcriber.release()
        let (coordinator, _, _, _) = makeCoordinator(transcriber: transcriber)

        try await coordinator.startTake()
        try await coordinator.stopTake()
        let finished = expectation(description: "the transcript came back")
        Task {
            await coordinator.waitForTranscripts()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(started.store.load().takes[0].sentences.map(\.text), ["Call the plumber."])
    }

    func testTheTranscriptFillsInAndTheLibraryItemTextFollows() async throws {
        let (coordinator, _, transcriber, saved) = makeCoordinator()
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()

        let take = started.store.load().takes[0]
        XCTAssertEqual(take.sentences.map(\.text), ["Call the plumber."])
        XCTAssertEqual(transcriber.requestedFiles, ["take-t1.m4a"])
        XCTAssertEqual(saved.all.last?.text, "Call the plumber.")
        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.transcribingTakeIds.isEmpty)
        XCTAssertTrue(snapshot.failedTranscriptTakeIds.isEmpty)
    }

    func testASecondTakeIsAddedAtTheEndAndTheFirstIsUntouched() async throws {
        let (coordinator, _, _, _) = makeCoordinator()
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()
        let first = started.store.load().takes[0]

        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()

        let note = started.store.load()
        XCTAssertEqual(note.takes.map(\.id), ["t1", "t2"])
        XCTAssertEqual(note.takes[0], first)
        XCTAssertEqual(note.text, "Call the plumber. Call the plumber.")
    }

    func testATranscriberThatFailsLeavesTheAudioInTheNoteAndARetryFillsItIn() async throws {
        let transcriber = FakeTranscriber()
        transcriber.fails = true
        let (coordinator, _, _, saved) = makeCoordinator(transcriber: transcriber)
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()

        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.failedTranscriptTakeIds, ["t1"])
        XCTAssertEqual(snapshot.note.takes.map(\.id), ["t1"], "the take stays")
        XCTAssertFalse(snapshot.note.takes[0].hasTranscript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.store.folderURL.appendingPathComponent("take-t1.m4a").path))

        transcriber.fails = false
        await coordinator.retryTranscript(forTake: "t1")
        await coordinator.waitForTranscripts()
        snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.failedTranscriptTakeIds.isEmpty)
        XCTAssertEqual(snapshot.note.takes[0].sentences.map(\.text), ["Call the plumber."])
        XCTAssertEqual(saved.all.last?.text, "Call the plumber.")
    }

    func testAnEmptyTranscriptChangesNothingAndIsNotAFailure() async throws {
        let transcriber = FakeTranscriber()
        transcriber.words = []
        let (coordinator, _, _, _) = makeCoordinator(transcriber: transcriber)
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()

        let snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.failedTranscriptTakeIds.isEmpty)
        XCTAssertFalse(snapshot.note.takes[0].hasTranscript)
    }

    func testOneTakeAtATimeAndStopNeedsARecording() async throws {
        let (coordinator, _, _, _) = makeCoordinator()
        do {
            _ = try await coordinator.stopTake()
            XCTFail("stop with nothing recording")
        } catch let error as SpokenNoteRecordingCoordinator.RecordingError {
            XCTAssertEqual(error, .notRecording)
        }
        try await coordinator.startTake()
        do {
            try await coordinator.startTake()
            XCTFail("a second start while recording")
        } catch let error as SpokenNoteRecordingCoordinator.RecordingError {
            XCTAssertEqual(error, .alreadyRecording)
        }
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()
        XCTAssertEqual(started.store.load().takes.count, 1, "the refused start made no take")
    }

    func testARecorderThatCannotStartLeavesNoTakeAndAnEmptyNoteCanBeRemoved() async throws {
        let recorder = FakeRecorder()
        recorder.failBegin = true
        let (coordinator, _, _, saved) = makeCoordinator(recorder: recorder)
        do {
            try await coordinator.startTake()
            XCTFail("begin should throw")
        } catch {}
        var snapshot = await coordinator.snapshot()
        XCTAssertFalse(snapshot.isRecording)
        XCTAssertFalse(recorder.hasHandler)
        XCTAssertTrue(saved.all.isEmpty)

        recorder.failBegin = false
        try await coordinator.startTake()
        snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.isRecording, "a later start works")
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()

        let removed = await coordinator.discardIfNothingWasRecorded()
        XCTAssertFalse(removed, "a note with a take is never removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.store.folderURL.path))
    }

    func testAnEmptyNoteFolderIsRemovedButNeverOneHoldingAnythingElse() async throws {
        let (coordinator, _, _, _) = makeCoordinator()
        let stray = started.store.folderURL.appendingPathComponent("take-orphan.m4a")
        try Data([9]).write(to: stray)
        var removed = await coordinator.discardIfNothingWasRecorded()
        XCTAssertFalse(removed, "an audio file the note doesn't list is the listener's recording; leave it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))

        try FileManager.default.removeItem(at: stray)
        removed = await coordinator.discardIfNothingWasRecorded()
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.store.folderURL.path))
    }

    func testTheSystemStoppingTheRecorderClosesTheTakeLikeStop() async throws {
        let (coordinator, recorder, _, _) = makeCoordinator()
        try await coordinator.startTake()
        XCTAssertTrue(recorder.hasHandler)
        recorder.systemStops()
        for _ in 0..<200 {
            if await !coordinator.snapshot().isRecording { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await coordinator.waitForTranscripts()
        let note = started.store.load()
        XCTAssertEqual(note.takes.map(\.id), ["t1"], "what was dictated before the call is kept")
        XCTAssertTrue(note.takes[0].hasTranscript)
        XCTAssertFalse(recorder.hasHandler)
    }

    func testAnUnreadableNoteFileIsNeverWrittenOverAndTheAudioStays() async throws {
        let (coordinator, _, _, saved) = makeCoordinator()
        try await coordinator.startTake()
        // Reading note.json fails (a locked phone, say): make the path a folder, which can't be read as a file.
        try FileManager.default.removeItem(at: started.store.fileURL)
        try FileManager.default.createDirectory(at: started.store.fileURL, withIntermediateDirectories: false)
        do {
            try await coordinator.stopTake()
            XCTFail("an unreadable note must not be saved over")
        } catch let error as SpokenNoteIntake.IntakeError {
            XCTAssertEqual(error, .noteUnreadable)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.store.folderURL.appendingPathComponent("take-t1.m4a").path))
        XCTAssertTrue(saved.all.isEmpty)
        let snapshot = await coordinator.snapshot()
        XCTAssertFalse(snapshot.isRecording, "the recorder is closed; a new take can start")
    }

    func testAFailedItemSaveIsTriedAgainOnTheNextChange() async throws {
        let saved = SavedItems()
        saved.failNext = true
        let (coordinator, _, _, _) = makeCoordinator(saved: saved)
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()
        // The first save failed; the transcript arriving saved the row with the text.
        XCTAssertEqual(saved.all.map(\.id), [started.item.id])
        XCTAssertEqual(saved.all[0].text, "Call the plumber.")
    }

    func testAReopenedNoteTranscribesTakesThatHaveNoTranscriptYet() async throws {
        let first = makeCoordinator(transcriber: { let t = FakeTranscriber(); t.fails = true; return t }())
        try await first.0.startTake()
        try await first.0.stopTake()
        await first.0.waitForTranscripts()
        XCTAssertFalse(started.store.load().takes[0].hasTranscript)

        // A new coordinator on the same folder, as after the app was closed.
        let reopened = makeCoordinator(itemIsSaved: true)
        await reopened.0.resumeTranscripts()
        await reopened.0.waitForTranscripts()
        XCTAssertEqual(started.store.load().takes[0].sentences.map(\.text), ["Call the plumber."])
        XCTAssertEqual(reopened.3.all.last?.text, "Call the plumber.", "the row follows the transcript")
    }

    func testAReopenedNoteDoesNotSaveItsRowUntilSomethingChanges() async throws {
        let reopened = makeCoordinator(itemIsSaved: true)
        await reopened.0.resumeTranscripts()
        XCTAssertTrue(reopened.3.all.isEmpty)
    }

    func testChangesAreReportedToTheScreen() async throws {
        let (coordinator, _, _, _) = makeCoordinator()
        let snapshots = Snapshots()
        await coordinator.setOnChange { snapshots.add($0) }
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()
        let all = snapshots.all
        XCTAssertTrue(all.contains { $0.isRecording })
        XCTAssertEqual(all.last?.note.takes.first?.sentences.map(\.text), ["Call the plumber."])
        XCTAssertEqual(all.last?.isRecording, false)
    }

    /// A take whose add to `note.json` failed is kept and added by the next step, so the audio never stays orphaned.
    func testATakeThatCouldNotBeAddedIsAddedByTheNextStart() async throws {
        let (coordinator, _, _, saved) = makeCoordinator()
        try await coordinator.startTake()
        let good = try Data(contentsOf: started.store.fileURL)
        try FileManager.default.removeItem(at: started.store.fileURL)
        try FileManager.default.createDirectory(at: started.store.fileURL, withIntermediateDirectories: false)
        do { try await coordinator.stopTake(); XCTFail("should not save over an unreadable note") } catch {}
        var snapshot = await coordinator.snapshot()
        XCTAssertTrue(snapshot.hasUnsavedTake)

        // The file becomes readable again (the phone is unlocked).
        try FileManager.default.removeItem(at: started.store.fileURL)
        try good.write(to: started.store.fileURL)
        try await coordinator.startTake()
        snapshot = await coordinator.snapshot()
        XCTAssertFalse(snapshot.hasUnsavedTake)
        XCTAssertEqual(started.store.load().takes.map(\.id), ["t1"], "the first take is in the note")
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()
        XCTAssertEqual(started.store.load().takes.map(\.id), ["t1", "t2"])
        XCTAssertFalse(saved.all.isEmpty)
    }

    /// An item save that failed is tried again when the screen is done, even if no transcript arrives.
    func testAFailedRowSaveIsRetriedWhenTheScreenIsDone() async throws {
        let transcriber = FakeTranscriberForFlush()
        let saved = SavedItemsForFlush()
        saved.failNext = true
        let coordinator = SpokenNoteRecordingCoordinator(
            store: started.store, item: started.item, itemIsSaved: false,
            recorder: RecorderForFlush(), transcriber: transcriber,
            saveItem: { item, _ in try saved.save(item) }, now: { Date(timeIntervalSince1970: 5) }, makeTakeId: { "f1" }
        )
        try await coordinator.startTake()
        try await coordinator.stopTake()
        await coordinator.waitForTranscripts()
        // The transcript failed and so did the first save; Done flushes the row.
        await coordinator.flushItem()
        XCTAssertEqual(saved.ids, [started.item.id])
    }
}

private final class RecorderForFlush: SpokenNoteTakeRecording, @unchecked Sendable {
    private var url: URL?
    func begin(writingTo url: URL) async throws { try Data([1]).write(to: url); self.url = url }
    func end() async throws -> Int { 1_000 }
    func setStoppedBySystemHandler(_ handler: (@Sendable () -> Void)?) {}
}

private struct FakeTranscriberForFlush: SpokenNoteTranscribing {
    func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment] { throw NSError(domain: "x", code: 1) }
}

private final class SavedItemsForFlush: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    var failNext = false
    var ids: [String] { lock.withLock { list } }
    func save(_ item: Item) throws {
        try lock.withLock {
            if failNext { failNext = false; throw NSError(domain: "db", code: 1) }
            list.append(item.id)
        }
    }
}
