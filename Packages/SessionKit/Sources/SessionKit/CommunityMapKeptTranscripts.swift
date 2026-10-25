import Foundation

/// Phone-made transcripts kept beside their community-map upload record while the upload waits for a retry
/// (#552), one file per episode key. The map job deletes its transcript once the map is made and the phone's
/// transcript isn't stored, so this file is the only copy a retry has.
///
/// Uploads read and write here off the main actor (#2507), so two attempts for one episode can interleave:
/// one finishing while the next has already saved its transcript. A finished attempt therefore removes only
/// the transcript it sent (`remove(episodeKey:ifHolding:)`), and every read, save and removal holds one lock,
/// so a save can't land between that check and the removal.
public struct CommunityMapKeptTranscripts: Sendable {
    public let folder: URL
    private let protection: Data.WritingOptions

    /// `protection` is the file-protection class for saved files (the app passes one; tests and Linux none).
    public init(folder: URL, protection: Data.WritingOptions = []) {
        self.folder = folder
        self.protection = protection
    }

    private static let lock = NSLock()

    public func load(episodeKey: String) -> TranscriptTimeline? {
        Self.lock.withLock { read(episodeKey) }
    }

    /// Saves the transcript for a retry. Says whether it was saved.
    @discardableResult
    public func save(_ timeline: TranscriptTimeline, episodeKey: String) -> Bool {
        guard let data = try? JSONEncoder().encode(timeline) else { return false }
        return Self.lock.withLock {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try? data.write(to: url(episodeKey), options: [.atomic, protection])) != nil
        }
    }

    public func remove(episodeKey: String) {
        Self.lock.withLock { try? FileManager.default.removeItem(at: url(episodeKey)) }
    }

    /// Removes the kept transcript only while it is still `sent`: one saved since by a newer attempt for the
    /// same episode stays for that attempt's retry. A file that can't be read counts as not `sent`.
    public func remove(episodeKey: String, ifHolding sent: TranscriptTimeline) {
        Self.lock.withLock {
            guard read(episodeKey) == sent else { return }
            try? FileManager.default.removeItem(at: url(episodeKey))
        }
    }

    /// Opted out: nothing waits to be sent.
    public func removeAll() {
        Self.lock.withLock { try? FileManager.default.removeItem(at: folder) }
    }

    private func url(_ episodeKey: String) -> URL {
        folder.appending(path: "\(episodeKey).json")
    }

    private func read(_ episodeKey: String) -> TranscriptTimeline? {
        guard let data = try? Data(contentsOf: url(episodeKey)) else { return nil }
        return try? JSONDecoder().decode(TranscriptTimeline.self, from: data)
    }
}
