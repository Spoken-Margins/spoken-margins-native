import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
import CryptoKit

/// Leveled playback copies of spoken Margins (#467), made once and kept in a caches folder.
///
/// A copy is named for a hash of the recording's content, so the same recording is leveled once,
/// whatever path it is reached by (a shared Margin is re-imported, an app container moves). The first
/// target a recording is leveled to is the one it keeps. The recording is only read. Leveling runs one
/// recording at a time on a utility queue and never on the caller's thread.
///
/// A caller that needs the audio now asks `readyCopy` and plays the original when there is no copy
/// yet; `level` makes the copy for the next play (or waits for it).
public final class LeveledMarginCache: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case leveled(URL)
        /// The recording plays as it is. `reason` is a short code for diagnostics, never a path or text.
        case original(reason: String)

        public var diagnosticValue: String {
            switch self {
            case .leveled: return "leveled"
            case .original(let reason): return "original:\(reason)"
            }
        }
    }

    /// The part of an episode that sets a Margin's target: `file` is the episode on the device,
    /// `anchorMediaTimeMs` where the Margin sits in it.
    public struct SourceWindow: Equatable, Sendable {
        public var file: URL
        public var anchorMediaTimeMs: Int

        public init(file: URL, anchorMediaTimeMs: Int) {
            self.file = file
            self.anchorMediaTimeMs = anchorMediaTimeMs
        }
    }

    /// Copies are 32-bit float (about 10 MB a minute for mono 44.1 kHz), so the folder is capped. The
    /// copies that were used longest ago go first, and the system may clear a caches folder anyway:
    /// a missing copy is made again from the recording.
    public static let defaultMaximumBytes: Int64 = 256 * 1_048_576
    static let copyExtension = "caf"

    private let directory: URL
    private let maximumBytes: Int64
    private let queue = DispatchQueue(label: "SpokenMargins.LeveledMarginCache", qos: .utility)
    private let lock = NSLock()
    private var waiters: [String: [CheckedContinuation<Outcome, Never>]] = [:]

    public init(directory: URL, maximumBytes: Int64 = LeveledMarginCache.defaultMaximumBytes) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    /// The copy of this recording that is already made, or nil. Cheap enough for the main thread: it
    /// hashes the recording and looks for one file.
    public func readyCopy(for recording: URL) -> URL? {
        guard let name = try? Self.copyName(for: recording) else { return nil }
        let url = directory.appendingPathComponent(name)
        guard isUsableCopy(url) else { return nil }
        touch(url)
        return url
    }

    /// Makes the copy if there isn't one, and says which file to play. Several callers asking for the
    /// same recording and window share one piece of work.
    public func level(_ recording: URL, sourceWindow: SourceWindow? = nil) async -> Outcome {
        let flight = "\(recording.standardizedFileURL.path)|\(sourceWindow?.file.path ?? "")|\(sourceWindow?.anchorMediaTimeMs ?? -1)"
        return await withCheckedContinuation { continuation in
            let isFirst: Bool = lock.withLock {
                if waiters[flight] != nil {
                    waiters[flight]?.append(continuation)
                    return false
                }
                waiters[flight] = [continuation]
                return true
            }
            guard isFirst else { return }
            queue.async { [self] in
                let outcome = levelNow(recording, sourceWindow: sourceWindow)
                let waiting = lock.withLock { waiters.removeValue(forKey: flight) ?? [] }
                for waiter in waiting { waiter.resume(returning: outcome) }
            }
        }
    }

    // MARK: Work (on the queue)

    private func levelNow(_ recording: URL, sourceWindow: SourceWindow?) -> Outcome {
        do {
            let destination = directory.appendingPathComponent(try Self.copyName(for: recording))
            if isUsableCopy(destination) {
                touch(destination)
                return .leveled(destination)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try MarginLoudnessLeveler.renderLeveledCopy(
                of: recording, to: destination, targetLUFS: Self.targetLUFS(for: sourceWindow)
            )
            if result.plan.limit == .silent {
                try? FileManager.default.removeItem(at: destination)
                return .original(reason: "silent")
            }
            evict(keeping: destination)
            return .leveled(destination)
        } catch {
            return .original(reason: Self.reason(for: error))
        }
    }

    /// The loudness to level to: the episode's, around the Margin, when the episode is on the device
    /// and can be measured; otherwise the fixed level.
    static func targetLUFS(for sourceWindow: SourceWindow?) -> Double {
        guard let sourceWindow else { return MarginLevelingTarget.fixedLUFS }
        let duration = try? MarginLoudnessLeveler.durationMs(ofFileAt: sourceWindow.file)
        guard let window = MarginLevelingTarget.sourceWindow(
            anchorMediaTimeMs: sourceWindow.anchorMediaTimeMs, sourceDurationMs: duration
        ) else {
            return MarginLevelingTarget.fixedLUFS
        }
        let measured = try? MarginLoudnessLeveler.measure(
            fileAt: sourceWindow.file, startMs: window.startMs, durationMs: window.durationMs
        )
        return MarginLevelingTarget.targetLUFS(sourceWindow: measured)
    }

    // MARK: Files

    private struct Copy {
        var url: URL
        var bytes: Int64
        var modified: Date
    }

    /// The finished copies. Hidden files are copies still being written.
    private func copies() -> [Copy] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == Self.copyExtension,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let bytes = values.fileSize, bytes > 0 else { return nil }
            return Copy(url: url, bytes: Int64(bytes), modified: values.contentModificationDate ?? .distantPast)
        }
    }

    private func isUsableCopy(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// Marks a copy as used now, so eviction keeps the ones that are still being played.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes the least recently used copies until the folder fits, never the one just made.
    private func evict(keeping keep: URL) {
        var all = copies()
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > maximumBytes else { return }
        all.sort { $0.modified < $1.modified }
        for copy in all where total > maximumBytes && copy.url != keep {
            if (try? FileManager.default.removeItem(at: copy.url)) != nil { total -= copy.bytes }
        }
    }

    // MARK: Names

    /// Bump the version when the leveling changes, so old copies aren't played in place of new ones.
    static func copyName(for recording: URL) throws -> String {
        "\(try contentHash(of: recording))-v1.\(copyExtension)"
    }

    /// SHA-256 of the file's bytes, read a megabyte at a time.
    static func contentHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func reason(for error: Error) -> String {
        if let leveler = error as? MarginLoudnessLeveler.LevelerError {
            switch leveler {
            case .destinationIsSource: return "destination_is_source"
            case .unsupportedChannelCount(let count): return "unsupported_channels_\(count)"
            case .unreadable: return "unreadable"
            }
        }
        let nsError = error as NSError
        return "failed_\(nsError.domain)_\(nsError.code)"
    }
}
#endif
