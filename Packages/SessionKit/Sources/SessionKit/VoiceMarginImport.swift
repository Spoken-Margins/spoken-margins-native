import Foundation

/// Checks and keeps an audio file handed to the Add Voice Margin Shortcuts action (#4924), so it becomes a spoken
/// Margin's voice. Nothing here decodes audio or uploads anything: the caller measures the file's length (`durationMs`),
/// and this refuses what can't be a Margin, then copies the file to where the app keeps its own recordings.
///
/// The copy is the app's own, named like no recording the app made, so a Shortcut that goes on to delete or change the
/// file it passed never reaches the Margin, and no listener recording is ever overwritten or removed by this type.
public enum VoiceMarginImport {
    /// The longest recording the action takes (the default taken on #4924). A longer one is refused, not cut.
    public static let maxDurationMs = 10 * 60 * 1_000

    /// Why a file can't become a Margin. Each case has one plain line for the listener (`line`).
    public enum Refusal: Error, Equatable, Sendable {
        /// The file is missing, empty or not audio the app can read, or has no sound length.
        case unreadable
        /// Longer than `maxDurationMs`.
        case tooLong
        /// The copy could not be made (the disk is full, say). Nothing was kept.
        case notKept

        public var line: String {
            switch self {
            case .unreadable: VoiceMarginImport.unreadableLine
            case .tooLong: VoiceMarginImport.tooLongLine
            case .notKept: VoiceMarginImport.notKeptLine
            }
        }
    }

    public static let unreadableLine = "That recording was empty or couldn't be read, so nothing was saved."
    public static let tooLongLine = "That recording is longer than 10 minutes, so nothing was saved. Record a shorter one."
    public static let notKeptLine = "Spoken Margins couldn't keep that recording, so nothing was saved. Try again."

    /// A recording the app now holds as its own.
    public struct Prepared: Equatable, Sendable {
        /// The path a Margin stores, relative to Application Support like a Margin the app recorded
        /// (`SpokenMargins/interjections/<name>`).
        public let audioPath: String
        public let durationMs: Int
    }

    /// The file extensions kept as they came. Any other name is stored as `.m4a`: the length was measured, so the file is
    /// audio the system can read, and the extension is only a name.
    static let keptExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aac", "aif", "aiff", "mp4"]

    /// Where a prepared recording is stored under `supportDirectory`.
    static let folder = "SpokenMargins/interjections"

    /// Refuses a file that can't be a Margin, else copies it into the app's recordings.
    ///
    /// - Parameters:
    ///   - source: the file the Shortcut passed; it is read, never changed or removed.
    ///   - supportDirectory: Application Support (or a test's stand-in).
    ///   - durationMs: the file's length in milliseconds, or nil when it can't be read as audio.
    ///   - makeId: the unique part of the stored name.
    public static func prepare(
        source: URL,
        supportDirectory: URL,
        durationMs: (URL) -> Int?,
        makeId: () -> String = { UUID().uuidString.lowercased() },
        fileManager: FileManager = .default
    ) throws -> Prepared {
        let size = (try? fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw Refusal.unreadable }
        guard let length = durationMs(source), length > 0 else { throw Refusal.unreadable }
        guard length <= maxDurationMs else { throw Refusal.tooLong }

        let ext = source.pathExtension.lowercased()
        let name = "shortcut-voice-\(makeId()).\(keptExtensions.contains(ext) ? ext : "m4a")"
        let directory = supportDirectory.appending(path: folder, directoryHint: .isDirectory)
        let destination = directory.appending(path: name)
        // A name already taken is never overwritten or removed: it is a recording some Margin may name.
        guard !fileManager.fileExists(atPath: destination.path) else { throw Refusal.notKept }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination) // a part-written copy of ours is nobody's recording
            throw Refusal.notKept
        }
        return Prepared(audioPath: "\(folder)/\(name)", durationMs: length)
    }

    /// Removes the copy `prepare` made when no Margin ended up naming it, so nothing is left that no Margin names. Only a
    /// file this type made is removed: its name has the `shortcut-voice-` prefix and it sits in the recordings folder.
    @discardableResult
    public static func discard(
        _ prepared: Prepared, supportDirectory: URL, fileManager: FileManager = .default
    ) -> Bool {
        let name = (prepared.audioPath as NSString).lastPathComponent
        guard prepared.audioPath == "\(folder)/\(name)", name.hasPrefix("shortcut-voice-") else { return false }
        let url = supportDirectory.appending(path: prepared.audioPath)
        return (try? fileManager.removeItem(at: url)) != nil
    }
}
