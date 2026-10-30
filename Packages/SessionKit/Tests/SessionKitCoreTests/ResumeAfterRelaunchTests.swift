import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2129: the place a listener resumes from after the app is killed. The audit removed the periodic save while
/// playing and every SessionKit test stayed green, because each resume test paused first and used one engine on
/// in-memory storage. These play on a real SQLite file, drop the engine without a pause (the app killed while
/// locked), and resume from a new engine and a new store on the same file.
final class ResumeAfterRelaunchTests: XCTestCase {
    private var directory: URL!
    private var now = Date(timeIntervalSince1970: 1_000)
    private let durationMs = 3_600_000
    private let itemId = "item-resume"
    private let sessionId = "session-resume"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: path)
        let url = "file:///episodes/long.mp3"
        try store.saveItem(Item(
            id: itemId, title: "A long episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: url, durationMs: durationMs)))
        try store.saveSession(Session(
            id: sessionId, itemId: itemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: url,
            position: Position(mediaTimeMs: 60_000), completionPercent: 1, playbackRate: 1))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appending(path: "library.sqlite").path }

    /// A new store and engine on the file, as a launch builds them, with the session inspected (restored).
    private func launch() throws -> (engine: SessionEngine, audio: RelaunchAudioClient, store: SQLiteSessionStore) {
        let store = try SQLiteSessionStore(path: path)
        let audio = RelaunchAudioClient(durationMs: durationMs)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]),
            repository: store, audio: audio, playbackStartTimeout: 5, now: { [unowned self] in self.now })
        _ = try engine.inspectSession(sessionId: sessionId)
        return (engine, audio, store)
    }

    private func storedMediaTimeMs() throws -> Int? {
        try SQLiteSessionStore(path: path).loadSession(id: sessionId)?.position.mediaTimeMs
    }

    private func playing() throws -> (engine: SessionEngine, audio: RelaunchAudioClient) {
        let (engine, audio, _) = try launch()
        XCTAssertEqual(try engine.resumePlayback().status, .starting)
        audio.startStatus = .confirmed
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)
        return (engine, audio)
    }

    func testPlayingFortyMinutesWithoutPausingResumesThereAfterTheAppIsKilled() throws {
        var (engine, audio): (SessionEngine?, RelaunchAudioClient?) = try { let p = try playing(); return (p.engine, p.audio) }()
        // The foreground ticker keeps running while the phone is locked, and nothing ever pauses.
        for minute in 1...40 {
            now += 60
            audio?.mediaTimeMs = 60_000 + minute * 60_000
            XCTAssertEqual(try engine?.syncPlaybackProgress(coalescingWrites: true).status, .playing)
        }
        XCTAssertEqual(try storedMediaTimeMs(), 2_460_000, "the place on disk follows the playback, not the last pause")

        engine = nil; audio = nil // killed
        let (relaunched, relaunchedAudio, _) = try launch()
        _ = try relaunched.resumePlayback()
        XCTAssertEqual(relaunchedAudio.mediaPlays, [2_460_000], "Play starts where the listener had got to")
    }

    func testTheTickersHeldPlaceIsSavedWhenTheAppLeavesTheForeground() throws {
        let (engine, audio) = try playing()
        now += 60
        audio.mediaTimeMs = 600_000
        _ = try engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(try storedMediaTimeMs(), 600_000)

        now += 1
        audio.mediaTimeMs = 601_000 // within the write interval: held, not written
        _ = try engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(try storedMediaTimeMs(), 600_000, "a steady advance is coalesced")

        _ = try engine.syncPlaybackProgress() // the lifecycle sync as the app is suspended
        XCTAssertEqual(try storedMediaTimeMs(), 601_000)
    }

    func testAScrubWhilePausedIsOnDiskAtOnceAndResumesThere() throws {
        let (engine, _) = try playing()
        XCTAssertEqual(try engine.pause().status, .paused)

        XCTAssertEqual(try engine.seekMedia(toMediaTimeMs: 1_800_000).status, .paused)
        XCTAssertEqual(try storedMediaTimeMs(), 1_800_000, "the scrub is saved without any later sync or pause")

        let (relaunched, relaunchedAudio, _) = try launch()
        _ = try relaunched.resumePlayback()
        XCTAssertEqual(relaunchedAudio.mediaPlays, [1_800_000])
    }

    func testAScrubWhilePlayingIsOnDiskBeforeThePlayerReportsIt() throws {
        let (engine, _) = try playing()
        _ = try engine.seekMedia(toMediaTimeMs: 2_000_000)
        XCTAssertEqual(try storedMediaTimeMs(), 2_000_000)
    }

    /// #2509: every tick publishes the session's Margin and AI-job counts. They used to decode every Margin and job of
    /// the session on the main thread twice a second; the store now counts them without reading a payload.
    func testATickCountsTheSessionsMarginsAndJobsWithoutDecodingThem() throws {
        let store = try SQLiteSessionStore(path: path)
        for index in 0..<40 {
            try store.saveInterjection(Interjection(
                id: "margin-\(index)", itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
                createdAt: now, roughPercent: 1, anchor: Anchor(anchorType: .text, startChar: index, endChar: index, anchorBefore: "a", anchorAfter: "b"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete",
                transcript: String(repeating: "spoken words ", count: 200), cleanedTranscript: nil, displayText: nil,
                status: index % 4 == 0 ? "deleted" : "active"))
        }
        for (index, status) in ["complete", "queued", "running"].enumerated() {
            try store.saveAIJob(AIJob(
                id: "job-\(index)", kind: "summary", itemId: nil, sessionId: sessionId, turnId: "turn-\(index)",
                providerType: "local", model: "on-device", status: status, attempts: 1, lastError: nil,
                messages: [], playbackMode: nil))
        }
        let meter = StoreReadMeter()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["native_media"]]),
            repository: try SQLiteSessionStore(path: path, readMeter: meter), audio: RelaunchAudioClient(durationMs: durationMs),
            playbackStartTimeout: 5, now: { [unowned self] in self.now })
        _ = try engine.inspectSession(sessionId: sessionId)
        meter.reset()

        var snapshot = try engine.syncPlaybackProgress(coalescingWrites: true)
        for _ in 0..<20 { snapshot = try engine.syncPlaybackProgress(coalescingWrites: true) }

        XCTAssertEqual(snapshot.activeInterjectionCount, 30, "the ten deleted Margins don't count")
        XCTAssertEqual(snapshot.pendingAiJobCount, 2, "the finished job doesn't count")
        let totals = meter.totals()
        XCTAssertNil(totals["loadInterjections(sessionId:)"], "no tick decodes the session's Margins")
        XCTAssertNil(totals["loadAIJobs(sessionId:)"], "no tick decodes the session's AI jobs")
        XCTAssertGreaterThan(totals["activeInterjectionCount"]?.calls ?? 0, 0, "the store counted them instead")
    }
}

/// A media player that reports whatever place the test sets and confirms a start when told to.
private final class RelaunchAudioClient: AudioPlaybackClient {
    let durationMs: Int
    var startStatus: PlaybackStartStatus = .pending
    var activeTargetId: String?
    var mediaTimeMs: Int?
    var mediaPlays: [Int] = []

    init(durationMs: Int) { self.durationMs = durationMs }

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, from charOffset: Int) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }
    func play(targetId: String, seekingTo charOffset: Int) throws { try play(targetId: targetId, fromMediaTimeMs: 0) }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeTargetId = targetId
        self.mediaTimeMs = mediaTimeMs
        mediaPlays.append(mediaTimeMs)
    }

    func seek(toMediaTimeMs mediaTimeMs: Int) throws { self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}

    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map {
            PlaybackPosition(targetId: activeTargetId, mediaTimeMs: $0, durationMs: durationMs, playbackRate: 1, anchorConfidence: .mediaTime)
        }
    }

    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }
}
