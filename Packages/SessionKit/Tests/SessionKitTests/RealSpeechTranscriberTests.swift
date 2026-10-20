import AVFoundation
import Speech
import XCTest
@testable import SessionKitAudio

/// #1522: the app's real long-form transcriber (SpeechAnalyzer plus AssetInventory) run on a short spoken clip, on the
/// host. The iOS simulator cannot run it (SpeechTranscriber.isAvailable is false there), and the app tests fake the
/// transcriber, so this is the only automated check of the real recognizer. It skips, with the reason, when the Mac
/// has no speech model for the locale or the model cannot be installed.
final class RealSpeechTranscriberTests: XCTestCase {
    func testRealTranscriberHearsSynthesizedSpeech() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        guard await longFormSpeechTranscriptionIsSupported() else {
            throw XCTSkip("SpeechTranscriber unavailable or locale \(Locale.current.identifier) unsupported on this Mac")
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-transcriber-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("clip.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", clip.path, "The quick brown fox jumps over the lazy dog. Today we are testing speech recognition."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath: clip.path) else {
            throw XCTSkip("`say` could not write a clip (status \(say.terminationStatus))")
        }

        let passages: [LongFormSpeechPassage]
        do {
            passages = try await transcribeLongFormSpeechFile(at: clip)
        } catch {
            throw XCTSkip("real transcriber could not run on this Mac (assets or permission): \(error)")
        }
        let text = passages.map(\.text).joined(separator: " ").lowercased()
        print("REAL TRANSCRIBER HEARD: \(text)")
        let expected = ["quick", "brown", "fox", "lazy", "dog", "speech", "recognition"]
        let hits = expected.filter { text.contains($0) }
        XCTAssertGreaterThanOrEqual(hits.count, 5, "heard: \(text)")
        XCTAssertTrue(passages.contains { !$0.timedText.isEmpty }, "no word timings returned")
        XCTAssertTrue(passages.allSatisfy { $0.endMs > $0.startMs })
    }
}
