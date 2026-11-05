import Foundation

/// The microphone side of a spoken note take (#3108, #1609). The app's implementation wraps `AVAudioRecorder`; a test
/// writes a file of its own. One take is one audio file in the note's folder.
public protocol SpokenNoteTakeRecording: Sendable {
    /// Starts recording into a new file at `url`. Throws when it can't start (no microphone, a call in progress).
    func begin(writingTo url: URL) async throws
    /// Stops and closes the file, then returns how long it holds in milliseconds. The file is complete when this
    /// returns. Throws only when there is no recording going on.
    func end() async throws -> Int
    /// Called, once, when the system ends the recording on its own (a call, Siri, the headphones going away). The
    /// audio taken so far is in the file; the coordinator then closes the take as if the listener had tapped Stop.
    func setStoppedBySystemHandler(_ handler: (@Sendable () -> Void)?)
}

/// The speech side: turns one take's audio file into timed words.
public protocol SpokenNoteTranscribing: Sendable {
    func transcribe(fileAt url: URL) async throws -> [AlignedTranscriptSegment]
}

/// Where a note's Library item is written. The database is one; a test is another.
public protocol SpokenNoteItemWriting: Sendable {
    /// Brings the stored row up to date with the note's text. Only the text is ever changed on a row that already
    /// exists; see `SpokenNoteItemMerge`. `isFirstSave` is true until the row has been written once.
    func write(_ item: Item, isFirstSave: Bool) throws
}

/// What a note's row should become when its transcript text changes (#3108). The coordinator keeps its own copy of
/// the item from when the note started, so it must never save that whole copy over the stored row: the listener may
/// have moved the row to the trash, renamed it or emptied the trash since. Only the text is brought up to date, and a
/// row the listener deleted stays deleted.
public enum SpokenNoteItemMerge {
    /// The row to save, or nil when nothing should be written.
    public static func rowToSave(stored: Item?, incoming: Item, isFirstSave: Bool) -> Item? {
        guard var row = stored else { return isFirstSave ? incoming : nil }
        guard row.deletedAt == nil, row.text != incoming.text else { return nil }
        row.text = incoming.text
        return row
    }
}

/// What a screen shows about a note being dictated.
public struct SpokenNoteRecordingSnapshot: Equatable, Sendable {
    public var note: SpokenNote
    /// A take is being recorded right now.
    public var isRecording: Bool
    /// Takes whose transcript has been asked for and has not come back.
    public var transcribingTakeIds: Set<String>
    /// Takes whose transcript failed. The audio is safe; `retryTranscript` or the next open asks again.
    public var failedTranscriptTakeIds: Set<String>
    /// A closed take whose audio is in the folder but could not be added to `note.json` yet. It is added again at the
    /// next stop, start or resume; nothing is deleted meanwhile.
    public var hasUnsavedTake: Bool
    /// Rises with every report, so a screen that receives reports out of order keeps the newest.
    public var revision: Int
}

/// Records takes into one spoken note and keeps the note, its transcripts and its Library item in step (#3108).
///
/// This is the whole recording step except the microphone and the speech recognizer, which are handed in. The order
/// protects the listener's words: a take is added to `note.json` the moment its audio is closed on disk, before any
/// transcription starts, so a transcriber that fails, or an app that is killed while it runs, leaves the audio in the
/// note. Transcripts then fill in one take at a time. It is an actor, so a stop, a start and a finishing transcript
/// never read and write `note.json` at once (`SpokenNoteIntake` does not lock; each of its calls is one step with no
/// suspension in it).
public actor SpokenNoteRecordingCoordinator {
    public enum RecordingError: Error, Equatable, Sendable {
        case alreadyRecording
        case notRecording
    }

    private let store: SpokenNoteStore
    private nonisolated let noteId: String
    private var item: Item
    /// The item as last written to the database; nil until it has been written.
    private var savedItem: Item?
    private let recorder: any SpokenNoteTakeRecording
    private let transcriber: any SpokenNoteTranscribing
    private let saveItem: @Sendable (Item, Bool) throws -> Void
    private let now: @Sendable () -> Date
    private let makeTakeId: @Sendable () -> String
    private var onChange: (@Sendable (SpokenNoteRecordingSnapshot) -> Void)?

    private var recording: (takeId: String, audioFileName: String)?
    private var transcribing: Set<String> = []
    private var failed: Set<String> = []
    private var transcriptionTasks: [String: Task<Void, Never>] = [:]
    private var revision = 0
    /// Takes closed on disk that `note.json` doesn't list yet (it couldn't be read or written at that moment).
    private var pendingTakes: [(takeId: String, audioFileName: String, durationMs: Int, createdAt: Date)] = []

    /// - Parameters:
    ///   - item: The note's Library item. It is saved with `saveItem` when the first take is added (or at once if
    ///     `itemIsSaved` is false and the note already has takes), so opening a note and leaving makes no row.
    ///   - itemIsSaved: True for a note reopened from the Library, whose row already exists.
    ///   - saveItem: Writes the item to the database. Runs on the actor's executor, never the main thread.
    public init(
        store: SpokenNoteStore,
        item: Item,
        itemIsSaved: Bool,
        recorder: any SpokenNoteTakeRecording,
        transcriber: any SpokenNoteTranscribing,
        saveItem: @escaping @Sendable (Item, Bool) throws -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        makeTakeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.noteId = store.noteId
        self.item = item
        self.savedItem = itemIsSaved ? item : nil
        self.recorder = recorder
        self.transcriber = transcriber
        self.saveItem = saveItem
        self.now = now
        self.makeTakeId = makeTakeId
        SpokenNoteLiveNotes.add(store.noteId)
    }

    deinit {
        SpokenNoteLiveNotes.remove(noteId)
    }

    public init(
        store: SpokenNoteStore,
        item: Item,
        itemIsSaved: Bool,
        recorder: any SpokenNoteTakeRecording,
        transcriber: any SpokenNoteTranscribing,
        itemWriter: any SpokenNoteItemWriting,
        now: @escaping @Sendable () -> Date = { Date() },
        makeTakeId: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.init(
            store: store, item: item, itemIsSaved: itemIsSaved, recorder: recorder, transcriber: transcriber,
            saveItem: { try itemWriter.write($0, isFirstSave: $1) }, now: now, makeTakeId: makeTakeId
        )
    }

    public func setOnChange(_ handler: (@Sendable (SpokenNoteRecordingSnapshot) -> Void)?) {
        onChange = handler
        publish()
    }

    public func snapshot() -> SpokenNoteRecordingSnapshot {
        SpokenNoteRecordingSnapshot(
            note: store.load(), isRecording: recording != nil,
            transcribingTakeIds: transcribing, failedTranscriptTakeIds: failed, hasUnsavedTake: !pendingTakes.isEmpty, revision: revision
        )
    }

    /// Starts a take. A second start while one is recording is refused, never a second recorder.
    public func startTake() async throws {
        guard recording == nil else { throw RecordingError.alreadyRecording }
        addPendingTakes()
        let takeId = makeTakeId()
        let fileName = "take-\(takeId).m4a"
        guard SpokenNoteIntake.isPlainFileName(fileName) else { throw SpokenNoteIntake.IntakeError.unsafeAudioFileName }
        // Claimed before the first suspension, so a second start can't slip in while the recorder is starting.
        recording = (takeId, fileName)
        recorder.setStoppedBySystemHandler { [weak self] in
            Task { await self?.stoppedBySystem() }
        }
        do {
            try await recorder.begin(writingTo: store.folderURL.appendingPathComponent(fileName))
        } catch {
            recording = nil
            recorder.setStoppedBySystemHandler(nil)
            publish()
            throw error
        }
        publish()
    }

    /// Stops the take, adds it to the note and starts its transcript. Returns once the audio is in the note; the
    /// transcript arrives later through `onChange`.
    @discardableResult
    public func stopTake() async throws -> SpokenNote {
        guard let take = recording else { throw RecordingError.notRecording }
        recording = nil
        recorder.setStoppedBySystemHandler(nil)
        let durationMs: Int
        do {
            durationMs = try await recorder.end()
        } catch {
            publish()
            throw error
        }
        pendingTakes.append((take.takeId, take.audioFileName, durationMs, now()))
        addPendingTakes()
        if !pendingTakes.isEmpty {
            // The audio file is still in the folder and the take is kept to be added again; nothing is deleted.
            publish()
            throw SpokenNoteIntake.IntakeError.noteUnreadable
        }
        let note = store.load()
        publish()
        return note
    }

    /// Adds every closed take that `note.json` doesn't list yet, oldest first, and starts each one's transcript. A take
    /// that still can't be added stays in the queue.
    private func addPendingTakes() {
        var remaining: [(takeId: String, audioFileName: String, durationMs: Int, createdAt: Date)] = []
        for pending in pendingTakes {
            do {
                let note = try SpokenNoteIntake.addRecordedTake(
                    audioFileName: pending.audioFileName, durationMs: pending.durationMs, to: store,
                    now: pending.createdAt, takeId: pending.takeId
                )
                syncItem(with: note)
                startTranscript(takeId: pending.takeId, audioFileName: pending.audioFileName)
            } catch {
                remaining.append(pending)
            }
        }
        pendingTakes = remaining
    }

    /// Saves the Library item if an earlier save failed. Called when the screen is done.
    public func flushItem() {
        addPendingTakes()
        syncItem(with: store.load())
        publish()
    }

    /// Asks again for the transcript of a take that has none and isn't being transcribed (a failed one).
    public func retryTranscript(forTake takeId: String) {
        let note = store.load()
        guard let take = note.takes.first(where: { $0.id == takeId }), !take.hasTranscript else { return }
        startTranscript(takeId: take.id, audioFileName: take.audioFileName)
        publish()
    }

    /// Asks for the transcript of every take that has none. Called when a note is opened, so an app killed while a
    /// transcript was running finishes it the next time.
    public func resumeTranscripts() {
        addPendingTakes()
        for take in store.load().takes where !take.hasTranscript {
            startTranscript(takeId: take.id, audioFileName: take.audioFileName)
        }
        publish()
    }

    /// Waits for every transcript asked for so far. For tests, and for a screen that wants to leave only when done.
    public func waitForTranscripts() async {
        while let task = transcriptionTasks.values.first {
            await task.value
        }
    }

    /// Removes the note's folder when nothing was ever recorded in it: no take and no file but `note.json`. A note
    /// with any take or any other file is left exactly as it is.
    @discardableResult
    public func discardIfNothingWasRecorded() -> Bool {
        guard recording == nil, store.load().isEmpty else { return false }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.folderURL.path)) ?? []
        guard names.allSatisfy({ $0 == "note.json" }) else { return false }
        return (try? FileManager.default.removeItem(at: store.folderURL)) != nil
    }

    // MARK: Steps

    private func stoppedBySystem() async {
        guard recording != nil else { return }
        _ = try? await stopTake()
    }

    /// Starts the transcript of one take, unless one is already running for it.
    private func startTranscript(takeId: String, audioFileName: String) {
        guard transcriptionTasks[takeId] == nil else { return }
        transcribing.insert(takeId)
        failed.remove(takeId)
        let url = store.folderURL.appendingPathComponent(audioFileName)
        let transcriber = self.transcriber
        transcriptionTasks[takeId] = Task { [weak self] in
            let words: [AlignedTranscriptSegment]?
            do {
                words = try await transcriber.transcribe(fileAt: url)
            } catch {
                words = nil
            }
            await self?.transcriptFinished(takeId: takeId, words: words)
        }
    }

    private func transcriptFinished(takeId: String, words: [AlignedTranscriptSegment]?) {
        transcriptionTasks[takeId] = nil
        transcribing.remove(takeId)
        if let words {
            do {
                let note = try SpokenNoteIntake.applyTranscript(words: words, forTake: takeId, in: store)
                syncItem(with: note)
            } catch {
                // `note.json` couldn't be read or written just now. The audio is safe; asking again later fills it in.
                failed.insert(takeId)
            }
        } else {
            failed.insert(takeId)
        }
        syncItem(with: store.load())
        publish()
    }

    /// Brings the Library item's text up to date with the note and saves it. The row is created with the first take.
    private func syncItem(with note: SpokenNote) {
        item = SpokenNoteIntake.updatedItem(item, for: note)
        guard !note.isEmpty, savedItem != item else { return }
        do {
            try saveItem(item, savedItem == nil)
            savedItem = item
        } catch {
            // The note is safe in its own file. The next change tries to save the row again (`savedItem` is unchanged).
        }
    }

    private func publish() {
        revision += 1
        onChange?(snapshot())
    }
}
