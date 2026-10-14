import AVFoundation
import XCTest

/// #768: how the system-voice tests read a write before they start an audio engine. Only a write
/// that delivered nothing is a stall to skip; one that answered but never ended, or ended with no
/// audio, must fail. These drive `Listening` with made-up buffers and never record a stall, which
/// would skip the real system-voice tests later in the process.
final class SystemVoiceRuntimeTests: XCTestCase {
    private func buffer(frames: AVAudioFrameCount, sampleRate: Double = 22_050) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        return buffer
    }

    func testAWriteThatDeliveredNothingIsAStall() {
        let answer = SystemVoiceRuntime.classify(.init(), finished: false, waited: 100, what: "a one-word write")
        XCTAssertEqual(answer, .stalled("a one-word write delivered nothing in 100 s"))
    }

    func testAudioWithNoEndOfSpeechIsBrokenNotAStall() {
        let heard = SystemVoiceRuntime.Listening.Heard(buffers: 3, frames: 900, sampleRate: 22_050, ended: false)
        let answer = SystemVoiceRuntime.classify(heard, finished: false, waited: 60, what: "rendering at rate 0.5")
        XCTAssertEqual(answer, .broken("rendering at rate 0.5 delivered 3 buffers but no end of speech in 60 s"))
    }

    func testAnEndOfSpeechWithNoAudioIsBroken() {
        let heard = SystemVoiceRuntime.Listening.Heard(buffers: 1, frames: 0, sampleRate: 0, ended: true)
        let answer = SystemVoiceRuntime.classify(heard, finished: true, waited: 100, what: "a one-word write")
        XCTAssertEqual(answer, .broken("a one-word write reached its end of speech with no audio"))
    }

    func testAudioThenAnEndOfSpeechIsAnAnswer() {
        let heard = SystemVoiceRuntime.Listening.Heard(buffers: 2, frames: 900, sampleRate: 22_050, ended: true)
        XCTAssertEqual(SystemVoiceRuntime.classify(heard, finished: true, waited: 100, what: "a write"), .answered)
    }

    func testABrokenAnswerFailsAndAnAnswerPasses() throws {
        // Not nil: on a wedged simulator the rate test, which runs first, has already recorded a stall.
        let before = SystemVoiceRuntime.stalledEarlier
        XCTAssertNoThrow(try SystemVoiceRuntime.requireAnswered(.answered))
        XCTAssertThrowsError(try SystemVoiceRuntime.requireAnswered(.broken("no end"))) { error in
            XCTAssertTrue(error is SystemVoiceRuntime.VoiceFailure, "a broken voice fails, it does not skip: \(error)")
        }
        XCTAssertEqual(SystemVoiceRuntime.stalledEarlier, before, "a broken answer is not recorded as a stall")
    }

    /// A cold start that outlasts the wait answers late (#1230 saw over 3 minutes). Once that write
    /// delivers, the stall is cleared, so the next test runs instead of skipping. A stall that was
    /// already recorded by a test earlier in the process stays.
    func testAStalledWriteThatAnswersLaterIsNoLongerAStall() throws {
        let before = SystemVoiceRuntime.stalledEarlier
        let late = SystemVoiceRuntime.Listening()
        XCTAssertThrowsError(try SystemVoiceRuntime.requireAnswered(.stalled("a test write delivered nothing in 1 s"), from: late)) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        XCTAssertEqual(SystemVoiceRuntime.stalledEarlier, before ?? "a test write delivered nothing in 1 s")
        late.receive(try buffer(frames: 400))
        XCTAssertEqual(SystemVoiceRuntime.stalledEarlier, before, "the late answer clears the stall it recorded")
    }

    func testListeningCountsFramesUpToTheFirstEmptyBufferAndEndsOnce() throws {
        let listening = SystemVoiceRuntime.Listening()
        listening.receive(try buffer(frames: 400))
        listening.receive(try buffer(frames: 500))
        XCTAssertFalse(listening.heard.ended, "no end of speech yet")
        listening.receive(try buffer(frames: 0))
        listening.receive(try buffer(frames: 0))
        listening.receive(try buffer(frames: 700))
        XCTAssertEqual(XCTWaiter().wait(for: [listening.finished], timeout: 1), .completed)
        XCTAssertEqual(listening.heard, .init(buffers: 5, frames: 900, sampleRate: 22_050, ended: true))
    }
}
