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
}
#endif
