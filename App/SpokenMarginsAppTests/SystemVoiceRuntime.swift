import AVFoundation
import XCTest

/// #768: on a simulator whose speech and audio services have wedged, `AVSpeechSynthesizer.write`
/// delivers no buffer at all, and the next `AVAudioEngine.start()` in the process aborts the app
/// inside Apple's audio stack (`AURemoteIO::fetchWorkgroup` RPC timeout, no app frame). The
/// system-voice tests check what the app does with that voice; on such a runtime they can't, so
/// they skip with the reason instead of taking the whole test process down.
///
/// Only "nothing at all arrived" is a stall. A voice that sends audio but never ends its speech, or
/// ends it with no audio, fails the test: that is a fault to see, not a wedge to skip. The check is
/// a raw write, not the shipped `SystemVoiceChunkRenderer`, so a renderer regression still fails the
/// tests that use the renderer. A healthy runtime never stalls a write, so these checks change
/// nothing there.
enum SystemVoiceRuntime {
    enum Answer: Equatable {
        case answered
        /// Nothing arrived: the #768 wedge. The test skips.
        case stalled(String)
        /// The voice answered but didn't finish properly. The test fails.
        case broken(String)
    }

    struct VoiceFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// #1230: the first iOS-voice write in a fresh simulator waited 30 s to over 3 minutes while the
    /// speech service loaded. That is a slow start, not a wedge, so the first write a test makes gets
    /// this long; tests that use it ask for the plan's 180 s maximum allowance.
    static let coldStartAllowance: TimeInterval = 100

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: String?
        private var stalledWrite: Listening?
        private var kept: [AVSpeechSynthesizer] = []
        /// A stalled write that delivered audio later was a slow start, not a wedge, so it no longer counts.
        var stall: String? {
            lock.withLock {
                if let write = stalledWrite, write.heard.buffers > 0 {
                    reason = nil
                    stalledWrite = nil
                }
                return reason
            }
        }
        func recordStall(_ why: String, write: Listening?) {
            lock.withLock {
                if reason == nil {
                    reason = why
                    stalledWrite = write
                }
            }
        }
        func keep(_ synthesizer: AVSpeechSynthesizer) { lock.withLock { kept.append(synthesizer) } }
    }

    private static let state = State()

    /// `AVSpeechSynthesizer.write` can block its caller for minutes while the speech service loads
    /// (#1230), so writes start here and the waits keep their timeouts.
    private static let writeQueue = DispatchQueue(label: "SpokenMarginsAppTests.SystemVoiceRuntime.write", qos: .userInitiated)

    /// What stalled earlier in this test process, if anything did.
    static var stalledEarlier: String? { state.stall }

    static func skipIfStalledEarlier() throws {
        if let why = stalledEarlier {
            throw XCTSkip("The system voice stopped answering earlier in this test process (\(why)); #768: the simulator's speech and audio services are wedged, so an audio engine start here would abort the app")
        }
    }

    /// What one write delivered. Its expectation is not a test case's own: a write that answers after
    /// the wait gave up must not fulfil one.
    final class Listening: @unchecked Sendable {
        struct Heard: Equatable {
            var buffers = 0
            var frames: Double = 0
            var sampleRate: Double = 0
            var ended = false
        }

        let finished = XCTestExpectation(description: "the write reached its end of speech")
        private let lock = NSLock()
        private var state = Heard()
        var heard: Heard { lock.withLock { state } }

        /// Counts every buffer, and the frames up to the first empty one, which marks the end of speech.
        func receive(_ buffer: AVAudioBuffer) {
            let endsNow: Bool = lock.withLock {
                state.buffers += 1
                guard let pcm = buffer as? AVAudioPCMBuffer, !state.ended else { return false }
                if pcm.frameLength == 0 {
                    state.ended = true
                    return true
                }
                state.frames += Double(pcm.frameLength)
                state.sampleRate = pcm.format.sampleRate
                return false
            }
            if endsNow { finished.fulfill() }
        }
    }

    private final class Write: @unchecked Sendable {
        let synthesizer: AVSpeechSynthesizer
        let utterance: AVSpeechUtterance
        init(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance) {
            self.synthesizer = synthesizer
            self.utterance = utterance
        }
    }

    /// Starts writing `utterance` off the caller's thread. The synthesizer is kept for the rest of the
    /// process: it goes on sending to the main queue after its end of stream, and releasing one while
    /// TextToSpeech still calls into it is the #1230 crash.
    static func startWrite(_ utterance: AVSpeechUtterance, offTheAppsSession: Bool) -> Listening {
        let synthesizer = AVSpeechSynthesizer()
        if offTheAppsSession { synthesizer.usesApplicationAudioSession = false }
        state.keep(synthesizer)
        let listening = Listening()
        let write = Write(synthesizer: synthesizer, utterance: utterance)
        writeQueue.async { write.synthesizer.write(write.utterance) { listening.receive($0) } }
        return listening
    }

    static func classify(_ heard: Listening.Heard, finished: Bool, waited: TimeInterval, what: String) -> Answer {
        if finished {
            return heard.frames > 0 ? .answered : .broken("\(what) reached its end of speech with no audio")
        }
        if heard.buffers == 0 { return .stalled("\(what) delivered nothing in \(Int(waited)) s") }
        return .broken("\(what) delivered \(heard.buffers) buffers but no end of speech in \(Int(waited)) s")
    }

    /// Returns on an answer. A stall is recorded, so later system-voice tests in the process skip at
    /// once unless `write` answers in the meantime, and the caller skips; a broken answer throws a failure.
    static func requireAnswered(_ answer: Answer, from write: Listening? = nil) throws {
        switch answer {
        case .answered:
            return
        case .stalled(let why):
            state.recordStall(why, write: write)
            try skipIfStalledEarlier()
        case .broken(let why):
            throw VoiceFailure(description: "The system voice answered but did not finish: \(why)")
        }
    }

    /// Skips the calling test unless the system voice answers a one-word write within `timeout`. Run
    /// it before starting an audio engine. The write stays off the app's audio session (#288).
    ///
    /// When a test runs on its own, this write is the one that loads the speech service, so that load
    /// happens before the test's engine starts rather than while it plays.
    static func requireAnsweringVoice(timeout: TimeInterval = coldStartAllowance) async throws {
        try skipIfStalledEarlier()
        let listening = startWrite(AVSpeechUtterance(string: "Ready."), offTheAppsSession: true)
        let finished = await XCTWaiter().fulfillment(of: [listening.finished], timeout: timeout) == .completed
        try requireAnswered(classify(listening.heard, finished: finished, waited: timeout, what: "a one-word write"), from: listening)
    }
}
