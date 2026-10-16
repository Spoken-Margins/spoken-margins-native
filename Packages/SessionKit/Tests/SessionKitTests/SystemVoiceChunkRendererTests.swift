#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKitAudio

/// #1230: the iOS-voice stand-in crashed the app inside Apple's TextToSpeech, and its 30 s
/// timeout did not fire while `AVSpeechSynthesizer.write` sat blocked inside TextToSpeech.
final class SystemVoiceChunkRendererTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "system-voice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let text = "Table 3 reports 91.1% and 8.9% across 7,494 tool decisions."
    private let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!

    /// A Supertonic-shaped chunk to match: 44.1 kHz mono.
    private func reference() throws -> URL {
        let url = root.appending(path: "reference.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try file.write(from: buffer)
        return url
    }

    // The synthesizer sends a second empty buffer and more after the render has returned, on the
    // main queue, as macOS 26 does. The render keeps only what came before the first end.
    func testBuffersAfterTheFirstEndOfStreamAreIgnored() async throws {
        let output = root.appending(path: "late.wav")
        let renderer = SystemVoiceChunkRenderer(usesApplicationAudioSession: false, releaseDelay: 0.05) { [speechFormat] synthesizer, utterance, callback in
            let make = { (frames: AVAudioFrameCount) -> AVAudioPCMBuffer in
                let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: max(frames, 1))!
                buffer.frameLength = frames
                return buffer
            }
            let box = SynthesizerBox()
            box.set(synthesizer, utterance)
            DispatchQueue.main.async {
                callback(make(22_050))
                callback(make(0))
                callback(make(0))
                callback(make(22_050))
                box.finish()
            }
        }
        let duration = try await renderer.render(text: text, voiceIdentifier: nil, matching: try reference(), to: output)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(duration, 1, accuracy: 0.01, "one second of speech, not two")
        XCTAssertEqual(Double(try AVAudioFile(forReading: output).length) / 44_100, duration, accuracy: 0.01)
    }

    // The crash: the synthesizer was released as soon as the render returned, while it still had
    // work queued on the main queue. It is now kept until it says it finished.
    func testTheSynthesizerIsKeptUntilItFinishes() async throws {
        let held = SynthesizerBox()
        let renderer = SystemVoiceChunkRenderer(usesApplicationAudioSession: false, releaseDelay: 0.05) { [speechFormat] synthesizer, utterance, callback in
            held.set(synthesizer, utterance)
            DispatchQueue.main.async {
                let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: 22_050)!
                buffer.frameLength = 22_050
                callback(buffer)
                callback(AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: 1)!)
            }
        }
        _ = try await renderer.render(text: text, voiceIdentifier: nil, matching: try reference(), to: root.appending(path: "kept.wav"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(held.synthesizer, "the synthesizer outlives the render until it finishes")

        await MainActor.run { held.finish() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(held.synthesizer, "and is let go once it has")
    }

    // The lane caught `write` blocked inside TextToSpeech for over two minutes on a Swift task
    // thread, so the 30 s timeout never fired and the test ran out of time. The timeout now fires
    // whatever the write does, and a write that wakes up later writes nothing.
    func testATimeoutFiresWhileTheWriteIsBlocked() async throws {
        let output = root.appending(path: "blocked.wav")
        let release = DispatchSemaphore(value: 0)
        let woke = expectation(description: "the blocked write returned")
        let renderer = SystemVoiceChunkRenderer(usesApplicationAudioSession: false, releaseDelay: 0.05) { [speechFormat] _, _, callback in
            _ = release.wait(timeout: .now() + 5)
            let buffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: 22_050)!
            buffer.frameLength = 22_050
            callback(buffer)
            callback(AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: 1)!)
            woke.fulfill()
        }
        let started = Date()
        do {
            _ = try await renderer.render(text: text, voiceIdentifier: nil, matching: try reference(), to: output, timeout: 0.3)
            XCTFail("a blocked write timed out")
        } catch let failure as SystemVoiceChunkRenderer.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
        let waited = Date().timeIntervalSince(started)
        release.signal()
        XCTAssertLessThan(waited, 2, "the timeout fired after \(waited) s, not when the write returned")
        await fulfillment(of: [woke], timeout: 5)
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 0, "nothing was written after the timeout")
    }

    // #1688: on a speech service still starting, `AVSpeechSynthesisVoice(identifier:)` blocked
    // for minutes, and the render called it on its caller's thread before the timeout was set, so
    // the timeout never fired. The lookup now runs in the timed write, and a write whose lookup
    // returns after the timeout is never started.
    func testATimeoutFiresWhileTheVoiceLookupIsBlocked() async throws {
        let release = DispatchSemaphore(value: 0)
        let looked = expectation(description: "the blocked lookup returned")
        let wrote = LockedFlag()
        let renderer = SystemVoiceChunkRenderer(
            usesApplicationAudioSession: false, releaseDelay: 0.05,
            voiceLookup: { _ in
                _ = release.wait(timeout: .now() + 5)
                looked.fulfill()
                return nil
            },
            speechWrite: { _, _, _ in wrote.set() }
        )
        let started = Date()
        do {
            _ = try await renderer.render(
                text: text, voiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
                matching: try reference(), to: root.appending(path: "lookup.wav"), timeout: 0.3
            )
            XCTFail("a blocked voice lookup timed out")
        } catch let failure as SystemVoiceChunkRenderer.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
        let waited = Date().timeIntervalSince(started)
        release.signal()
        XCTAssertLessThan(waited, 2, "the timeout fired after \(waited) s, not when the lookup returned")
        await fulfillment(of: [looked], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(wrote.value, "no write starts after the render timed out")
    }

    // The real synthesizer on this Mac: a stand-in is written in the reference's format, and the
    // synthesizer is let go after it finishes.
    func testTheSystemVoiceWritesAStandInAndLetsGoOfItsSynthesizer() async throws {
        let before = SystemVoiceChunkRenderer.heldWriteCount
        let output = root.appending(path: "real.wav")
        let duration = try await SystemVoiceChunkRenderer().render(text: text, voiceIdentifier: nil, matching: try reference(), to: output)
        XCTAssertGreaterThan(duration, 1, "the voice read the text")
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(Double(file.length) / 44_100, duration, accuracy: 0.05)
        for _ in 0..<50 where SystemVoiceChunkRenderer.heldWriteCount > before {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertLessThanOrEqual(SystemVoiceChunkRenderer.heldWriteCount, before, "the synthesizer was let go after it finished")
    }
}

private final class SynthesizerBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var weakSynthesizer: AVSpeechSynthesizer?
    private var utterance: AVSpeechUtterance?
    var synthesizer: AVSpeechSynthesizer? { lock.withLock { weakSynthesizer } }

    func set(_ synthesizer: AVSpeechSynthesizer, _ utterance: AVSpeechUtterance) {
        lock.withLock { weakSynthesizer = synthesizer; self.utterance = utterance }
    }

    func finish() {
        guard let synthesizer, let utterance = lock.withLock({ utterance }) else { return }
        synthesizer.delegate?.speechSynthesizer?(synthesizer, didFinish: utterance)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
#endif
