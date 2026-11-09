#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #3660: Export joins a note's takes with the system's audio engine. Real AAC takes, a real join, then the result is
/// opened and measured. Runs on macOS and in the app-hosted tests; the file handling around it is in
/// `SpokenNoteExportTests` (Linux too).
final class SpokenNoteAudioJoinerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-join-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func take(_ name: String, seconds: Int, seed: UInt64) throws -> URL {
        let url = root.appendingPathComponent(name)
        try SeededNoiseAudio.write(to: url, seconds: seconds, seed: seed)
        return url
    }

    func testThreeTakesJoinIntoOneFileAsLongAsTheirSum() async throws {
        let sources = [try take("a.m4a", seconds: 2, seed: 1), try take("b.m4a", seconds: 3, seed: 2), try take("c.m4a", seconds: 1, seed: 3)]
        let before = try sources.map { try Data(contentsOf: $0) }
        let destination = root.appendingPathComponent("joined.m4a")

        let skipped = try await SpokenNoteAudioJoiner().join(sources, to: destination)

        XCTAssertEqual(skipped, 0)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.3, "2 + 3 + 1 seconds, end to end")
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, before, "the takes are read, never changed")
    }

    func testAnUnreadableTakeIsLeftOutAndCountedAndTheRestJoin() async throws {
        let first = try take("a.m4a", seconds: 2, seed: 1)
        let bad = root.appendingPathComponent("b.m4a")
        try Data("not audio".utf8).write(to: bad)
        let last = try take("c.m4a", seconds: 2, seed: 3)
        let destination = root.appendingPathComponent("joined.m4a")

        let skipped = try await SpokenNoteAudioJoiner().join([first, bad, last], to: destination)

        XCTAssertEqual(skipped, 1)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.3, "the two readable takes, with no gap where the bad one was")
    }

    func testWhenNoTakeIsReadableTheJoinFails() async throws {
        let bad = root.appendingPathComponent("b.m4a")
        try Data("not audio".utf8).write(to: bad)
        do {
            _ = try await SpokenNoteAudioJoiner().join([bad, bad], to: root.appendingPathComponent("joined.m4a"))
            XCTFail("nothing readable to join")
        } catch let error as SpokenNoteAudioJoiner.JoinError {
            XCTAssertEqual(error, .noAudio)
        }
    }

    func testTheWholeExportWithRealAudio() async throws {
        let folder = root.appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try take("note/a.m4a", seconds: 2, seed: 1)
        _ = try take("note/b.m4a", seconds: 2, seed: 2)
        var note = SpokenNote(id: "n")
        for id in ["a", "b"] {
            note.appendTake(SpokenNoteTake(
                id: id, audioFileName: "\(id).m4a", durationMs: 2000, createdAt: Date(timeIntervalSince1970: 0),
                sentences: [SpokenNoteSentence(text: "Take \(id).", startMs: 0, endMs: 900)]))
        }
        let files = try await SpokenNoteExport.prepare(
            note: note, title: "Trip ideas", noteFolder: folder, into: root.appendingPathComponent("exports"), joiner: SpokenNoteAudioJoiner())
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["Trip ideas.m4a", "Trip ideas.txt"])
        let duration = try await AVURLAsset(url: XCTUnwrap(files.audioURL)).load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.3)
    }

    // MARK: #3662, whole-note playback

    func testTheMeasuredJoinPlacesEachTakeWhereTheJoinedFileHasIt() async throws {
        let bad = root.appendingPathComponent("b.m4a")
        try Data("not audio".utf8).write(to: bad)
        let sources = [try take("a.m4a", seconds: 2, seed: 1), bad, try take("c.m4a", seconds: 3, seed: 3)]
        let destination = root.appendingPathComponent("joined.m4a")

        let measurement = try await SpokenNoteAudioJoiner().joinMeasured(sources, to: destination)

        XCTAssertEqual(measurement.placements.map(\.sourceIndex), [0, 2], "the unreadable take is not placed")
        XCTAssertEqual(measurement.placements[0].startMs, 0)
        XCTAssertEqual(Double(measurement.placements[0].durationMs), 2000, accuracy: 100)
        XCTAssertEqual(measurement.placements[1].startMs, measurement.placements[0].durationMs, "the next take starts where the last ends")
        XCTAssertEqual(Double(measurement.durationMs), 5000, accuracy: 200)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        XCTAssertEqual(duration * 1000, Double(measurement.durationMs), accuracy: 300, "the measure is the file's own length")
    }

    func testAWholeNoteIsPreparedFromRealAudioAndPlaysAsOneFile() async throws {
        let folder = root.appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try take("note/take-a.m4a", seconds: 2, seed: 1)
        _ = try take("note/take-b.m4a", seconds: 2, seed: 2)
        var note = SpokenNote(id: "n")
        for id in ["a", "b"] {
            note.appendTake(SpokenNoteTake(
                id: id, audioFileName: "take-\(id).m4a", durationMs: 2000, createdAt: Date(timeIntervalSince1970: 0),
                sentences: [SpokenNoteSentence(text: "Take \(id).", startMs: 0, endMs: 900)]))
        }
        let store = SpokenNoteStore(folderURL: folder, noteId: "n")
        try store.save(note)
        struct Writer: SpokenNotePlaybackWriting {
            func attachPlayback(itemId: String, audioURL: URL, durationMs: Int, timeline: MediaTimeline, text: String) throws -> Bool { true }
        }

        let prepared = try await SpokenNoteWholePlayback.prepare(store: store, joiner: SpokenNoteAudioJoiner(), writer: Writer())

        let duration = try await AVURLAsset(url: prepared.audioURL).load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.3)
        XCTAssertEqual(prepared.timeline.entries.count, 2)
        XCTAssertEqual(Double(prepared.timeline.entries[1].startMs), 2000, accuracy: 150, "take b's first sentence starts where take a ends")
        let again = try await SpokenNoteWholePlayback.prepare(store: store, joiner: SpokenNoteAudioJoiner(), writer: Writer())
        XCTAssertFalse(again.rebuilt)
        XCTAssertEqual(again.timeline, prepared.timeline)
    }
}
#endif
