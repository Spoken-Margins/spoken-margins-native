import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

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

    /// The guard in persistSession, on its own: a stored 99% on an episode whose length
    /// is unknown (the #293 bug left such percents) doesn't complete it. Playing a Margin
    /// keeps the percent as it was, so without the guard the save stamps completion.
    func testAHighPercentWithNoKnownLengthDoesNotCompleteTheEpisode() throws {
        let (item, session, margin) = podcastInProgress(percent: 99, durationMs: nil)
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], interjections: [margin.id: margin])
        let engine = SessionEngine(profile: phoneProfile(), repository: repo, audio: StreamNotYetMeasuredAudioClient())

        _ = try engine.playInterjectionAnchor(margin)

        XCTAssertNil(try repo.loadItem(id: item.id).sourceCompletedAt)
    }

    /// A summary or reply keeps the episode's percent while it plays, so the guard must
    /// follow the item, not what is playing (Codex audit on dda72fc).
    func testPlayingASummaryOrReplyOnAnEpisodeWithNoKnownLengthDoesNotCompleteIt() throws {
        let (item, session, _) = podcastInProgress(percent: 99, durationMs: nil)
        let summary = ConversationTurn(id: "turn-summary-352", sessionId: session.id, role: "assistant", turnType: "interjection_summary", status: "complete", summary: nil, text: "Summary.", rawText: nil, sourceInterjectionIds: [])
        let reply = ConversationTurn(id: "turn-reply-352", sessionId: session.id, role: "assistant", turnType: "assistant_response", status: "complete", summary: nil, text: "Reply.", rawText: nil, sourceInterjectionIds: [])
        let repo = InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session], turns: [summary.id: summary, reply.id: reply])
        let engine = SessionEngine(profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
            "sync": ["canonical_persistence"], "playback": ["native_media", "summary_turn_tts", "assistant_turn_tts"],
        ]), repository: repo, audio: StreamNotYetMeasuredAudioClient())

        for turn in [summary, reply] {
            _ = try engine.playTurn(turnId: turn.id)
            XCTAssertNil(try repo.loadItem(id: item.id).sourceCompletedAt, "completed by playing \(turn.turnType)")
        }
    }

    func testAHighPercentOfTheEpisodesOwnPlayerLengthStillCompletesIt() throws {
        // Must not break: a stream whose length only its player knows still completes
        // once the listener reaches the end of it.
        let (item, _, _) = podcastInProgress(percent: 0, durationMs: nil)
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = StreamNotYetMeasuredAudioClient()
        let engine = SessionEngine(profile: phoneProfile(), repository: repo, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        audio.durationMs = 3_600_000

        _ = try engine.seekMedia(toMediaTimeMs: 3_590_000)

        XCTAssertNotNil(try repo.loadItem(id: item.id).sourceCompletedAt)
    }

    func testThePlayerReachingTheEndCompletesAnEpisodeWithNoKnownLength() throws {
        // Must not break: with no length anywhere, the player's own end still counts.
        let (item, _, _) = podcastInProgress(percent: 0, durationMs: nil)
        let repo = InMemorySessionRepository(items: [item.id: item])
        let audio = StreamNotYetMeasuredAudioClient()
        let engine = SessionEngine(profile: phoneProfile(), repository: repo, audio: audio)
        _ = try engine.startSession(itemId: item.id)
        audio.completedTargetId = item.media?.url

        _ = try engine.endSession()

        XCTAssertNotNil(try repo.loadItem(id: item.id).sourceCompletedAt)
    }

    private func phoneProfile() -> RuntimeCapabilityProfile {
        RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]])
    }

    private func podcastInProgress(percent: Int, durationMs: Int?) -> (Item, Session, Interjection) {
        let url = "https://cdn.example.com/352.mp3"
        let item = Item(id: "item-podcast-352", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: nil, status: "ready", media: ItemMedia(sourceType: .remoteStream, url: url, durationMs: durationMs))
        let session = Session(id: "session-podcast-352", itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia, currentTargetId: url, position: Position(mediaTimeMs: 3_560_000), completionPercent: percent, playbackRate: 1)
        let margin = Interjection(id: "ij-352", itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id, createdAt: Date(), roughPercent: percent, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 3_570_000), audioPath: "ij-352.m4a", audioStatus: "saved", transcriptionStatus: "transcribed", transcript: "Note", cleanedTranscript: nil, displayText: "Note", status: "active")
        return (item, session, margin)
    }

    private func copyOfBuild29Library() throws -> String {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("build29-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.copyItem(at: fixture, to: copy)
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
