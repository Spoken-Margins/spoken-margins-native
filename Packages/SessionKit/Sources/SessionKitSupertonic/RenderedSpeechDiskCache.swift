import AVFoundation
import CryptoKit
import Foundation
import SessionKit

/// The rendered-speech files Supertonic keeps between plays, named by a digest of what was rendered and
/// trimmed least-recently-used to a byte limit.
public final class RenderedSpeechDiskCache: @unchecked Sendable {
    private let directory: URL
    private var limitBytes: Int
    private let fileManager: FileManager
    private let lock = NSLock()

    /// `trimsOnInit: false` leaves the first trim to the caller's `setLimitBytes`, which lists the whole
    /// directory and so belongs off the main actor (#2510).
    public init(directory: URL, limitBytes: Int, trimsOnInit: Bool = true, fileManager: FileManager = .default) throws {
        self.directory = directory.standardizedFileURL
        self.limitBytes = max(1, limitBytes)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resourceValues)
        if trimsOnInit { enforceLimit(protecting: nil) }
    }

    public func cachedAudio(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) -> SupertonicNarrationResult? {
        lock.withLock {
            let url = cacheURL(
                text: text,
                voice: voice,
                language: language,
                speed: speed,
                synthesisSteps: synthesisSteps
            )
            guard fileManager.fileExists(atPath: url.path),
                  let audio = try? AVAudioFile(forReading: url),
                  audio.processingFormat.sampleRate > 0,
                  audio.length > 0 else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return SupertonicNarrationResult(
                audioURL: url,
                duration: Double(audio.length) / audio.processingFormat.sampleRate,
                sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
                renderDuration: 0,
                sessionLoadCount: 0,
                engine: SupertonicNarrationResult.supertonicEngine
            )
        }
    }

    public func store(
        _ result: SupertonicNarrationResult,
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) throws -> SupertonicNarrationResult {
        try lock.withLock {
            let destination = cacheURL(
                text: text,
                voice: voice,
                language: language,
                speed: speed,
                synthesisSteps: synthesisSteps
            )
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: result.audioURL, to: destination)
            }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            enforceLimit(protecting: destination)
            return SupertonicNarrationResult(
                audioURL: destination,
                duration: result.duration,
                sampleRate: result.sampleRate,
                renderDuration: result.renderDuration,
                sessionLoadCount: result.sessionLoadCount,
                engine: result.engine,
                trimmedSilence: result.trimmedSilence
            )
        }
    }

    public func owns(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory
    }

    public func invalidate(_ url: URL) {
        guard owns(url) else { return }
        lock.withLock {
            try? fileManager.removeItem(at: url)
        }
    }

    public func setLimitBytes(_ limitBytes: Int) {
        lock.withLock {
            self.limitBytes = max(1, limitBytes)
            enforceLimit(protecting: nil)
        }
    }

    public var sizeBytes: Int {
        lock.withLock { cacheEntries().reduce(0) { $0 + $1.size } }
    }

    /// Deletes every cached file and returns the bytes freed.
    @discardableResult
    public func removeAll() -> Int64 {
        lock.withLock { Self.removeAll(in: directory, fileManager: fileManager) }
    }

    /// The same, for a cache directory no instance has open.
    public static func removeAll(in directory: URL, fileManager: FileManager = .default) -> Int64 {
        RenderedSpeechCacheFiles.removeAll(in: directory, fileManager: fileManager)
    }

    private func cacheURL(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) -> URL {
        // v2: v1 entries can hold iOS-voice stand-ins cached as Supertonic before #311; they now
        // miss once and age out under the cache limit (#363 audit). v3: v2 entries still carry the
        // model's silence before and after the speech, so they miss once and render trimmed (#586).
        let payload = "supertonic-v3\u{1f}\(voice.rawValue)\u{1f}\(language)\u{1f}\(speed)\u{1f}\(synthesisSteps)\u{1f}\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(digest).wav")
    }

    private func enforceLimit(protecting protectedURL: URL?) {
        var entries = cacheEntries().sorted { $0.modifiedAt < $1.modifiedAt }
        var total = entries.reduce(0) { $0 + $1.size }
        // The directory listing can spell the same file as /private/var/... where the stored URL says /var/...
        // (and the reverse), so the file just stored is matched by its standardized path.
        let protectedPath = protectedURL?.standardizedFileURL.path
        while total > limitBytes, let index = entries.firstIndex(where: { $0.url.standardizedFileURL.path != protectedPath }) {
            let entry = entries.remove(at: index)
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func cacheEntries() -> [RenderedSpeechCacheFiles.Entry] {
        RenderedSpeechCacheFiles.entries(in: directory, fileManager: fileManager)
    }
}

extension RenderedSpeechDiskCache: RenderedSpeechCacheClearing {}
