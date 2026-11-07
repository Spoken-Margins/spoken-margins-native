import XCTest
@testable import SessionKit

/// #3660: Export gets a spoken note's audio (every take as one file) and transcript out of the app, from real files in a
/// real temporary folder. The audio join itself is AVFoundation's and is tested with real audio in SessionKitTests
/// (`SpokenNoteAudioJoinerTests`); here the joiner only records what it was asked to join.
final class SpokenNoteExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private struct RecordingJoiner: SpokenNoteAudioJoining {
        let joined = Box()
        final class Box: @unchecked Sendable { var sources: [[URL]] = [] }
        func join(_ sources: [URL], to destination: URL) async throws {
            joined.sources.append(sources)
            try Data("joined:\(sources.map(\.lastPathComponent).joined(separator: ","))".utf8).write(to: destination)
        }
    }

    private struct FailingJoiner: SpokenNoteAudioJoining {
        func join(_ sources: [URL], to destination: URL) async throws {
            try Data("half".utf8).write(to: destination)
            throw SpokenNoteExportError.nothingToExport
        }
    }

    private func take(_ id: String, sentences: [String] = [], writeAudio: Bool = true, in folder: URL) throws -> SpokenNoteTake {
        if writeAudio { try Data("audio-\(id)".utf8).write(to: folder.appendingPathComponent("\(id).m4a")) }
        return SpokenNoteTake(
            id: id, audioFileName: "\(id).m4a", durationMs: 4000, createdAt: Date(timeIntervalSince1970: 0),
            sentences: sentences.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 1000, endMs: $0 * 1000 + 900) })
    }

    private func noteFolder() throws -> URL {
        let folder = root.appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }

    // MARK: transcript

    func testTheTranscriptKeepsEverySentenceWithABlankLineBetweenTakes() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["First idea.", "Second idea."], in: folder))
        note.appendTake(try take("b", sentences: [], in: folder))
        note.appendTake(try take("c", sentences: ["Third idea."], in: folder))
        XCTAssertEqual(SpokenNoteExport.transcriptText(of: note), "First idea. Second idea.\n\nThird idea.")
        XCTAssertEqual(SpokenNoteExport.transcriptText(of: SpokenNote(id: "empty")), "")
    }

    // MARK: file names, a table of neighbouring titles

    func testFileBaseNames() {
        let long = String(repeating: "word ", count: 60)
        let cases: [(String, String)] = [
            ("Trip ideas", "Trip ideas"),
            ("  Trip   ideas \n", "Trip ideas"),
            ("Ideas: 10/12 \"draft\"?", "Ideas 10 12 draft"),
            ("a/b\\c", "a b c"),
            ("../../etc/passwd", "etc passwd"),
            (".hidden", "hidden"),
            ("Café ☕️ 会議メモ", "Café ☕️ 会議メモ"),
            ("e\u{301}tude", "e\u{301}tude"),
            ("", "Spoken note"),
            ("   ", "Spoken note"),
            ("???", "Spoken note"),
            ("...", "Spoken note"),
            ("tab\there\u{7}bell", "tab here bell"),
            (String(long.prefix(300)), String(long.prefix(SpokenNoteExport.maxBaseNameCharacters)).trimmingCharacters(in: .whitespaces)),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(SpokenNoteExport.fileBaseName(forTitle: title), expected, "title: \(title.debugDescription)")
        }
        XCTAssertEqual(SpokenNoteExport.fileBaseName(forTitle: "", fallback: "???"), "Spoken note", "an unusable fallback still gives a name")
    }

    func testAVeryLongTitleMakesAShortFileNameStem() {
        XCTAssertLessThanOrEqual(SpokenNoteExport.fileBaseName(forTitle: String(repeating: "é", count: 5000)).count, SpokenNoteExport.maxBaseNameCharacters)
    }

    // MARK: prepare

    func testOneTakeCopiesItsOwnFileAndWritesTheTranscript() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hello there."], in: folder))
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "Trip ideas", noteFolder: folder, into: exports, joiner: joiner)

        XCTAssertEqual(files.audioURL?.lastPathComponent, "Trip ideas.m4a")
        XCTAssertEqual(files.transcriptURL?.lastPathComponent, "Trip ideas.txt")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.audioURL)), Data("audio-a".utf8), "the take's bytes, not re-encoded")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.transcriptURL), encoding: .utf8), "Hello there.")
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertTrue(joiner.joined.sources.isEmpty, "a single take is never run through the joiner")
        XCTAssertEqual(files.missingAudioTakeCount, 0)
        XCTAssertTrue(files.folderURL.path.hasPrefix(exports.path))
    }

    func testSeveralTakesAreJoinedInOrderIntoOneFile() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        for id in ["a", "b", "c"] { note.appendTake(try take(id, sentences: ["Take \(id)."], in: folder)) }
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "Long note", noteFolder: folder, into: exports, joiner: joiner)

        XCTAssertEqual(joiner.joined.sources.first?.map(\.lastPathComponent), ["a.m4a", "b.m4a", "c.m4a"])
        XCTAssertEqual(files.audioURL?.lastPathComponent, "Long note.m4a")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.transcriptURL), encoding: .utf8), "Take a.\n\nTake b.\n\nTake c.")
    }

    func testAMissingTakeIsLeftOutAndCounted() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", in: folder))
        note.appendTake(try take("gone", writeAudio: false, in: folder))
        note.appendTake(try take("c", in: folder))
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: joiner)
        XCTAssertEqual(joiner.joined.sources.first?.map(\.lastPathComponent), ["a.m4a", "c.m4a"])
        XCTAssertEqual(files.missingAudioTakeCount, 1)
        XCTAssertNil(files.transcriptURL, "no transcript yet means no text file")
    }

    func testATranscriptAloneIsExportedWhenTheAudioIsGone() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Only words."], writeAudio: false, in: folder))
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertNil(files.audioURL)
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["N.txt"])
        XCTAssertEqual(files.missingAudioTakeCount, 1)
    }

    func testNothingToExportThrowsAndLeavesNoFolder() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", writeAudio: false, in: folder))
        do {
            _ = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
            XCTFail("expected nothingToExport")
        } catch {
            XCTAssertEqual(error as? SpokenNoteExportError, .nothingToExport)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path), "nothing is created for an empty note")
        do {
            _ = try await SpokenNoteExport.prepare(note: SpokenNote(id: "empty"), title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
            XCTFail("an empty note has nothing to export")
        } catch {
            XCTAssertEqual(error as? SpokenNoteExportError, .nothingToExport)
        }
    }

    func testAFailedJoinLeavesNoHalfMadeFolder() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", in: folder))
        note.appendTake(try take("b", in: folder))
        do {
            _ = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: FailingJoiner())
            XCTFail("the join failed")
        } catch {}
        let left = (try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? []
        XCTAssertEqual(left, [], "the folder made for this export is removed")
    }

    func testExportNeverTouchesTheNotesOwnFiles() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hi."], in: folder))
        note.appendTake(try take("b", sentences: ["There."], in: folder))
        func snapshot() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: folder.path).map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
        }
        let before = try snapshot()
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertEqual(try snapshot(), before)
        files.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folderURL.path), "discard removes the export folder")
        XCTAssertEqual(try snapshot(), before, "discarding the export leaves the note as it was")
    }

    func testTwoExportsOfTheSameNoteDoNotShareAFolder() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hi."], in: folder))
        let first = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        let second = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertNotEqual(first.folderURL, second.folderURL)
        first.discard()
        XCTAssertNotNil(second.audioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }
}
