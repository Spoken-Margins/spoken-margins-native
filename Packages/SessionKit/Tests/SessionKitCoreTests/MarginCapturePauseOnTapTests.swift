import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1696: Add a Margin on a long podcast left the source playing and Cancel dead for 16 s before the microphone
/// started. The tap now pauses a playing podcast first, Cancel before the recorder is asked for puts it back, and
/// the engine no longer decodes the whole transcript timeline on every progress tick.
final class MarginCapturePauseOnTapTests: XCTestCase {
    private let profile = RuntimeCapabilityProfile(
        id: "phone-tablet-online", displayName: "Phone/Tablet Online",
        capabilities: [
            "sync": ["canonical_persistence"],
            "playback": ["realtime_tts", "native_media"],
            "interjection": ["record_audio", "capture_media_anchor", "capture_text_anchor"]
        ]
    )

    private let episode = Item(
        id: "item-episode", title: "Episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
        externalReference: "https://example.com/episode", status: "ready", externalReferenceType: "url",
        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/episode.mp3", durationMs: 4_740_000)
    )

    private let article = Item(
        id: "item-article", title: "Article", mediaType: "text", text: "First sentence. Second sentence. Third sentence.",
        externalReference: nil, status: "ready"
    )

    /// A player whose clock only runs while it plays, as a real one's does.
    private final class Podcast: AudioPlaybackClient {
        var mediaTimeMs: Int? = 3_969_000
        var playing = false
        var charOffset: Int?
        var events: [String] = []
        func prepareSpeechText(_ text: String) throws -> String { text }
        func play(targetId: String) throws { playing = true; events.append("play") }
        func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset; playing = true; events.append("play") }
        func play(targetId: String, fromMediaTimeMs t: Int) throws { mediaTimeMs = t; playing = true; events.append("play@\(t)") }
        func pause() throws { playing = false; events.append("pause") }
        func currentCharOffset() -> Int? { charOffset }
        func currentMediaTimeMs() -> Int? { mediaTimeMs }
        func currentPlaybackPosition() -> PlaybackPosition? {
            if let mediaTimeMs { return PlaybackPosition(mediaTimeMs: mediaTimeMs, durationMs: 4_740_000, anchorConfidence: .mediaTime) }
            return charOffset.map { PlaybackPosition(textStart: $0, textEnd: $0 + 1, anchorConfidence: .textRange) }
        }
        /// What the listener hears advancing while the source plays.
        func advance(byMs ms: Int) { if playing, let t = mediaTimeMs { mediaTimeMs = t + ms } }
    }

    private final class Recorder: RecordingClient {
        var begins = 0
        var cancels = 0
        var failsToStart = false
        /// A slow microphone start (the Bluetooth switch), and what the source was doing while it ran.
        var startDelay: TimeInterval = 0
        var sourcePlaying: (() -> Bool)?
        var sourceWasPlayingDuringStart: Bool?
        func beginRecording() throws {
            if failsToStart { throw SessionKitError.invalidCommandForState("microphone") }
            sourceWasPlayingDuringStart = sourcePlaying?()
            if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
            begins += 1
        }
        func cancelRecording() throws { cancels += 1 }
        func finishRecording(audioRef: String?) throws -> String { "interjections/test.m4a" }
    }

    private struct Rig {
        let engine: SessionEngine
        let audio: Podcast
        let recorder: Recorder
        let repository: InMemorySessionRepository
        let journal: RecordingDraftJournal
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pause-on-tap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func rig(item: Item, playing: Bool = true, repository: InMemorySessionRepository? = nil) throws -> Rig {
        let audio = Podcast()
        let recorder = Recorder()
        let repository = repository ?? InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: audio, recorder: recorder)
        let journal = RecordingDraftJournal(directory: RecordingDraftJournal.standardDirectory(applicationSupport: directory))
        engine.recordingDraftJournal = journal
        _ = try engine.startSession(itemId: item.id) // starts playing
        if !playing { _ = try engine.pause() }
        audio.mediaTimeMs = item.id == episode.id ? 3_969_000 : nil // 66 min into the episode
        audio.events.removeAll()
        return Rig(engine: engine, audio: audio, recorder: recorder, repository: repository, journal: journal)
    }

    // MARK: Done when 2: the tap pauses a playing podcast before any slow work

    func testTheTapPausesAPlayingPodcastAndAsksForNoRecorder() throws {
        let rig = try rig(item: episode)
        XCTAssertTrue(rig.engine.snapshot.status.isPlaybackActive, "the rig starts with the podcast playing")

        let snapshot = rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())

        XCTAssertEqual(rig.audio.events, ["pause"], "the pause is the only thing that happened")
        XCTAssertFalse(rig.audio.playing)
        XCTAssertEqual(snapshot.status, .paused, "the screen and the Lock Screen stop saying Playing")
        XCTAssertEqual(rig.recorder.begins, 0)
        XCTAssertTrue(rig.engine.isSourcePausedOnTap)
        XCTAssertEqual(try rig.journal.load().drafts.count, 0, "no recording draft before the recorder is asked for")
    }

    func testTheMarginIsAnchoredWhereThePodcastStoppedNotWhereItWouldHaveReached() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        rig.audio.advance(byMs: 16_000) // a slow start: the clock must not run on, the source is paused

        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        XCTAssertEqual(rig.recorder.begins, 1)
        XCTAssertFalse(rig.engine.isSourcePausedOnTap, "the start took the pause over")
        let draft = try XCTUnwrap(try rig.journal.load().drafts.first)
        XCTAssertEqual(draft.anchor.mediaTimeMs, 3_969_000)
    }

    func testCancellingARecordingStartedAfterTheTapPauseStillPutsThePodcastBack() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())
        rig.audio.events.removeAll()

        _ = try rig.engine.cancelInterjection()

        XCTAssertTrue(rig.audio.playing, "the podcast was playing before the tap, so Cancel plays it on")
        XCTAssertEqual(rig.audio.events, ["play@3969000"])
        XCTAssertEqual(try rig.journal.load().drafts.count, 0)
    }

    // MARK: Done when 3: Cancel while the start is slow

    func testASlowMicrophoneStartNeverRunsOverAPlayingPodcast() throws {
        let rig = try rig(item: episode)
        rig.recorder.startDelay = 0.3
        rig.recorder.sourcePlaying = { rig.audio.playing }
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())

        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())

        XCTAssertEqual(rig.recorder.sourceWasPlayingDuringStart, false, "the listener never talks over the podcast")
        XCTAssertEqual(rig.recorder.begins, 1)
    }

    func testAPlayFromTheLockScreenWhileWaitingIsNotSoughtAgainByCancel() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.resumePlayback() // the listener pressed Play on the Lock Screen
        rig.audio.events.removeAll()

        _ = try rig.engine.abandonPendingInterjection()

        XCTAssertEqual(rig.audio.events, [], "it already plays; Cancel doesn't restart it")
        XCTAssertFalse(rig.engine.isSourcePausedOnTap)
    }

    func testACancelThatFindsThePauseStillPendingClearsIt() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.cancelInterjection()
        XCTAssertFalse(rig.engine.isSourcePausedOnTap, "a stale pause would be taken for the next Margin's")
        XCTAssertTrue(rig.audio.playing)
    }

    func testCancelBeforeTheSlowStartRunsStopsItAndResumesThePodcastWithNoDraft() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        rig.audio.advance(byMs: 16_000)

        let snapshot = try rig.engine.abandonPendingInterjection()

        XCTAssertEqual(rig.audio.events, ["pause", "play@3969000"], "back from where it stopped, not 16 s on")
        XCTAssertTrue(rig.audio.playing)
        XCTAssertTrue(snapshot.status.isPlaybackActive)
        XCTAssertFalse(rig.engine.isSourcePausedOnTap)
        XCTAssertEqual(rig.recorder.begins, 0, "the recorder was never asked for")
        XCTAssertEqual(try rig.journal.load().drafts.count, 0, "Cancel leaves no draft to recover")
        XCTAssertFalse(snapshot.isRecording)
        XCTAssertEqual(try XCTUnwrap(rig.repository.loadSession(id: try XCTUnwrap(rig.engine.currentSession?.id))).position.mediaTimeMs, 3_969_000)
    }

    func testAStartThatFailsAfterTheTapPausePutsThePodcastBackToo() throws {
        let rig = try rig(item: episode)
        rig.recorder.failsToStart = true
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())

        XCTAssertThrowsError(try rig.engine.beginInterjection(request: MarginCaptureRequest()))

        XCTAssertTrue(rig.audio.playing, "the microphone wouldn't start, so the podcast plays on")
        XCTAssertFalse(rig.engine.isSourcePausedOnTap)
        XCTAssertEqual(try rig.journal.load().drafts.count, 0)
    }

    func testCancelWhenTheTapPausedNothingChangesNothing() throws {
        let rig = try rig(item: episode, playing: false)
        XCTAssertFalse(rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest()).status.isPlaybackActive)
        XCTAssertFalse(rig.engine.isSourcePausedOnTap, "a paused podcast has nothing to put back")

        _ = try rig.engine.abandonPendingInterjection()

        XCTAssertEqual(rig.audio.events, [])
    }

    func testSwitchingToAWrittenMarginKeepsTheSourceOwed() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())

        let capture = try rig.engine.beginWrittenInterjection()

        XCTAssertTrue(capture.wasPlaying, "the podcast was playing before the tap, so saving the written Margin resumes it")
        XCTAssertFalse(rig.engine.isSourcePausedOnTap)
        rig.audio.events.removeAll()
        _ = try rig.engine.saveWrittenInterjection(captureId: capture.id, text: "A thought")
        XCTAssertTrue(rig.audio.playing)
    }

    func testTextReadAloudIsLeftToTheEngineStartAsBefore() throws {
        let rig = try rig(item: article)
        rig.audio.charOffset = 16

        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())

        XCTAssertFalse(rig.engine.isSourcePausedOnTap, "its position is read before it is paused, so only the engine start does both")
        XCTAssertEqual(rig.audio.events, [])
    }

    // MARK: Done when 1: each step of the path is stamped

    func testTheDiagnosticsNameTheStepThatTookTheTime() throws {
        let rig = try rig(item: episode)
        rig.engine.pauseSourceForInterjection(request: .tapped(at: Date()))
        Thread.sleep(forTimeInterval: 0.25) // the deferred start waits behind the main actor's queue
        _ = try rig.engine.beginInterjection(request: .tapped(at: Date()))

        let fields = rig.engine.recordingCaptureDiagnostics()
        func ms(_ key: String) throws -> Int { try XCTUnwrap(Int(try XCTUnwrap(fields[key]))) }

        XCTAssertLessThan(try ms("tapToSourcePausedMs"), try ms("tapToEngineEnteredMs"), "the pause came with the tap, before the wait")
        XCTAssertGreaterThanOrEqual(try ms("tapToEngineEnteredMs"), 250, "the wait before the engine call shows as its own step")
        XCTAssertGreaterThanOrEqual(try ms("tapToAnchorReadyMs"), try ms("tapToEngineEnteredMs"))
        XCTAssertGreaterThanOrEqual(try ms("tapToRecorderRequestedMs"), try ms("tapToAnchorReadyMs"))
        XCTAssertGreaterThanOrEqual(try ms("tapToRecorderStartedMs"), try ms("tapToRecorderRequestedMs"))
    }

    func testWithoutATapPauseTheEngineStampsItsOwnPause() throws {
        let rig = try rig(item: episode)
        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())
        let fields = rig.engine.recordingCaptureDiagnostics()
        XCTAssertNotEqual(fields["tapToSourcePausedMs"], "not_observed")
        XCTAssertNotEqual(fields["tapToEngineEnteredMs"], "not_observed")
        XCTAssertNotEqual(fields["tapToAnchorReadyMs"], "not_observed")
    }

    // MARK: The timeline is decoded once, not on every tick

    private final class StampedRepository: InMemorySessionRepository, @unchecked Sendable {
        var stamp: String? = "v1"
        var timelineLoads = 0
        override func transcriptTimelineStamp(itemId: String) throws -> String? { stamp }
        override func loadTranscriptTimeline(itemId: String) throws -> SourceTranscriptTimeline? {
            timelineLoads += 1
            return try super.loadTranscriptTimeline(itemId: itemId)
        }
    }

    private func timeline(segments: Int, id: String = "timeline") -> SourceTranscriptTimeline {
        SourceTranscriptTimeline(
            id: id, itemId: "item-episode", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeline: TranscriptTimeline(
                segments: (0..<segments).map { MediaTimelineSegment(id: "seg-\($0)", startMs: $0 * 1_000, endMs: $0 * 1_000 + 900, text: "Words \($0).") },
                chapters: [], durationMs: 4_740_000))
    }

    private func stampedRig(segments: Int = 50) throws -> (Rig, StampedRepository) {
        let repository = StampedRepository(items: [episode.id: episode])
        try repository.saveTranscriptTimeline(timeline(segments: segments))
        return (try rig(item: episode, repository: repository), repository)
    }

    func testProgressTicksAndAddAMarginReadTheStoredTimelineOnce() throws {
        let (rig, repository) = try stampedRig()
        _ = try rig.engine.syncPlaybackProgress()
        repository.timelineLoads = 0

        for _ in 0..<10 { _ = try rig.engine.syncPlaybackProgress() }
        rig.engine.pauseSourceForInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.cancelInterjection()

        XCTAssertEqual(repository.timelineLoads, 0, "ten ticks and a whole Add a Margin read the timeline already held")
        XCTAssertEqual(rig.engine.snapshot.sourceTranscriptStatus, "ready")
    }

    /// #2508: playing a Margin checked its place against the transcript's length by decoding the whole transcript.
    func testPlayingAMarginReadsTheStoredTimelineAlreadyHeld() throws {
        let (rig, repository) = try stampedRig()
        _ = try rig.engine.beginInterjection(request: MarginCaptureRequest())
        _ = try rig.engine.finishInterjection(audioRef: "margin.m4a")
        let sessionId = try XCTUnwrap(rig.engine.currentSession?.id)
        let margin = try XCTUnwrap(try repository.loadInterjections(sessionId: sessionId).first)
        _ = try rig.engine.syncPlaybackProgress()
        repository.timelineLoads = 0

        for _ in 0..<3 { _ = try rig.engine.playInterjectionAnchor(margin) }

        XCTAssertEqual(repository.timelineLoads, 0, "three Margin plays read the timeline already held")
        XCTAssertEqual(rig.engine.currentSession?.position.mediaTimeMs, margin.anchor.mediaTimeMs)
    }

    func testAChangedStoredTimelineIsReadAgainAtTheNextCall() throws {
        let (rig, repository) = try stampedRig()
        _ = try rig.engine.syncPlaybackProgress()
        XCTAssertEqual(rig.engine.snapshot.sourceTranscriptStatus, "ready")

        repository.transcriptTimelines["timeline"] = timeline(segments: 0) // the transcript was replaced with an empty one
        repository.stamp = "v2"
        _ = try rig.engine.syncPlaybackProgress()

        XCTAssertEqual(rig.engine.snapshot.sourceTranscriptStatus, "not_started", "the old copy was not kept past the save")
    }

    func testAStoreThatCannotStampIsReadEveryTimeAsBefore() throws {
        let (rig, repository) = try stampedRig()
        repository.stamp = nil
        _ = try rig.engine.syncPlaybackProgress()
        repository.timelineLoads = 0

        _ = try rig.engine.syncPlaybackProgress()
        XCTAssertGreaterThan(repository.timelineLoads, 1)
    }

    func testTheSQLiteStampMovesOnlyWithTheStoredRecord() throws {
        let path = directory.appending(path: "library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        XCTAssertNil(try store.transcriptTimelineStamp(itemId: "item-episode"), "no timeline, no stamp")

        try store.saveTranscriptTimeline(timeline(segments: 20))
        let first = try XCTUnwrap(try store.transcriptTimelineStamp(itemId: "item-episode"))
        XCTAssertEqual(try store.transcriptTimelineStamp(itemId: "item-episode"), first, "reading changes nothing")

        try store.saveTranscriptTimeline(timeline(segments: 21))
        XCTAssertNotEqual(try store.transcriptTimelineStamp(itemId: "item-episode"), first, "a longer timeline under the same id is another record")

        let second = try XCTUnwrap(try store.transcriptTimelineStamp(itemId: "item-episode"))
        try store.saveTranscriptTimeline(timeline(segments: 5, id: "other"))
        XCTAssertNotNil(try store.transcriptTimelineStamp(itemId: "item-episode"))
        XCTAssertNil(try store.transcriptTimelineStamp(itemId: "another-item"))
        _ = second
    }
}
