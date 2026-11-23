import Foundation

/// The files of a note's version without ums (#4779). They all sit in the note's `clean/` folder, beside the takes,
/// which are never written. Every file here can be made again from the takes.
///
/// - `words-<takeId>.json`: the take's timed words (`SpokenNoteTimedWord`), from intake or the word pass.
/// - `cut-<takeId>.json`: the take's cut (`SpokenNoteCutFile`), reused while its words and rule are unchanged.
/// - `whole-note.m4a`: the version without ums.
/// - `whole-note.json`: how it was made (`SpokenNoteCleanLayout`).
public enum SpokenNoteCleanFiles {
    public static let folderName = "clean"
    public static let audioFileName = "whole-note.m4a"
    public static let layoutFileName = "whole-note.json"
    /// What an item's media URL ends with when the version without ums is attached. Two path components, so it can't be
    /// mistaken for the recording's `whole-note.m4a` one folder up.
    public static let mediaSuffix = "\(folderName)/\(audioFileName)"

    public static func folder(inNoteFolder noteFolder: URL) -> URL { noteFolder.appendingPathComponent(folderName, isDirectory: true) }
    public static func audioURL(inNoteFolder noteFolder: URL) -> URL { folder(inNoteFolder: noteFolder).appendingPathComponent(audioFileName) }
    public static func layoutURL(inNoteFolder noteFolder: URL) -> URL { folder(inNoteFolder: noteFolder).appendingPathComponent(layoutFileName) }
    public static func wordsURL(takeId: String, inNoteFolder noteFolder: URL) -> URL {
        folder(inNoteFolder: noteFolder).appendingPathComponent("words-\(takeId).json")
    }
    public static func cutURL(takeId: String, inNoteFolder noteFolder: URL) -> URL {
        folder(inNoteFolder: noteFolder).appendingPathComponent("cut-\(takeId).json")
    }

    /// Whether a media URL names a note's version without ums: its last two path components are `clean/whole-note.m4a`.
    public static func namesCleanAudio(_ mediaURL: String?) -> Bool {
        guard let mediaURL, let url = URL(string: mediaURL) ?? Optional(URL(fileURLWithPath: mediaURL)) else { return false }
        let components = url.pathComponents
        guard components.count >= 2 else { return false }
        return components[components.count - 2] == folderName && components[components.count - 1] == audioFileName
    }

    // MARK: Reading and writing

    /// Writes through a temporary file and a rename, so a reader never sees half a file.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        do {
            try encoder.encode(value).write(to: temporary)
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func readWords(takeId: String, inNoteFolder noteFolder: URL) -> [SpokenNoteTimedWord]? {
        read([SpokenNoteTimedWord].self, from: wordsURL(takeId: takeId, inNoteFolder: noteFolder))
    }

    public static func writeWords(_ words: [SpokenNoteTimedWord], takeId: String, inNoteFolder noteFolder: URL) throws {
        try write(words, to: wordsURL(takeId: takeId, inNoteFolder: noteFolder))
    }

    public static func readLayout(inNoteFolder noteFolder: URL) -> SpokenNoteCleanLayout? {
        guard let layout = read(SpokenNoteCleanLayout.self, from: layoutURL(inNoteFolder: noteFolder)),
              layout.version <= SpokenNoteCleanLayout.currentVersion else { return nil }
        return layout
    }

    /// A stable 64-bit FNV-1a hash, hex. Used to tell whether a take's words or cut changed; not for security.
    public static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    public static func fingerprint<T: Encodable>(of value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return fingerprint((try? encoder.encode(value)) ?? Data())
    }
}

/// A take's saved cut, with the words it was made from, so it is made again only when they or the rule change.
public struct SpokenNoteCutFile: Codable, Equatable, Sendable {
    public let wordsFingerprint: String
    public let cut: SpokenNoteTakeCut

    public init(wordsFingerprint: String, cut: SpokenNoteTakeCut) {
        self.wordsFingerprint = wordsFingerprint
        self.cut = cut
    }
}

/// Why a version shortens pauses only and keeps the ums.
public enum SpokenNotePausesOnlyReason: String, Codable, Equatable, Sendable {
    /// Speech Recognition is off for the app.
    case denied
    /// The words couldn't be timed: a transcription error, or the speech model isn't on the phone and there's no connection.
    case untimed
    /// The note isn't in English.
    case notEnglish
}

/// What making a note's version without ums came to.
public enum SpokenNoteCleanResult: Codable, Equatable, Sendable {
    public enum Failure: String, Codable, Equatable, Sendable {
        case noSpace
        case other
    }

    case made(savedMs: Int)
    /// Nothing to cut: no audio file is written, and the note plays as recorded.
    case nothingToRemove
    case pausesOnly(reason: SpokenNotePausesOnlyReason, savedMs: Int)
    case failed(Failure)
    /// The export was stopped by the system in the background. Not a failure: it starts again with the app in front.
    case interrupted

    /// A version with an audio file to attach.
    public var hasAudio: Bool {
        switch self {
        case .made, .pausesOnly: return true
        default: return false
        }
    }

    public var savedMs: Int {
        switch self {
        case .made(let saved), .pausesOnly(_, let saved): return saved
        default: return 0
        }
    }
}

/// `clean/whole-note.json`: how the version without ums was made, and where each kept stretch landed.
public struct SpokenNoteCleanLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    /// The takes it was made from, exactly as the recording's join asked for them.
    public let requested: [SpokenNoteWholeAudioLayout.Requested]
    public let ruleVersion: Int
    /// Take id to the fingerprint of the cut used for it.
    public let cutFingerprints: [String: String]
    public let placements: [SpokenNoteCleanPlacement]
    public let durationMs: Int
    public let result: SpokenNoteCleanResult

    public init(
        requested: [SpokenNoteWholeAudioLayout.Requested], ruleVersion: Int = SpokenNoteCleanPolicy.ruleVersion,
        cutFingerprints: [String: String], placements: [SpokenNoteCleanPlacement], durationMs: Int, result: SpokenNoteCleanResult
    ) {
        self.version = Self.currentVersion
        self.requested = requested
        self.ruleVersion = ruleVersion
        self.cutFingerprints = cutFingerprints
        self.placements = placements
        self.durationMs = max(0, durationMs)
        self.result = result
    }

    /// Whether this layout was made from exactly these takes and cuts under today's rule.
    public func matches(requested: [SpokenNoteWholeAudioLayout.Requested], cutFingerprints: [String: String]) -> Bool {
        self.requested == requested && ruleVersion == SpokenNoteCleanPolicy.ruleVersion && self.cutFingerprints == cutFingerprints
    }

    /// Whether this layout was made from these takes under today's rule, whatever the cuts (for attaching: the cuts are
    /// the pipeline's question).
    public func isCurrent(for requested: [SpokenNoteWholeAudioLayout.Requested]) -> Bool {
        self.requested == requested && ruleVersion == SpokenNoteCleanPolicy.ruleVersion
    }
}
