import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
import CryptoKit

/// Leveled playback copies of spoken Margins (#467), made once and kept in a caches folder.
///
/// A copy is named for a hash of the recording's content and the kind of target it was leveled to, so
/// the same recording is leveled once, whatever path it is reached by (a shared Margin is re-imported,
/// an app container moves). A copy leveled to the fixed podcast level is replaced when the episode
/// turns up on the device (it is downloaded, or the file is imported), because then the Margin has an
/// episode to match. The recording is only read. Leveling runs one recording at a time on a utility
/// queue and never on the caller's thread.
///
/// A caller that needs the audio now asks `readyCopy` and plays the original when there is no copy
/// yet; `level` makes the copy for the next play (or waits for it). On the main thread, ask `knownCopy`
/// instead: it only looks at what `level` has already found and never reads the recording (#2510).
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

    /// Copies are 32-bit float (about 10 MB a minute for mono 44.1 kHz, twice that for stereo 48 kHz), so
    /// the folder is capped: 1 GB holds about an hour and a half of Margins. The copies that were used
    /// longest ago go first, and the system may clear a caches folder anyway: a missing copy is made
    /// again from the recording.
    public static let defaultMaximumBytes: Int64 = 1_024 * 1_048_576
    static let copyExtension = "caf"

    private let directory: URL
    private let maximumBytes: Int64
    private let queue = DispatchQueue(label: "SpokenMargins.LeveledMarginCache", qos: .utility)
    private let lock = NSLock()
    private var waiters: [String: [CheckedContinuation<Outcome, Never>]] = [:]
    /// The copy `level` last found or made for a recording as it was (path, size, modified), so the main thread
    /// can ask for it with two `stat`s instead of hashing the file. Guarded by `lock`.
    private var known: [Stamp: URL] = [:]

    private struct Stamp: Hashable {
        var path: String
        var bytes: Int
        var modified: Date

        init?(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let bytes = values.fileSize else { return nil }
            path = url.resolvingSymlinksInPath().path
            self.bytes = bytes
            modified = values.contentModificationDate ?? .distantPast
        }
    }

    public init(directory: URL, maximumBytes: Int64 = LeveledMarginCache.defaultMaximumBytes) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    /// The copy of this recording that is already made, or nil: the one matched to an episode if there is
    /// one, else the one at the fixed level. Cheap enough for the main thread: it hashes the recording and
    /// looks in one folder.
    public func readyCopy(for recording: URL) -> URL? {
        guard let hash = try? Self.contentHash(of: recording) else { return nil }
        return existingCopy(hash: hash)
    }

    /// The copy `level` has already found or made for this recording, or nil: it does not read the recording or
    /// list the folder, so it is safe on the main thread. Nil also before the first `level` of a launch, and for
    /// a recording changed since; the caller plays the original and asks `level` (#2510).
    public func knownCopy(for recording: URL) -> URL? {
        guard let stamp = Stamp(recording), let copy = lock.withLock({ known[stamp] }), isUsableCopy(copy) else { return nil }
        return copy
    }

    /// Removes every copy of this recording, for when the recording itself is deleted for good. Call it
    /// before the recording is removed: the copy is found by the recording's content. The removal runs
    /// on the leveling queue, after any render in progress, so a copy that is being made when the
    /// recording is deleted goes too; renders queued later fail because the recording is gone.
    public func removeCopies(of recording: URL) {
        guard let hash = try? Self.contentHash(of: recording) else { return }
        let path = recording.resolvingSymlinksInPath().path
        lock.withLock { known = known.filter { $0.key.path != path } }
        queue.async { [self] in
            for copy in copies() where copy.url.lastPathComponent.hasPrefix("\(hash)-") {
                try? FileManager.default.removeItem(at: copy.url)
            }
        }
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
                let stamp = Stamp(recording)
                let outcome = levelNow(recording, sourceWindow: sourceWindow)
                if let stamp, case .leveled(let copy) = outcome { lock.withLock { known[stamp] = copy } }
                let waiting = lock.withLock { waiters.removeValue(forKey: flight) ?? [] }
                for waiter in waiting { waiter.resume(returning: outcome) }
            }
        }
    }

    /// Returns once the work queued so far has finished. For tests.
    func waitForQueuedWork() { queue.sync {} }

    // MARK: Work (on the queue)

    private func levelNow(_ recording: URL, sourceWindow: SourceWindow?) -> Outcome {
        do {
            let hash = try Self.contentHash(of: recording)
            let existing = existingCopy(hash: hash)
            // A copy matched to the episode is final. Otherwise measure the episode, if there is one now.
            if let existing, !Self.isFixed(existing) { return .leveled(existing) }
            let matched = Self.matchedTarget(for: sourceWindow)
            if matched == nil, let existing { return .leveled(existing) }
            let name = Self.copyName(hash: hash, matchedTarget: matched)
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try MarginLoudnessLeveler.renderLeveledCopy(
                of: recording, to: destination, targetLUFS: matched ?? MarginLevelingTarget.fixedLUFS
            )
            if result.plan.limit == .silent {
                try? FileManager.default.removeItem(at: destination)
                return .original(reason: "silent")
            }
            if let existing { try? FileManager.default.removeItem(at: existing) }
            evict(keeping: destination)
            return .leveled(destination)
        } catch {
            return .original(reason: Self.reason(for: error))
        }
    }

    /// The loudness of the episode around the Margin, on the cache's grid, when the episode is on the
    /// device and that stretch of it can be measured; nil means the fixed level.
    static func matchedTarget(for sourceWindow: SourceWindow?) -> Double? {
        guard let sourceWindow,
              let window = MarginLevelingTarget.sourceWindow(anchorMediaTimeMs: sourceWindow.anchorMediaTimeMs, sourceDurationMs: nil),
              let measured = try? MarginLoudnessLeveler.measure(
                  fileAt: sourceWindow.file, startMs: window.startMs, durationMs: window.durationMs
              ),
              MarginLevelingTarget.isMatchable(measured) else {
            return nil
        }
        return MarginLevelingTarget.targetLUFS(sourceWindow: measured)
    }

    /// The finished copy for this content, matched to an episode if there is one, else fixed. Marks it used.
    private func existingCopy(hash: String) -> URL? {
        let matched = copies()
            .filter { $0.url.lastPathComponent.hasPrefix("\(hash)-m") }
            .max { $0.modified < $1.modified }?.url
        let fixed = directory.appendingPathComponent(Self.copyName(hash: hash, matchedTarget: nil))
        guard let url = matched ?? (isUsableCopy(fixed) ? fixed : nil) else { return nil }
        touch(url)
        return url
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
            // Built from `directory` rather than taken from the listing, which can spell the path differently
            // (/private/var for /var), so every URL this cache hands out for a copy is the same one.
            return Copy(
                url: directory.appendingPathComponent(url.lastPathComponent),
                bytes: Int64(bytes),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private func isUsableCopy(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0
    }

    /// Marks a copy as used now, so eviction keeps the ones that are still being played.
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Removes the least recently used copies until the folder fits, never the one just made. Also removes
    /// half-written copies an interrupted render left behind (hidden files, an hour old or more).
    private func evict(keeping keep: URL) {
        sweepInterruptedRenders()
        var all = copies()
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > maximumBytes else { return }
        all.sort { $0.modified < $1.modified }
        for copy in all where total > maximumBytes && copy.url.lastPathComponent != keep.lastPathComponent {
            if (try? FileManager.default.removeItem(at: copy.url)) != nil { total -= copy.bytes }
        }
    }

    private func sweepInterruptedRenders() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let cutoff = Date().addingTimeInterval(-3_600)
        for url in urls where url.lastPathComponent.hasPrefix(".leveling-") {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Names

    /// `<hash>-fixed-v1.caf`, or `<hash>-m<steps>-v1.caf` for a copy matched to an episode, where steps
    /// count the grid's half decibels. Bump the version when the leveling changes, so old copies aren't
    /// played in place of new ones.
    static func copyName(hash: String, matchedTarget: Double?) -> String {
        guard let matchedTarget else { return "\(hash)-fixed-v1.\(copyExtension)" }
        let steps = Int((-MarginLevelingTarget.rounded(matchedTarget) / MarginLevelingTarget.cacheStepDB).rounded())
        return "\(hash)-m\(steps)-v1.\(copyExtension)"
    }

    static func isFixed(_ url: URL) -> Bool { url.lastPathComponent.contains("-fixed-") }

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
