import Foundation
import XCTest
import SessionKitAudio

final class SourceTranscriptionCachesTests: XCTestCase {
    private func withCaches(_ body: (URL) throws -> Void) throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: caches) }
        try body(caches)
    }

    private func seed(_ caches: URL, itemId: String) throws {
        for folder in ["SourceAudioTranscriptionChunksV3", "SourceAudioTranscriptionWindows"] {
            let directory = caches.appendingPathComponent("\(folder)/\(itemId)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("cached audio".utf8).write(to: directory.appendingPathComponent("audio.m4a"))
        }
    }

    func testPurgeRemovesBothFoldersForOnlyRequestedItem() throws {
        try withCaches { caches in
            try seed(caches, itemId: "episode")
            try seed(caches, itemId: "episode-other")
            try SourceTranscriptionCaches.purge(itemId: "episode", cachesDirectory: caches)
            for folder in ["SourceAudioTranscriptionChunksV3", "SourceAudioTranscriptionWindows"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("\(folder)/episode").path))
                XCTAssertEqual(
                    try Data(contentsOf: caches.appendingPathComponent("\(folder)/episode-other/audio.m4a")),
                    Data("cached audio".utf8)
                )
            }
            // Missing cache folders remain a successful no-op.
            try SourceTranscriptionCaches.purge(itemId: "episode", cachesDirectory: caches)
        }
    }

    func testRawItemIDsAndWindowLayoutStayUnchanged() throws {
        try withCaches { caches in
            for itemId in ["episode", "Raw ID: É/segment", ""] {
                XCTAssertEqual(
                    SourceTranscriptionCaches.directory(for: .chunks, itemId: itemId, cachesDirectory: caches),
                    caches.appending(path: "SourceAudioTranscriptionChunksV3/\(itemId)", directoryHint: .isDirectory)
                )
                XCTAssertEqual(
                    SourceTranscriptionCaches.directory(for: .windows, itemId: itemId, cachesDirectory: caches),
                    caches.appending(path: "SourceAudioTranscriptionWindows/\(itemId)", directoryHint: .isDirectory)
                )
            }
            // Pin both the export and evidence lookup paths without invoking speech recognition.
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let adapters = try String(contentsOf: package.appendingPathComponent("Sources/SessionKitAudio/AudioAdapters.swift"), encoding: .utf8)
            XCTAssertEqual(adapters.components(separatedBy: #"appending(path: "window-\(anchorMediaTimeMs)-v3", directoryHint: .isDirectory)"#).count - 1, 2)
        }
    }

    func testScratchRemovalLeavesChunksAndThrowsOnMissingFolder() throws {
        try withCaches { caches in
            try seed(caches, itemId: "scratch")
            try SourceTranscriptionCaches.remove(.windows, itemId: "scratch", cachesDirectory: caches)
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("SourceAudioTranscriptionWindows/scratch").path))
            XCTAssertEqual(
                try Data(contentsOf: caches.appendingPathComponent("SourceAudioTranscriptionChunksV3/scratch/audio.m4a")),
                Data("cached audio".utf8)
            )
            XCTAssertThrowsError(try SourceTranscriptionCaches.remove(.windows, itemId: "scratch", cachesDirectory: caches))
        }
    }

    func testPurgePropagatesDeletionFailure() throws {
        try withCaches { caches in
            try seed(caches, itemId: "episode")
            let chunks = caches.appendingPathComponent("SourceAudioTranscriptionChunksV3")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: chunks.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chunks.path) }
            XCTAssertThrowsError(try SourceTranscriptionCaches.purge(itemId: "episode", cachesDirectory: caches))
            // The throwing caller stops at the first failure.
            XCTAssertTrue(FileManager.default.fileExists(atPath: caches.appendingPathComponent("SourceAudioTranscriptionWindows/episode/audio.m4a").path))
        }
    }
}
