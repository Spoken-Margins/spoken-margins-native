import Foundation
import SessionKit
import SessionKitAudio
import XCTest

/// No app test reaches the iPhone's speech voice (#4664).
///
/// The app asks one app-wide reader (`WrittenMarginReader.shared`) to render a written Margin when it plays and no
/// reading is made yet. In the app that render is a real `AVSpeechSynthesizer` write, which the hosted Mac's speech
/// service can hold for minutes. A test that played such a Margin ended with the render still running; the reader's
/// one lane stayed busy, and the next tests failed `expectSharedReaderIdle` ("left the shared written-Margin reader
/// busy") for a leak they had not made.
///
/// This installs, once when the bundle loads, a reader whose renderer writes a short silent file and returns, so every
/// test class is covered whether or not it knows about the reader. A test that wants a reading the app can find still
/// seeds the file and the reader finds it, as before. It is the same reader type, so the queue, the lane and the time
/// limit are the real ones; only the speech is not.
///
/// XCTest reaches it through `OpenDescriptorGuard`, the bundle's principal class, which calls `install()`.
enum WrittenMarginReaderForTests {
    /// The renderer of the installed reader: counts what it was asked to say and says nothing.
    final class SilentRenderer: @unchecked Sendable {
        private let lock = NSLock()
        private var spoken: [String] = []

        var renderedTexts: [String] { lock.withLock { spoken } }

        func render(_ text: String, scratch: URL) throws -> URL {
            lock.withLock { spoken.append(text) }
            let file = scratch.appending(path: "silence.wav")
            try Self.silentWAV(seconds: 0.2).write(to: file)
            return file
        }

        /// A valid 16-bit mono PCM file of silence, so whatever opens the reading can open it.
        static func silentWAV(seconds: Double, sampleRate: Int = 8_000) -> Data {
            let samples = Int(Double(sampleRate) * seconds)
            let dataBytes = samples * 2
            var wav = Data()
            func put32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
            func put16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }
            wav.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes)
            wav.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
            put32(sampleRate); put32(sampleRate * 2); put16(2); put16(16)
            wav.append(contentsOf: Array("data".utf8)); put32(dataBytes)
            wav.append(Data(count: dataBytes))
            return wav
        }
    }

    nonisolated(unsafe) static private(set) var renderer: SilentRenderer?
    nonisolated(unsafe) static private(set) var reader: WrittenMarginReader?

    static func install() {
        guard reader == nil else { return }
        let renderer = SilentRenderer()
        let reader = WrittenMarginReader(renderAudio: { try renderer.render($0, scratch: $1) })
        Self.renderer = renderer
        Self.reader = reader
        WrittenMarginReader.replaceShared(with: reader)
    }
}
