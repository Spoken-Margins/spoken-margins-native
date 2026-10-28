import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2129, the article half: a text article read aloud by on-device speech keeps its place the way a podcast does
/// (`ResumeAfterRelaunchTests`). Each test plays on a real SQLite file, drops the engine without a pause (the app
/// killed while locked), and resumes from a new engine and a new store on the same file.
final class ResumeArticleAfterRelaunchTests: XCTestCase {
    private var directory: URL!
    private var now = Date(timeIntervalSince1970: 1_000)
    private let itemId = "item-article"
    private let sessionId = "session-article"
    private let text = (1...4_000).map { "This is sentence number \($0)." }.joined(separator: " ")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "resume-article-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(
            id: itemId, title: "A long article", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        try store.saveSession(Session(
            id: sessionId, itemId: itemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: itemId,
            position: Position(charOffset: 0), completionPercent: 0, playbackRate: 1))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var path: String { directory.appending(path: "library.sqlite").path }

    /// A new store and engine on the file, as a launch builds them, with the session inspected (restored).
    private func launch() throws -> (engine: SessionEngine, audio: ArticleRelaunchAudioClient) {
        let store = try SQLiteSessionStore(path: path)
        let audio = ArticleRelaunchAudioClient()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]),
            repository: store, audio: audio, playbackStartTimeout: 5, now: { [unowned self] in self.now })
        _ = try engine.inspectSession(sessionId: sessionId)
        return (engine, audio)
    }

    private func storedCharOffset() throws -> Int? {
        try SQLiteSessionStore(path: path).loadSession(id: sessionId)?.position.charOffset
    }

    private func playing() throws -> (engine: SessionEngine, audio: ArticleRelaunchAudioClient) {
        let (engine, audio) = try launch()
        XCTAssertEqual(try engine.resumePlayback().status, .starting)
        audio.startStatus = .confirmed
        XCTAssertEqual(try engine.syncPlaybackProgress().status, .playing)
        return (engine, audio)
    }

    func testReadingForAWhileWithoutPausingResumesThereAfterTheAppIsKilled() throws {
        var (engine, audio): (SessionEngine?, ArticleRelaunchAudioClient?) = try { let p = try playing(); return (p.engine, p.audio) }()
        for minute in 1...30 {
            now += 60
            audio?.charOffset = minute * 1_000
            XCTAssertEqual(try engine?.syncPlaybackProgress(coalescingWrites: true).status, .playing)
        }
        XCTAssertEqual(try storedCharOffset(), 30_000, "the place on disk follows the reading, not the last pause")

        engine = nil; audio = nil // killed
        let (relaunched, relaunchedAudio) = try launch()
        _ = try relaunched.resumePlayback()
        XCTAssertEqual(relaunchedAudio.plays, [30_000], "Play starts where the listener had got to")
    }

    func testTheTickersHeldPlaceIsSavedWhenTheAppLeavesTheForeground() throws {
        let (engine, audio) = try playing()
        now += 60
        audio.charOffset = 6_000
        _ = try engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(try storedCharOffset(), 6_000)

        now += 1
        audio.charOffset = 6_050 // within the write interval: held, not written
        _ = try engine.syncPlaybackProgress(coalescingWrites: true)
        XCTAssertEqual(try storedCharOffset(), 6_000, "a steady advance is coalesced")

        _ = try engine.syncPlaybackProgress() // the lifecycle sync as the app is suspended
        XCTAssertEqual(try storedCharOffset(), 6_050)
    }

    func testAScrubWhilePausedIsOnDiskAtOnceAndResumesThere() throws {
        let (engine, _) = try playing()
        XCTAssertEqual(try engine.pause().status, .paused)

        _ = try engine.seekText(toCharOffset: 40_000)
        XCTAssertEqual(try storedCharOffset(), 40_000, "the scrub is saved without any later sync or pause")

        let (relaunched, relaunchedAudio) = try launch()
        _ = try relaunched.resumePlayback()
        XCTAssertEqual(relaunchedAudio.plays, [40_000])
    }

    func testAScrubWhilePlayingIsOnDiskBeforeTheVoiceReportsIt() throws {
        let (engine, _) = try playing()
        _ = try engine.seekText(toCharOffset: 50_000)
        XCTAssertEqual(try storedCharOffset(), 50_000)
    }
}

/// A speech voice that reports whatever place the test sets and confirms a start when told to.
private final class ArticleRelaunchAudioClient: AudioPlaybackClient {
    var startStatus: PlaybackStartStatus = .pending
    var activeTargetId: String?
    var charOffset: Int?
    var plays: [Int] = []

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { try play(targetId: targetId, from: 0) }
    func play(targetId: String, from charOffset: Int) throws { start(targetId, charOffset) }
    func play(targetId: String, seekingTo charOffset: Int) throws { start(targetId, charOffset) }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {}
    func seek(toMediaTimeMs mediaTimeMs: Int) throws {}
    func pause() throws {}

    private func start(_ targetId: String, _ charOffset: Int) {
        activeTargetId = targetId
        self.charOffset = charOffset
        plays.append(charOffset)
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        charOffset.map { PlaybackPosition(targetId: activeTargetId, textStart: $0, playbackRate: 1, anchorConfidence: .textRange) }
    }

    func currentCharOffset() -> Int? { charOffset }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }
}
