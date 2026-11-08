import XCTest
@testable import SessionKit

/// #3662: a spoken note plays whole, start to finish, through the shared playback. These are the parts that are logic:
/// how takes line up on the joined audio's clock, which sentence is sounding at a time, and when the joined file is made
/// again. They run on real files in a real temporary folder. The join itself is AVFoundation's; here a joiner reports what
/// it laid down, and `SpokenNoteAudioJoinerTests` (SessionKitTests) joins real audio.
final class SpokenNoteWholePlaybackTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-whole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: fakes

    /// Lays sources end to end, each as long as `lengths` says (the joined file's own measure, not the recorder's).
    private final class FakeJoiner: SpokenNoteMeasuredAudioJoining, @unchecked Sendable {
        var calls: [[String]] = []
        var lengths: [String: Int] = [:]
        var unreadable: Set<String> = []
        var failing = false

        func joinMeasured(_ sources: [URL], to destination: URL) async throws -> SpokenNoteJoinMeasurement {
            calls.append(sources.map(\.lastPathComponent))
            if failing {
                try Data("half".utf8).write(to: destination)
                throw CocoaError(.fileWriteUnknown)
            }
            var cursor = 0
            var placements: [SpokenNoteJoinMeasurement.Placement] = []
            for (index, source) in sources.enumerated() where !unreadable.contains(source.lastPathComponent) {
                let length = lengths[source.lastPathComponent] ?? 4000
                placements.append(.init(sourceIndex: index, startMs: cursor, durationMs: length))
                cursor += length
            }
            guard !placements.isEmpty else { throw CocoaError(.fileReadUnknown) }
            try Data("joined#\(calls.count):\(sources.map(\.lastPathComponent).joined(separator: ","))".utf8).write(to: destination)
            return SpokenNoteJoinMeasurement(placements: placements, durationMs: cursor)
        }
    }

    private final class RecordingWriter: SpokenNotePlaybackWriting, @unchecked Sendable {
        struct Call { let itemId: String; let audioURL: URL; let durationMs: Int; let timeline: MediaTimeline; let text: String }
        var calls: [Call] = []
        var hasRow = true
        func attachPlayback(itemId: String, audioURL: URL, durationMs: Int, timeline: MediaTimeline, text: String) throws -> Bool {
            guard hasRow else { return false }
            calls.append(Call(itemId: itemId, audioURL: audioURL, durationMs: durationMs, timeline: timeline, text: text))
            return true
        }
    }

    private func take(_ id: String, _ sentences: [String], writeAudio: Bool = true, in folder: URL) throws -> SpokenNoteTake {
        if writeAudio { try Data("audio-\(id)".utf8).write(to: folder.appendingPathComponent("take-\(id).m4a")) }
        return SpokenNoteTake(
            id: id, audioFileName: "take-\(id).m4a", durationMs: 4000, createdAt: Date(timeIntervalSince1970: 0),
            sentences: sentences.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 1000, endMs: $0 * 1000 + 900) })
    }

    private func makeStore(takes: [(String, [String])], missingAudio: Set<String> = []) throws -> SpokenNoteStore {
        let folder = root.appendingPathComponent("note-1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var note = SpokenNote(id: "note-1")
        for (id, sentences) in takes {
            note.appendTake(try take(id, sentences, writeAudio: !missingAudio.contains(id), in: folder))
        }
        let store = SpokenNoteStore(folderURL: folder, noteId: "note-1")
        try store.save(note)
        return store
    }

    private func append(_ id: String, _ sentences: [String], to store: SpokenNoteStore) throws {
        var note = store.load()
        note.appendTake(try take(id, sentences, in: store.folderURL))
        try store.save(note)
    }

    // MARK: take-to-take sequencing and position mapping

    func testTakesLineUpOnTheJoinedClockByTheLengthsTheJoinUsed() async throws {
        let store = try makeStore(takes: [("a", ["One.", "Two."]), ("b", ["Three.", "Four."])])
        let joiner = FakeJoiner()
        // The recorder said 4000 ms for each; the joined file's own measure differs, and the offsets must follow it.
        joiner.lengths = ["take-a.m4a": 3100, "take-b.m4a": 2000]
        let prepared = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())

        XCTAssertEqual(prepared.durationMs, 5100)
        XCTAssertEqual(prepared.timeline.entries.map(\.startMs), [0, 1000, 3100, 4100])
        XCTAssertEqual(prepared.timeline.entries.map(\.endMs), [900, 1900, 4000, 5000])
        XCTAssertEqual(prepared.timeline.entries.map(\.text), ["One.", "Two.", "Three.", "Four."])
    }

    func testTheSentenceSoundingAtATimeIsTheLastOneThatStarted() async throws {
        let store = try makeStore(takes: [("a", ["One.", "Two."]), ("b", ["Three."])])
        let joiner = FakeJoiner()
        joiner.lengths = ["take-a.m4a": 3000, "take-b.m4a": 2000]
        let timeline = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter()).timeline

        let cases: [(Int, SpokenNote.SentenceRef?)] = [
            (0, .init(takeIndex: 0, sentenceIndex: 0)),
            (899, .init(takeIndex: 0, sentenceIndex: 0)),
            (950, .init(takeIndex: 0, sentenceIndex: 0)),    // the pause after a sentence keeps it lit
            (1000, .init(takeIndex: 0, sentenceIndex: 1)),
            (2999, .init(takeIndex: 0, sentenceIndex: 1)),   // the tail of a take
            (3000, .init(takeIndex: 1, sentenceIndex: 0)),   // the first instant of the next take
            (4999, .init(takeIndex: 1, sentenceIndex: 0)),
            (99_999, .init(takeIndex: 1, sentenceIndex: 0))  // past the end: still the last
        ]
        for (ms, expected) in cases {
            XCTAssertEqual(timeline.ref(atMs: ms), expected, "at \(ms) ms")
        }
    }

    func testEverySentenceStartMapsBackToItself() async throws {
        let store = try makeStore(takes: [("a", ["One.", "Two.", "Three."]), ("b", ["Four.", "Five."]), ("c", ["Six."])])
        let joiner = FakeJoiner()
        joiner.lengths = ["take-a.m4a": 3300, "take-b.m4a": 2100, "take-c.m4a": 1500]
        let timeline = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter()).timeline
        XCTAssertEqual(timeline.entries.count, 6)
        for entry in timeline.entries {
            XCTAssertEqual(timeline.startMs(of: entry.ref), entry.startMs)
            XCTAssertEqual(timeline.ref(atMs: entry.startMs), entry.ref)
        }
        XCTAssertNil(timeline.ref(atMs: -1))
        XCTAssertNil(timeline.startMs(of: .init(takeIndex: 9, sentenceIndex: 0)))
    }

    func testASentenceBeforeTheFirstOneIsNotLit() async throws {
        // A take whose first sentence starts after a lead-in: before it, nothing is lit.
        let folder = root.appendingPathComponent("lead", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("take-a.m4a"))
        var note = SpokenNote(id: "lead")
        note.appendTake(SpokenNoteTake(
            id: "a", audioFileName: "take-a.m4a", durationMs: 4000, createdAt: Date(),
            sentences: [SpokenNoteSentence(text: "Late.", startMs: 700, endMs: 1500)]))
        let store = SpokenNoteStore(folderURL: folder, noteId: "lead")
        try store.save(note)
        let timeline = try await SpokenNoteWholePlayback.prepare(store: store, joiner: FakeJoiner(), writer: RecordingWriter()).timeline
        XCTAssertNil(timeline.ref(atMs: 0))
        XCTAssertNil(timeline.ref(atMs: 699))
        XCTAssertEqual(timeline.ref(atMs: 700), .init(takeIndex: 0, sentenceIndex: 0))
    }

    func testATakeTheSystemCouldNotReadLeavesAHoleNotAShift() async throws {
        let store = try makeStore(takes: [("a", ["One."]), ("b", ["Broken."]), ("c", ["Three."])])
        let joiner = FakeJoiner()
        joiner.unreadable = ["take-b.m4a"]
        joiner.lengths = ["take-a.m4a": 2000, "take-c.m4a": 2500]
        let prepared = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
        // Take c starts right after take a, because b is not in the file; b's words have no audio and no entry.
        XCTAssertEqual(prepared.timeline.entries.map(\.text), ["One.", "Three."])
        XCTAssertEqual(prepared.timeline.entries.map(\.startMs), [0, 2000])
        XCTAssertEqual(prepared.durationMs, 4500)
        // The words are the whole note's, and every entry's offsets point at its own words in them.
        XCTAssertEqual(prepared.timeline.text, "One. Broken. Three.")
    }

    func testEntryOffsetsPointAtTheirOwnWordsInTheNotesText() async throws {
        let sentences = ["Plain.", "Emoji 👩‍👩‍👧 family.", "  padded with spaces  ", "Ünïcödé, é (decomposed).", "Last"]
        let store = try makeStore(takes: [("a", Array(sentences.prefix(3))), ("b", Array(sentences.suffix(2)))])
        let note = store.load()
        let timeline = try await SpokenNoteWholePlayback.prepare(store: store, joiner: FakeJoiner(), writer: RecordingWriter()).timeline
        XCTAssertEqual(timeline.text, note.text)
        XCTAssertEqual(timeline.entries.count, 5)
        for entry in timeline.entries {
            let slice = String(note.text.dropFirst(entry.startChar).prefix(entry.endChar - entry.startChar))
            XCTAssertEqual(slice, entry.text)
        }
        XCTAssertEqual(timeline.mediaTimeline.segments.map(\.startChar), timeline.entries.map(\.startChar))
    }

    func testASentenceStartingAfterItsTakesAudioEndsHasNothingToPlay() async throws {
        let store = try makeStore(takes: [("a", ["One.", "Two.", "Three."])])
        let joiner = FakeJoiner()
        joiner.lengths = ["take-a.m4a": 1500]   // the joined file holds only the first 1.5 s of the take
        let timeline = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter()).timeline
        XCTAssertEqual(timeline.entries.map(\.text), ["One.", "Two."])
        XCTAssertEqual(timeline.entries.last?.endMs, 1500)   // clamped to the audio
    }

    // MARK: when the joined file is made

    func testTheFirstPlayJoinsTakesInOrderAndLaterPlaysReuseTheFile() async throws {
        let store = try makeStore(takes: [("a", ["One."]), ("b", ["Two."])])
        let joiner = FakeJoiner()
        let writer = RecordingWriter()

        let first = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: writer)
        XCTAssertTrue(first.rebuilt)
        XCTAssertEqual(joiner.calls, [["take-a.m4a", "take-b.m4a"]])
        XCTAssertEqual(first.audioURL, SpokenNoteWholePlayback.audioURL(inFolder: store.folderURL))
        XCTAssertNotNil(SpokenNoteWholePlayback.existingAudioURL(inFolder: store.folderURL))

        let second = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: writer)
        XCTAssertFalse(second.rebuilt)
        XCTAssertEqual(joiner.calls.count, 1, "a note that has not changed is not joined again")
        XCTAssertEqual(second.timeline, first.timeline)
        XCTAssertEqual(writer.calls.count, 2, "the item is pointed at the audio on every play, and the writer skips what is unchanged")
        XCTAssertEqual(writer.calls[0].itemId, "spoken-note-note-1")
        XCTAssertEqual(writer.calls[0].text, "One. Two.")
    }

    func testATakeAddedLaterMakesTheFileAgainAndKeepsEarlierTimes() async throws {
        let store = try makeStore(takes: [("a", ["One."])])
        let joiner = FakeJoiner()
        joiner.lengths = ["take-a.m4a": 3000, "take-b.m4a": 2000]
        let first = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())

        try append("b", ["Two."], to: store)
        let second = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
        XCTAssertTrue(second.rebuilt)
        XCTAssertEqual(joiner.calls.last, ["take-a.m4a", "take-b.m4a"])
        XCTAssertEqual(second.durationMs, 5000)
        XCTAssertEqual(second.timeline.entries.first, first.timeline.entries.first, "a take is only ever added at the end")
        let file = try String(contentsOf: SpokenNoteWholePlayback.audioURL(inFolder: store.folderURL), encoding: .utf8)
        XCTAssertTrue(file.hasPrefix("joined#2"), "the file now holds both takes: \(file)")
    }

    func testATranscriptArrivingLaterChangesTheTimelineButNotTheAudio() async throws {
        let store = try makeStore(takes: [("a", [])])   // recorded, words not yet written down
        let joiner = FakeJoiner()
        let before = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
        XCTAssertTrue(before.timeline.entries.isEmpty)
        XCTAssertEqual(before.durationMs, 4000, "a take with no words still plays")

        var note = store.load()
        XCTAssertTrue(note.setTranscript([SpokenNoteSentence(text: "Now written.", startMs: 0, endMs: 900)], forTake: "a"))
        try store.save(note)
        let after = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
        XCTAssertFalse(after.rebuilt)
        XCTAssertEqual(joiner.calls.count, 1)
        XCTAssertEqual(after.timeline.entries.map(\.text), ["Now written."])
    }

    func testATakeWhoseAudioIsGoneIsLeftOutAndNotAskedFor() async throws {
        let store = try makeStore(takes: [("a", ["One."]), ("b", ["Gone."]), ("c", ["Three."])], missingAudio: ["b"])
        let joiner = FakeJoiner()
        let prepared = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
        XCTAssertEqual(joiner.calls, [["take-a.m4a", "take-c.m4a"]])
        XCTAssertEqual(prepared.timeline.entries.map(\.text), ["One.", "Three."])
    }

    func testAFailedJoinLeavesThePreviousFileInPlaceAndNoLeftovers() async throws {
        let store = try makeStore(takes: [("a", ["One."])])
        let joiner = FakeJoiner()
        _ = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
        let audio = SpokenNoteWholePlayback.audioURL(inFolder: store.folderURL)
        let before = try Data(contentsOf: audio)

        try append("b", ["Two."], to: store)
        joiner.failing = true
        do {
            _ = try await SpokenNoteWholePlayback.prepare(store: store, joiner: joiner, writer: RecordingWriter())
            XCTFail("a failed join must throw")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: audio), before)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folderURL.path)
        XCTAssertFalse(names.contains { $0.contains(".tmp-") }, "no half-made file is left: \(names)")
    }

    func testTheTakesAreNeverChanged() async throws {
        let store = try makeStore(takes: [("a", ["One."]), ("b", ["Two."])])
        let before = try ["take-a.m4a", "take-b.m4a", "note.json"].map { try Data(contentsOf: store.folderURL.appendingPathComponent($0)) }
        _ = try await SpokenNoteWholePlayback.prepare(store: store, joiner: FakeJoiner(), writer: RecordingWriter())
        let after = try ["take-a.m4a", "take-b.m4a", "note.json"].map { try Data(contentsOf: store.folderURL.appendingPathComponent($0)) }
        XCTAssertEqual(before, after)
    }

    // MARK: what it refuses

    func testANoteWithNoAudioCannotBePrepared() async throws {
        let store = try makeStore(takes: [("a", ["One."])], missingAudio: ["a"])
        do {
            _ = try await SpokenNoteWholePlayback.prepare(store: store, joiner: FakeJoiner(), writer: RecordingWriter())
            XCTFail("no audio on the phone")
        } catch {
            XCTAssertEqual(error as? SpokenNoteWholePlayback.PrepareError, .noAudio)
        }
    }

    func testAnUnreadableNoteFileIsLeftExactlyAsItIs() async throws {
        let store = try makeStore(takes: [("a", ["One."])])
        try Data("not json".utf8).write(to: store.fileURL)
        do {
            _ = try await SpokenNoteWholePlayback.prepare(store: store, joiner: FakeJoiner(), writer: RecordingWriter())
            XCTFail("an unreadable note can't be played")
        } catch {
            XCTAssertEqual(error as? SpokenNoteWholePlayback.PrepareError, .noteUnreadable)
        }
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.setAsideURL.path), "playing never sets a note file aside")
    }

    func testANoteWithoutALibraryRowIsNotPlayed() async throws {
        let store = try makeStore(takes: [("a", ["One."])])
        let writer = RecordingWriter()
        writer.hasRow = false
        do {
            _ = try await SpokenNoteWholePlayback.prepare(store: store, joiner: FakeJoiner(), writer: writer)
            XCTFail("a trashed or unsaved note has no row to play")
        } catch {
            XCTAssertEqual(error as? SpokenNoteWholePlayback.PrepareError, .itemGone)
        }
    }

    func testATakeNamedLikeTheJoinedFileIsNeverJoinedIntoItself() throws {
        let store = try makeStore(takes: [("a", ["One."])])
        var note = store.load()
        try Data("x".utf8).write(to: store.folderURL.appendingPathComponent(SpokenNoteWholePlayback.audioFileName))
        note.appendTake(SpokenNoteTake(id: "evil", audioFileName: SpokenNoteWholePlayback.audioFileName, durationMs: 1, createdAt: Date()))
        XCTAssertEqual(SpokenNoteWholePlayback.requestedTakes(of: note, inFolder: store.folderURL).map(\.id), ["a"])
    }

    // MARK: neighbours of the feature

    func testLaunchRecoveryDoesNotMistakeTheJoinedFileForALostTake() async throws {
        let support = root.appendingPathComponent("support-recovery", isDirectory: true)
        let started = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { "n2" })
        var note = started.note
        try Data("a".utf8).write(to: started.store.folderURL.appendingPathComponent("take-a.m4a"))
        note.appendTake(SpokenNoteTake(id: "a", audioFileName: "take-a.m4a", durationMs: 1000, createdAt: Date()))
        try started.store.save(note)
        _ = try await SpokenNoteWholePlayback.prepare(store: started.store, joiner: FakeJoiner(), writer: RecordingWriter())
        XCTAssertNotNil(SpokenNoteWholePlayback.existingAudioURL(inFolder: started.store.folderURL))

        struct NoWrites: SpokenNoteItemWriting {
            func write(_ item: Item, isFirstSave: Bool) throws { XCTFail("recovery found a take that is not there") }
        }
        let recovered = SpokenNoteRecovery.recover(
            in: support, now: Date(), measureDurationMs: { _ in 1 }, itemWriter: NoWrites(), liveNoteIds: [])
        XCTAssertEqual(recovered, [])
    }

    func testPlaybackURLNeedsAPreparedNote() async throws {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let started = try SpokenNoteStarter.start(in: support, now: Date(), makeId: { "n1" })
        var note = started.note
        try Data("a".utf8).write(to: started.store.folderURL.appendingPathComponent("take-a.m4a"))
        note.appendTake(SpokenNoteTake(id: "a", audioFileName: "take-a.m4a", durationMs: 1000, createdAt: Date(),
                                       sentences: [SpokenNoteSentence(text: "Hi.", startMs: 0, endMs: 500)]))
        try started.store.save(note)

        var item = SpokenNoteItem.makeItem(note: note, createdAt: Date())
        XCTAssertNil(SpokenNoteWholePlayback.playbackURL(for: item, applicationSupport: support), "no media attached yet: never read aloud")

        _ = try await SpokenNoteWholePlayback.prepare(store: started.store, joiner: FakeJoiner(), writer: RecordingWriter())
        item.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///anything", durationMs: 4000)
        XCTAssertEqual(
            SpokenNoteWholePlayback.playbackURL(for: item, applicationSupport: support)?.lastPathComponent, "whole-note.m4a")

        var other = item
        other.mediaType = "audiobook"
        XCTAssertNil(SpokenNoteWholePlayback.playbackURL(for: other, applicationSupport: support))
        var unsafe = item
        unsafe.externalReference = "note://../escape"
        XCTAssertNil(SpokenNoteWholePlayback.playbackURL(for: unsafe, applicationSupport: support))
    }
}
