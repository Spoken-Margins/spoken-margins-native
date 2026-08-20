import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest

@MainActor
final class MediaPlaybackInterruptionTests: XCTestCase {
    func testPreparedTextMediaPublishesCanonicalPauseAndConditionalResumeIntent() async throws {
        let audioURL = try makeTestWAV(duration: 2)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let notificationCenter = NotificationCenter()
        let events = InterruptionEventRecorder()
        let began = expectation(description: "interruption began")
        let ended = expectation(description: "interruption ended with resume permission")
        let client = AVPlayerStreamPlaybackClient(
            audioSessionNotificationCenter: notificationCenter,
            interruptionHandler: { event in
                events.append(event)
                switch event {
                case .began:
                    began.fulfill()
                case .endedShouldResume:
                    ended.fulfill()
                }
            }
        )
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "native-text",
            targetType: .transcriptBackedMedia,
            targetId: "prepared-native-text-audio",
            title: "Prepared native text",
            playbackURL: audioURL.absoluteString,
            durationMs: 2_000
        ))
        try client.play(targetId: "prepared-native-text-audio", fromMediaTimeMs: 0)

        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        await fulfillment(of: [began], timeout: 1)
        XCTAssertEqual(client.playbackTransportState(targetId: "prepared-native-text-audio"), .paused)

        notificationCenter.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertEqual(events.values, [.began, .endedShouldResume])
        try client.stop()
    }

    private func makeTestWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "media-interruption-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private final class InterruptionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AudioPlaybackInterruptionEvent] = []

    var values: [AudioPlaybackInterruptionEvent] {
        lock.withLock { storage }
    }

    func append(_ event: AudioPlaybackInterruptionEvent) {
        lock.withLock {
            storage.append(event)
        }
    }
}
