import AVFoundation
import SessionKitAudio
import XCTest

/// #768: on a simulator whose speech and audio services have wedged, `AVSpeechSynthesizer.write`
/// delivers no buffer at all, and the next `AVAudioEngine.start()` in the process aborts the app
/// inside Apple's audio stack (`AURemoteIO::fetchWorkgroup` RPC timeout, no app frame). The
/// system-voice tests check what the app does with that voice; on such a runtime they can't, so
/// they skip with the reason instead of taking the whole test process down. A healthy runtime
/// never stalls a write, so these checks change nothing there.
enum SystemVoiceRuntime {
    enum Answer: Equatable {
        case answered
        case stalled(String)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: String?
        private var kept: [AVSpeechSynthesizer] = []
        var stall: String? { lock.withLock { reason } }
        func recordStall(_ why: String) { lock.withLock { if reason == nil { reason = why } } }
        func keep(_ synthesizer: AVSpeechSynthesizer) { lock.withLock { kept.append(synthesizer) } }
    }

    private static let state = State()

    /// `AVSpeechSynthesizer.write` can block its caller for minutes while the speech service loads
    /// (#1230), so tests start their writes here and their waits keep running.
    static let writeQueue = DispatchQueue(label: "SpokenMarginsAppTests.SystemVoiceRuntime.write", qos: .userInitiated)

    /// What stalled earlier in this test process, if anything did.
    static var stalledEarlier: String? { state.stall }

    static func recordStall(_ why: String) { state.recordStall(why) }

    /// Keeps a synthesizer for the rest of the process. It goes on sending to the main queue after the
    /// end of its stream, and releasing one while TextToSpeech still calls into it is the #1230 crash.
    static func keep(_ synthesizer: AVSpeechSynthesizer) { state.keep(synthesizer) }

    static func skipIfStalledEarlier() throws {
        if let why = stalledEarlier {
            throw XCTSkip("The system voice stopped answering earlier in this test process (\(why)); #768: the simulator's speech and audio services are wedged, so an audio engine start here would abort the app")
        }
    }

    /// Renders one word through `render` (the shipped `SystemVoiceChunkRenderer` in the real check)
    /// into a temporary file. A timeout or a render with no audio is a stall; any other error is the
    /// test's own and is thrown. Records nothing, so tests can drive it with scripted renders.
    static func probe(
        timeout: TimeInterval,
        render: (_ reference: URL, _ output: URL, _ timeout: TimeInterval) async throws -> TimeInterval
    ) async throws -> Answer {
        let folder = FileManager.default.temporaryDirectory.appending(path: "system-voice-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let reference = folder.appending(path: "reference.wav")
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        silence.frameLength = 4_410
        try AVAudioFile(forWriting: reference, settings: format.settings).write(from: silence)
        do {
            _ = try await render(reference, folder.appending(path: "probe.wav"), timeout)
            return .answered
        } catch SystemVoiceChunkRenderer.Failure.timedOut {
            return .stalled("a one-word render did not finish in \(Int(timeout)) s")
        } catch SystemVoiceChunkRenderer.Failure.noAudio {
            return .stalled("a one-word render produced no audio")
        }
    }

    /// Skips the calling test unless the system voice answers: a write earlier in this process
    /// stalled, or a fresh one-word render through the shipped renderer doesn't finish with audio
    /// within `timeout`. Run it before starting an audio engine.
    static func requireAnsweringVoice(timeout: TimeInterval = 30) async throws {
        try skipIfStalledEarlier()
        let renderer = SystemVoiceChunkRenderer()
        let answer = try await probe(timeout: timeout) { reference, output, timeout in
            try await renderer.render(text: "Ready.", voiceIdentifier: nil, matching: reference, to: output, timeout: timeout)
        }
        if case .stalled(let why) = answer {
            recordStall(why)
            try skipIfStalledEarlier()
        }
    }
}
