import AVFoundation
import Foundation
import SessionKit

/// The audio heard around streamed Margins, written to temporary files until a transcription uses them (#156).
///
/// Each window gets its own folder under `rootDirectory`. A window is kept only while its Margin can still use it
/// (#652): the caller drops it with `discard` when the Margin is gone or its context is already ready, and a
/// transcription `take`s it and deletes the folder when done. The map lives in memory, so folders left by an
/// earlier run of the app can never be used again; the first instance for a root in each process removes them.
public final class HeardSourceWindowFiles {
    public struct Segment: Equatable, Sendable {
        public let url: URL
        public let startMediaTimeMs: Int
        public let durationMs: Int
    }

    /// Shorter runs aren't worth transcribing.
    public static let minimumSegmentDurationMs = 2_000

    /// `Caches/HeardSourceWindows`, the app's folder for these files.
    public static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "HeardSourceWindows", directoryHint: .isDirectory)
    }

    public let rootDirectory: URL
    private var windows: [String: [Segment]] = [:]
    private static let purgedRootsLock = NSLock()
    nonisolated(unsafe) private static var purgedRoots: Set<String> = []

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        Self.purgeEarlierRunsOnce(in: rootDirectory)
    }

    /// The window kept for a Margin, if any.
    public func segments(for key: String) -> [Segment]? { windows[key] }

    /// Whether a heard window can still give this Margin its source context. A deleted or missing Margin can't use
    /// it, nor can a written one or one with no media time (the app only recovers context for spoken Margins at a
    /// time in the item), and a ready context isn't replaced by it.
    public static func isStillNeeded(by margin: Interjection?) -> Bool {
        guard let margin, margin.status != "deleted",
              margin.captureKind != .written,
              margin.targetType == .item,
              margin.anchor.mediaTimeMs != nil else { return false }
        return margin.anchorContextStatus != .ready
    }

    /// Writes the window's runs of at least two seconds to a new folder and keeps them for `key`, replacing (and
    /// deleting) a window for the same Margin that no transcription has taken. Keeps nothing when no run qualifies.
    @discardableResult
    public func store(_ window: HeardAudioWindow, key: String) throws -> [Segment] {
        let segments = try Self.write(window, in: rootDirectory)
        Self.delete(adopt(segments, key: key))
        return segments
    }

    /// The file half of `store`: writes the runs of at least two seconds to a new folder under `rootDirectory`
    /// (up to about two minutes of mono audio) and keeps nothing here. It touches no state, so the app runs it
    /// off the main thread (#2510); `adopt` then keeps what it returns.
    public static func write(_ window: HeardAudioWindow, in rootDirectory: URL) throws -> [Segment] {
        let directory = rootDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var segments: [Segment] = []
        do {
            for (index, run) in window.segments.enumerated() where window.durationMs(of: run) >= minimumSegmentDurationMs {
                let url = directory.appending(path: "segment-\(index).caf")
                try Self.write(run.samples, sampleRate: window.sampleRate, to: url)
                segments.append(Segment(url: url, startMediaTimeMs: run.startMediaTimeMs, durationMs: window.durationMs(of: run)))
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        guard !segments.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return []
        }
        return segments
    }

    /// Keeps segments `write` made as the window for `key`, and returns the window it replaced (one no transcription
    /// has taken) for the caller to `delete`. Nothing is kept, and nothing replaced, when `segments` is empty.
    public func adopt(_ segments: [Segment], key: String) -> [Segment] {
        guard !segments.isEmpty else { return [] }
        let replaced = windows.removeValue(forKey: key) ?? []
        windows[key] = segments
        return replaced
    }

    /// Hands the window to a transcription, which must `delete` it when done. It is no longer kept here.
    public func take(_ key: String) -> [Segment]? {
        windows.removeValue(forKey: key)
    }

    /// Drops a window nothing will use, and its files.
    public func discard(_ key: String) {
        if let segments = windows.removeValue(forKey: key) { Self.delete(segments) }
    }

    /// Like `discard`, but the folder is removed off the calling thread: the window is forgotten at once, so a
    /// caller on the main thread never waits on the files (#2510).
    public func discardInBackground(_ key: String) {
        if let segments = windows.removeValue(forKey: key) { Self.deleteInBackground(segments) }
    }

    /// Removes a taken window's folder.
    public static func delete(_ segments: [Segment]) {
        for directory in Set(segments.map { $0.url.deletingLastPathComponent().standardizedFileURL }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// `delete` on a background task, for a caller on the main thread.
    public static func deleteInBackground(_ segments: [Segment]) {
        guard !segments.isEmpty else { return }
        Task.detached(priority: .utility) { HeardSourceWindowFiles.delete(segments) }
    }

    private static func purgeEarlierRunsOnce(in rootDirectory: URL) {
        // Under the lock, so a second instance can't write a folder while the first is still clearing the root.
        purgedRootsLock.withLock {
            guard purgedRoots.insert(rootDirectory.standardizedFileURL.path).inserted,
                  let leftovers = try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            else { return }
            for leftover in leftovers { try? FileManager.default.removeItem(at: leftover) }
        }
    }

    private static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SessionKitError.persistenceFailed("heard_audio_buffer_unavailable")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
