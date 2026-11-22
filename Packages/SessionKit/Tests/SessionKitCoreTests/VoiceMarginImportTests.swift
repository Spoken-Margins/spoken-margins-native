import Foundation
import XCTest
@testable import SessionKit

/// #4924: an audio file handed to Add Voice Margin is refused when it can't be a Margin, else copied into the app's own
/// recordings. Real temporary files; the length is measured by the caller, so a test hands it in.
final class VoiceMarginImportTests: XCTestCase {
    private var root: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "voice-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        support = root.appending(path: "support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source(_ name: String, bytes: Int = 64) throws -> URL {
        let url = root.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func prepare(_ url: URL, ms: Int? = 4_000, id: String = "one") throws -> VoiceMarginImport.Prepared {
        try VoiceMarginImport.prepare(source: url, supportDirectory: support, durationMs: { _ in ms }, makeId: { id })
    }

    func testACopyIsKeptUnderTheRecordingsFolderAndTheSourceIsUntouched() throws {
        let url = try source("memo.m4a", bytes: 90)
        let prepared = try prepare(url)
        XCTAssertEqual(prepared.audioPath, "SpokenMargins/interjections/shortcut-voice-one.m4a")
        XCTAssertEqual(prepared.durationMs, 4_000)
        let copy = support.appending(path: prepared.audioPath)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the Shortcut's file is not moved or removed")
    }

    func testTheCopySurvivesTheShortcutDeletingItsFile() throws {
        let url = try source("memo.m4a")
        let prepared = try prepare(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appending(path: prepared.audioPath).path))
    }

    func testEveryRefusalSavesNothingAndNamesWhy() throws {
        let missing = root.appending(path: "nothing.m4a")
        let empty = try source("empty.m4a", bytes: 0)
        let ok = try source("ok.m4a")
        let table: [(String, URL, Int?, VoiceMarginImport.Refusal)] = [
            ("missing file", missing, 4_000, .unreadable),
            ("empty file", empty, 4_000, .unreadable),
            ("not audio (no length)", ok, nil, .unreadable),
            ("zero length", ok, 0, .unreadable),
            ("negative length", ok, -5, .unreadable),
            ("just over the cap", ok, VoiceMarginImport.maxDurationMs + 1, .tooLong),
            ("far over the cap", ok, 3 * 60 * 60 * 1_000, .tooLong),
        ]
        for (name, url, ms, expected) in table {
            XCTAssertThrowsError(try prepare(url, ms: ms), name) { XCTAssertEqual($0 as? VoiceMarginImport.Refusal, expected, name) }
        }
        XCTAssertEqual(files(in: support), [], "no folder or file is left behind by a refusal")
    }

    func testExactlyTheCapIsKept() throws {
        let prepared = try prepare(try source("ok.m4a"), ms: VoiceMarginImport.maxDurationMs)
        XCTAssertEqual(prepared.durationMs, 600_000)
    }

    func testTheCapIsTenMinutes() {
        XCTAssertEqual(VoiceMarginImport.maxDurationMs, 600_000)
        XCTAssertTrue(VoiceMarginImport.tooLongLine.contains("10 minutes"))
    }

    func testEachRefusalHasItsOwnPlainLine() {
        let lines = [VoiceMarginImport.Refusal.unreadable, .tooLong, .notKept].map(\.line)
        XCTAssertEqual(Set(lines).count, 3)
        XCTAssertTrue(lines.allSatisfy { $0.contains("nothing was saved") })
    }

    func testExtensionsAreKeptWhenKnownAndOtherwiseBecomeM4a() throws {
        let table: [(String, String)] = [
            ("a.M4A", "m4a"), ("a.mp3", "mp3"), ("a.WAV", "wav"), ("a.caf", "caf"), ("a.aiff", "aiff"),
            ("a", "m4a"), ("a.exe", "m4a"), ("a.m4a.exe", "m4a"), ("a..", "m4a"), (".mp3", "m4a"),
        ]
        for (index, (name, ext)) in table.enumerated() {
            let prepared = try prepare(try source(name.isEmpty ? "x" : name), id: "id\(index)")
            XCTAssertTrue(prepared.audioPath.hasSuffix(".\(ext)"), "\(name) -> \(prepared.audioPath)")
        }
    }

    func testTwoRunsOfTheSameFileMakeTwoCopiesAndNeverOverwrite() throws {
        let url = try source("memo.m4a")
        let first = try prepare(url, id: "a")
        let second = try prepare(url, id: "b")
        XCTAssertNotEqual(first.audioPath, second.audioPath)
        XCTAssertEqual(files(in: support.appending(path: "SpokenMargins/interjections")).count, 2)
    }

    func testAnIdThatAlreadyExistsIsNotOverwritten() throws {
        let first = try prepare(try source("a.m4a", bytes: 10), id: "same")
        XCTAssertThrowsError(try prepare(try source("b.m4a", bytes: 20), id: "same")) {
            XCTAssertEqual($0 as? VoiceMarginImport.Refusal, .notKept)
        }
        let kept = try Data(contentsOf: support.appending(path: first.audioPath))
        XCTAssertEqual(kept.count, 10, "the earlier recording is untouched")
    }

    func testDiscardRemovesOnlyAFileThisTypeMade() throws {
        let prepared = try prepare(try source("memo.m4a"))
        // A recording the app made, sitting beside it, is never removed.
        let own = support.appending(path: "SpokenMargins/interjections/recording-1.m4a")
        try Data(repeating: 1, count: 4).write(to: own)
        let fake = VoiceMarginImport.Prepared(audioPath: "SpokenMargins/interjections/recording-1.m4a", durationMs: 1)
        XCTAssertFalse(VoiceMarginImport.discard(fake, supportDirectory: support))
        let outside = VoiceMarginImport.Prepared(audioPath: "SpokenMargins/interjections/../shortcut-voice-x.m4a", durationMs: 1)
        XCTAssertFalse(VoiceMarginImport.discard(outside, supportDirectory: support))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(VoiceMarginImport.discard(prepared, supportDirectory: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: prepared.audioPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }
}
