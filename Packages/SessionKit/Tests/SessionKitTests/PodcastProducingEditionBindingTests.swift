import Foundation
import XCTest
import SessionKit
import SessionKitAudio
import SessionKitPersistence

final class PodcastProducingEditionBindingTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testActiveLocalBytesProduceStableDigestAndStreamingHasNoBinding() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("episode.mp3")
        try Data("original edition".utf8).write(to: url)
        let binding = try XCTUnwrap(LocalPlaybackFileBinding(url: url, itemId: "episode", generation: 7))
        let digest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        XCTAssertTrue(binding.stillIdentifiesFile())
        XCTAssertEqual(digest, try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: binding.url))
        XCTAssertNil(LocalPlaybackFileBinding(url: URL(string: "https://example.com/episode.mp3")!,
                                                   itemId: "episode", generation: 7))
    }

    func testReplacementAndNewPlaybackGenerationRejectOldBinding() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("episode.mp3")
        try Data("original edition".utf8).write(to: url)
        let original = try XCTUnwrap(LocalPlaybackFileBinding(url: url, itemId: "episode", generation: 7))
        let nextGeneration = try XCTUnwrap(LocalPlaybackFileBinding(url: url, itemId: "episode", generation: 8))
        XCTAssertNotEqual(original, nextGeneration, "A delayed digest cannot attach to a new player item")
        let replacement = root.appendingPathComponent("replacement.mp3")
        try Data("different edition and length".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        XCTAssertFalse(original.stillIdentifiesFile(), "A same-path replacement cannot inherit the producing identity")
    }

    func testProducingDigestSurvivesStoreReopen() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("session.sqlite").path
        let url = root.appendingPathComponent("episode.mp3")
        try Data("original edition".utf8).write(to: url)
        let digest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        do {
            let store = try SQLiteSessionStore(path: database)
            try store.saveInterjection(Interjection(
                id: "ij-001", itemId: "episode", sessionId: "session",
                targetType: .item, targetId: "episode", createdAt: Date(timeIntervalSince1970: 1),
                roughPercent: 10,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                               anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
                audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
                transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active",
                sourceExactEditionSHA256: digest
            ))
        }
        let reopened = try SQLiteSessionStore(path: database)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "session").first?.sourceExactEditionSHA256, digest)
    }
}
