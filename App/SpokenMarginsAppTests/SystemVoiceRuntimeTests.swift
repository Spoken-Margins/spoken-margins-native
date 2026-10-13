import AVFoundation
import SessionKitAudio
import XCTest

/// #768: the check the system-voice tests run before starting an audio engine. A render that times
/// out or comes back without audio must read as a stall, or the session test starts its engine on a
/// wedged simulator and the app aborts; any other error must surface, not turn into a skip. Uses
/// scripted renders and `probe`, which records nothing, so it can't skip the real tests later.
final class SystemVoiceRuntimeTests: XCTestCase {
    private struct Unrelated: Error {}

    func testATimedOutRenderIsAStall() async throws {
        let answer = try await SystemVoiceRuntime.probe(timeout: 30) { _, _, _ in
            throw SystemVoiceChunkRenderer.Failure.timedOut
        }
        XCTAssertEqual(answer, .stalled("a one-word render did not finish in 30 s"))
    }

    func testARenderWithNoAudioIsAStall() async throws {
        let answer = try await SystemVoiceRuntime.probe(timeout: 30) { _, _, _ in
            throw SystemVoiceChunkRenderer.Failure.noAudio
        }
        XCTAssertEqual(answer, .stalled("a one-word render produced no audio"))
    }

    func testARenderThatFinishesIsAnAnswer() async throws {
        var asked: (reference: URL, output: URL, timeout: TimeInterval)?
        let answer = try await SystemVoiceRuntime.probe(timeout: 12) { reference, output, timeout in
            asked = (reference, output, timeout)
            return 0.4
        }
        XCTAssertEqual(answer, .answered)
        XCTAssertEqual(asked?.timeout, 12, "the render gets the probe's timeout")
        let reference = try XCTUnwrap(asked?.reference)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reference.path), "the probe cleans up after itself")
    }

    func testTheReferenceIsARealAudioFileWhileTheRenderRuns() async throws {
        var frames: AVAudioFramePosition = 0
        _ = try await SystemVoiceRuntime.probe(timeout: 1) { reference, _, _ in
            frames = try AVAudioFile(forReading: reference).length
            return 0.4
        }
        XCTAssertGreaterThan(frames, 0)
    }

    func testAnyOtherErrorIsThrownNotSkipped() async {
        do {
            _ = try await SystemVoiceRuntime.probe(timeout: 1) { _, _, _ in throw Unrelated() }
            XCTFail("an unrelated error must surface")
        } catch {
            XCTAssertTrue(error is Unrelated, "\(error)")
        }
    }
}
