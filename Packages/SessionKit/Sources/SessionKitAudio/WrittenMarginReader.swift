import Foundation
import SessionKit

#if canImport(AVFoundation)
/// Turns a written Margin's words into an audio file the Margin-moment conductor plays as it plays a recording (#3365):
/// the same tone, the same pause of the episode, the same skip, interruption and heard-marking, with no second playback
/// machine. The iPhone's voice does the reading (`SystemTextAudioPreparationClient`, `AVSpeechSynthesizer.write`) for
/// everyone, before and after the Terms (owner, 2026-11-02, "the iPhone voice"). It takes (words, spoken intro, voice),
/// not a Margin, so the listener's chosen voice and the reading of an episode's quote can use it later.
///
/// A file's path comes from its words and voice alone, so a caller can name the file without touching the disk and the
/// render can happen any time before the Margin plays. A render is written to a scratch folder and moved into place only
/// when complete, so a file that exists is whole. Everything that touches the disk runs on the reader's own queue,
/// never the main thread.
public final class WrittenMarginReader: @unchecked Sendable {
    public static let shared = WrittenMarginReader()

    /// Where rendered readings are kept. Caches, so the system may clear them and the next play renders again. Built
    /// from the path alone: nothing is read or created.
    public static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "SpokenMargins/WrittenMargins", directoryHint: .isDirectory)
    }

    public enum RenderError: Error, Equatable { case nothingToSay }

    private let directory: URL
    private let voiceIdentifier: String?
    private let renderAudio: @Sendable (_ spokenText: String, _ scratch: URL) throws -> URL
    // Its own queue, a step above the shared `.utility` render queue: a listener is waiting on this one.
    private let queue = DispatchQueue(label: "SessionKitAudio.WrittenMarginReader", qos: .userInitiated)
    private let lock = NSLock()
    private var waiting: [String: [@Sendable (Result<URL, Error>) -> Void]] = [:]

    /// `renderAudio` writes the speech for `spokenText` somewhere under `scratch` and returns that file. The default is
    /// the iPhone voice.
    public init(
        directory: URL = WrittenMarginReader.defaultDirectory,
        voiceIdentifier: String? = nil,
        renderAudio: (@Sendable (_ spokenText: String, _ scratch: URL) throws -> URL)? = nil
    ) {
        self.directory = directory
        self.voiceIdentifier = voiceIdentifier
        self.renderAudio = renderAudio ?? { text, scratch in
            let client = SystemTextAudioPreparationClient(outputDirectory: scratch, voiceIdentifier: voiceIdentifier)
            guard let prepared = try client.prepareTextAudio(itemId: "written-margin", title: "Written Margin", text: text),
                  let url = prepared.media.url.flatMap({ URL(string: $0) }) else { throw RenderError.nothingToSay }
            return url
        }
    }

    /// Where this reading's file is, or will be. Pure: no disk access.
    public func fileURL(for reading: WrittenMarginReading) -> URL {
        let seed = ["written-margin-reading-v1", voiceIdentifier ?? "default", reading.spokenText].joined(separator: "\u{1f}")
        let digest = Self.fingerprint(seed)
        return directory.appending(path: "\(digest).caf", directoryHint: .notDirectory)
    }

    /// A stable 128-bit name from two FNV-1a runs with different starting values, plus the length. Plain arithmetic on
    /// the words in memory: naming a file never reads the disk, so the main thread can ask for a path.
    static func fingerprint(_ seed: String) -> String {
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        var b: UInt64 = 0x84222325_cbf29ce4
        var count: UInt64 = 0
        for byte in seed.utf8 {
            a = (a ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            b = (b ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 &+ count
            count += 1
        }
        return String(format: "%016llx%016llx-%llx", a, b, count)
    }

    /// Names each reading's file and starts rendering the ones that are not on disk yet, off the calling thread. Returns
    /// at once with the paths, keyed as the caller keyed the readings; a file may not exist yet when this returns.
    public func start(_ readings: [String: WrittenMarginReading]) -> [String: URL] {
        var urls: [String: URL] = [:]
        for (key, reading) in readings {
            urls[key] = fileURL(for: reading)
            ensureRendered(reading) { _ in }
        }
        return urls
    }

    /// The reading's file once it is on disk: already there, or rendered now. Never blocks the caller's thread.
    public func rendered(_ reading: WrittenMarginReading) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            ensureRendered(reading) { continuation.resume(with: $0) }
        }
    }

    private func ensureRendered(_ reading: WrittenMarginReading, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        let target = fileURL(for: reading)
        lock.lock()
        if waiting[target.path] != nil {
            waiting[target.path]?.append(completion) // the same words are already being rendered: share that render
            lock.unlock()
            return
        }
        waiting[target.path] = [completion]
        lock.unlock()
        queue.async { [self] in
            let result = Result<URL, Error> { try render(reading, to: target) }
            lock.lock()
            let done = waiting.removeValue(forKey: target.path) ?? []
            lock.unlock()
            done.forEach { $0(result) }
        }
    }

    private func render(_ reading: WrittenMarginReading, to target: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) { return target }
        let scratch = directory.appending(path: "scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let rendered = try renderAudio(reading.spokenText, scratch)
        try fileManager.moveItem(at: rendered, to: target)
        return target
    }
}
#endif
