import AVFoundation
import Foundation
import SessionKitPersistence
import XCTest
@testable import SessionKit
@testable import SessionKitAudio
@testable import SpokenMarginsApp

/// #547, run in the app on the iOS audio session (the macOS twin is `PublisherAudioUnreachableTests`): the
/// publisher's recording is at an address nothing answers. Through the real `AVPlayer` client and
/// the engine's own start watchdog, the article must carry on with on-device speech from the same place and
/// never sit in "starting".
@MainActor
final class PublisherAudioUnreachableAppTests: XCTestCase {
    func testAnUnreachableRecordingFallsBackToOnDeviceSpeechWithinTheStartWatchdog() throws {
        let text = "The harbour shelters fishing boats. Gulls circle the old pier at dawn."
        let item = Item(id: "item-post", title: "A harbour", mediaType: "text", text: text,
                        externalReference: "https://example.com/harbour", status: "ready")
        let repository = InMemorySessionRepository(items: [item.id: item])
        // Port 9 (discard) refuses the connection straight away, as a dead host or a 404 page would fail.
        let url = "http://127.0.0.1:9/voiceover.mp3"
        repository.publisherAudio[item.id] = PublisherAudio(
            itemId: item.id, audioURL: url, durationMs: 9_000, detectedFrom: "feed_enclosure",
            textMap: TranscriptTimeline(segments: [
                MediaTimelineSegment(id: "publisher-audio-0001", startMs: 500, endMs: 4_000, startChar: 0, endChar: 35, text: "The harbour shelters fishing boats."),
                MediaTimelineSegment(id: "publisher-audio-0002", startMs: 4_500, endMs: 8_500, startChar: 36, endChar: text.count, text: "Gulls circle the old pier at dawn.")
            ], chapters: [], durationMs: 9_000),
            textMapStatus: "aligned(2 of 2 sentences)")
        let secondSentence = 36
        try repository.saveSession(Session(
            id: "session-saved", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: secondSentence + 8), completionPercent: 60, playbackRate: 1))

        let speech = UnreachableSpeechSpy()
        let media = AVPlayerStreamPlaybackClient()
        try media.setPlaybackVolume(0)
        defer { try? media.stop() }
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone", displayName: "Phone", capabilities: [
                "sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"]
            ]),
            repository: repository,
            audio: RoutedAudioPlaybackClient(speech: speech, media: media),
            playbackStartTimeout: 10
        )

        _ = try engine.inspectSession(sessionId: "session-saved")
        var snapshot = try engine.resumePlayback()
        let deadline = Date().addingTimeInterval(12)
        while snapshot.targetType != TargetType.itemTextTTS.rawValue, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            snapshot = try engine.syncPlaybackProgress()
        }

        XCTAssertEqual(snapshot.targetType, TargetType.itemTextTTS.rawValue, "gave way to on-device speech within the 10 s start watchdog")
        XCTAssertEqual(snapshot.status, .playing, "never left in starting")
        XCTAssertEqual(speech.played, [item.id])
        XCTAssertTrue(snapshot.lastFailure?.hasPrefix("publisher_audio_unavailable:") == true, snapshot.lastFailure ?? "nil")
        let offset = try XCTUnwrap(engine.currentSession?.position.charOffset)
        XCTAssertLessThanOrEqual(abs(offset - (secondSentence + 8)), 2, "from the place it was left")
        XCTAssertNil(try repository.loadItem(id: item.id).media)
    }

    /// #2508 audit: a play start asks whether the item plays its recording before the engine has a session for it,
    /// so the stored plan has to answer. An article that plays its publisher's recording renders nothing on the
    /// phone and is given no background time for on-device speech; one without a record still is.
    func testAPlayStartGivesNoStartupProtectionToAnArticleThatPlaysItsRecording() throws {
        let text = "The harbour shelters fishing boats. Gulls circle the old pier at dawn."
        func startupProtection(withRecording: Bool) throws -> String? {
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
            model.resetAndSeed()
            model.ttsVoiceSelection = .lily
            model.acceptCurrentTermsAndEnableOnDeviceVoice()
            let store = try XCTUnwrap(model.store)
            try store.saveItem(Item(id: "item-post", title: "A harbour", mediaType: "text", text: text,
                                    externalReference: "https://example.com/harbour", status: "ready"))
            if withRecording {
                try store.savePublisherAudio(PublisherAudio(
                    itemId: "item-post", audioURL: "https://publisher.example/post/voiceover.mp3", durationMs: 9_000,
                    detectedFrom: "feed_enclosure",
                    textMap: TranscriptTimeline(segments: [
                        MediaTimelineSegment(id: "publisher-audio-0001", startMs: 500, endMs: 4_000, startChar: 0, endChar: 35, text: "The harbour shelters fishing boats."),
                        MediaTimelineSegment(id: "publisher-audio-0002", startMs: 4_500, endMs: 8_500, startChar: 36, endChar: text.count, text: "Gulls circle the old pier at dawn.")
                    ], chapters: [], durationMs: 9_000),
                    textMapStatus: "aligned(2 of 2 sentences)"))
            }
            model.diagnostics["textAudioBackgroundStartup"] = nil
            model.activeItemId = "item-post"
            model.start()
            return model.diagnostics["textAudioBackgroundStartup"]
        }
        XCTAssertNotNil(try startupProtection(withRecording: false), "on-device speech renders on the phone, so its start is protected")
        XCTAssertNil(try startupProtection(withRecording: true), "the publisher's recording plays; nothing renders on the phone")
    }
}

private final class UnreachableSpeechSpy: AudioPlaybackClient {
    var played: [String] = []
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws { played.append(targetId) }
    func pause() throws {}
    func stop() throws {}
    func currentCharOffset() -> Int? { nil }
    func currentRecoveryCharOffset() -> Int? { nil }
    func currentMediaTimeMs() -> Int? { nil }
    func currentPlaybackDurationMs() -> Int? { nil }
    func currentPlaybackPosition() -> PlaybackPosition? { nil }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .confirmed }
    func isAwaitingRenderedAudio(targetId: String) -> Bool { false }
    func playbackTransportState(targetId: String) -> PlaybackTransportState? { nil }
    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {}
}
