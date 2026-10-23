import Foundation
import XCTest

/// Hears what a test played, through BlackHole on the Mac (#1790). verify-tests.py starts the window server
/// (ops/audio-loopback/window.py) when a run includes an AudioLoopback test and passes its folder as
/// SM_AUDIO_WINDOW; the Simulator writes and reads that folder on the Mac's disk directly.
///
/// Use: `open` a window before playing, `waitUntilRecording`, play, then `verdict` and `require`. Without a
/// server (a run that didn't ask for it, or a Mac without BlackHole) the test skips, which the lane reports as
/// INCONCLUSIVE, never as a pass.
struct AudioLoopbackWindow {
    struct Limits {
        /// Fail on a silence longer than this between sounds or, unless `allowTrailing`, after the last one.
        var maxStall: Double? = 2.0
        /// Fail with less sound than this in the window.
        var minSound: Double?
        /// Fail above this word error rate against the expected text.
        var maxWER: Double? = 0.25
        /// The window is longer than the audio on purpose, so silence at its end is fine.
        var allowTrailing = true
        var allowRepeats = false
    }

    /// How long the Mac waits for another audio window to end; a test's allowance is at most 180 s.
    static let lockWait: Double = 40

    let folder: URL
    let id: String

    static func open(for test: XCTestCase, seconds: Double, expected: String?, limits: Limits = Limits()) throws -> AudioLoopbackWindow {
        guard let path = ProcessInfo.processInfo.environment["SM_AUDIO_WINDOW"], !path.isEmpty else {
            throw XCTSkip("No audio window on this run: name this test in a /lane T3 request (ops/audio-loopback/README.md).")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready.json").path) else {
            throw XCTSkip("The audio window server isn't running in \(path).")
        }
        let name = test.name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let window = AudioLoopbackWindow(folder: folder, id: "\(name)-\(UUID().uuidString.prefix(8))")
        var request: [String: Any] = ["seconds": seconds, "test": test.name,
                                      "lock_wait": lockWait,
                                      "allow_trailing": limits.allowTrailing, "allow_repeats": limits.allowRepeats]
        request["expected"] = expected
        request["max_stall"] = limits.maxStall
        request["min_sound"] = limits.minSound
        request["max_wer"] = limits.maxWER
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        try data.write(to: window.file("request.json"), options: .atomic)
        return window
    }

    private func file(_ suffix: String) -> URL { folder.appendingPathComponent("\(id).\(suffix)") }

    private func readResult() -> [String: Any]? {
        guard let data = try? Data(contentsOf: file("result.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Waits until the Mac records. The server waits up to `lockWait` for another window to end (the request
    /// says so), then answers instead; an answer (busy, no BlackHole, recorder failed) skips with its reason.
    func waitUntilRecording(timeout: Duration = .seconds(AudioLoopbackWindow.lockWait + 45)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: file("recording").path) { return }
            if let answer = readResult() { throw XCTSkip("The audio window didn't open: \(answer["summary"] ?? answer)") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("The audio window didn't open within \(timeout).")
    }

    /// The Mac's verdict once the window has ended and the recording has been checked.
    func verdict(timeout: Duration = .seconds(120)) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let answer = readResult() { return answer }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw XCTSkip("The audio window gave no verdict within \(timeout).")
    }

    /// Attaches the verdict, fails on FAIL, and skips on UNAVAILABLE (the lane couldn't listen). On the main
    /// actor: XCTContext throws "Current context must not be nil" off it (first lane run, PR #2050).
    @MainActor
    func require(_ answer: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let summary = answer["summary"] as? String ?? "no summary"
        if let data = try? JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "audio-window-\(id).json"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Audio window: \(summary)") { $0.add(attachment) }
        }
        switch answer["verdict"] as? String {
        case "PASS": return
        case "FAIL": XCTFail("What came out of the speakers broke an expectation. \(summary)", file: file, line: line)
        default: throw XCTSkip("The lane couldn't listen: \(summary)")
        }
    }
}
