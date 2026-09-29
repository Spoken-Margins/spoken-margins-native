import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// New code acting on a Library Build 29 left behind must keep each item's completion
/// and progress (#352). Build29DatabaseFixtureTests and PriorBuildPersistenceTests prove
/// the stores open each other's data; this proves the engine doesn't rewrite old rows'
/// invariants when it saves through fields Build 29 left empty, as #293 did.
final class Build29UpgradeProgressTests: XCTestCase {
    /// Contracts/fixtures/persistence/build29.sqlite was written by Build 29's own
    /// SessionKit (scripts/fixtures/generate-build29-podcasts.swift): podcasts with and
    /// without a stored length, a finished episode and an article, each with Margins.
    func testEveryMarginAndSeekOnABuild29LibraryKeepsCompletionAndProgress() throws {
        let store = try SQLiteSessionStore(path: try copyOfBuild29Library())
        let audio = StreamNotYetMeasuredAudioClient()
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
            "sync": ["canonical_persistence"], "playback": ["native_media", "realtime_tts"],
        ]), repository: store, audio: audio)

        let items = try store.listItems(includeDeleted: true)
        let before = Dictionary(uniqueKeysWithValues: try items.map { ($0.id, try store.loadItem(id: $0.id).sourceCompletedAt) })
        let sessions = try store.loadSessions().sorted { $0.id < $1.id }
        let percentBefore = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.completionPercent) })
        var marginsPlayed = 0
        XCTAssertTrue(items.contains { $0.media?.sourceType == .remoteStream && $0.media?.durationMs == nil },
                      "the fixture must hold a podcast with no stored length, or this test proves nothing")

        func check(_ session: Session, after step: String) throws {
            XCTAssertEqual(try store.loadItem(id: session.itemId).sourceCompletedAt, before[session.itemId] ?? nil,
                           "\(session.itemId): completion changed after \(step)")
            let percent = try XCTUnwrap(store.loadSession(id: session.id)).completionPercent
            XCTAssertLessThan(abs(percent - (percentBefore[session.id] ?? 0)), 50,
                              "\(session.itemId): progress jumped from \(percentBefore[session.id] ?? 0)% to \(percent)% after \(step)")
        }

        for session in sessions {
            for margin in try store.loadInterjections(sessionId: session.id).sorted(by: { $0.id < $1.id }) {
                _ = try engine.playInterjectionAnchor(margin)
                marginsPlayed += 1
                try check(session, after: "playing Margin \(margin.id)")

                if let mediaTimeMs = margin.anchor.mediaTimeMs {
                    _ = try engine.seekMedia(toMediaTimeMs: mediaTimeMs + 60_000)
                } else {
                    _ = try engine.seekText(toCharOffset: margin.anchor.endChar)
                }
                try check(session, after: "a seek past Margin \(margin.id)")
            }
        }
        XCTAssertEqual(marginsPlayed, 7, "every Margin in the fixture was played")
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    private func copyOfBuild29Library() throws -> String {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw NSError(domain: "Build29Library", code: 1, userInfo: [NSLocalizedDescriptionKey: "Repository root unavailable"]) }
            root = parent
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("build29-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Contracts/fixtures/persistence/build29.sqlite"), to: copy)
        return copy.path
    }
}

/// A player that has opened a stream but not yet learned its length, the state every
/// podcast is in right after an upgrade. It reports the target it plays, and a length
/// only once a test sets one.
private final class StreamNotYetMeasuredAudioClient: AudioPlaybackClient {
    var activeTargetId: String?
    var mediaTimeMs: Int?
    var durationMs: Int?
    var completedTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { activeTargetId = targetId }
    func play(targetId: String, from charOffset: Int) throws { activeTargetId = targetId }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        self.mediaTimeMs = mediaTimeMs
    }
    func seek(toMediaTimeMs mediaTimeMs: Int) throws { self.mediaTimeMs = mediaTimeMs }
    func currentPlaybackPosition() -> PlaybackPosition? {
        guard let activeTargetId else { return nil }
        return PlaybackPosition(targetId: activeTargetId, mediaTimeMs: mediaTimeMs, durationMs: durationMs)
    }
    func currentCharOffset() -> Int? { nil }
    func currentMediaTimeMs() -> Int? { mediaTimeMs }
    func isPlaybackComplete(targetId: String) -> Bool { completedTargetId == targetId }
    func pause() throws {}
    func stop() throws {}
}
