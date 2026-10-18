import Foundation

/// A written Margin the listener has started typing and not saved yet (#1970). The engine keeps its capture only in
/// memory, and the text lives in the screen; this is the copy that survives a call, a memory kill or a swipe-away.
public struct WrittenMarginDraftRecord: Codable, Equatable, Sendable {
    /// The capture id, which also names the file.
    public var id: String
    public var sessionId: String
    public var itemId: String
    public var targetType: InterjectionTargetType
    public var targetId: String
    public var anchor: Anchor
    public var roughPercent: Int
    public var replyTo: MarginReplyLink?
    public var text: String
    public var updatedAt: Date

    public init(capture: WrittenInterjectionCapture, text: String, updatedAt: Date) {
        id = capture.id
        sessionId = capture.sessionId
        itemId = capture.itemId
        targetType = capture.targetType
        targetId = capture.targetId
        anchor = capture.anchor
        roughPercent = capture.roughPercent
        replyTo = capture.replyTo
        self.text = text
        self.updatedAt = updatedAt
    }

    /// The capture to hand the engine on a relaunch. The source is paused by then, so saving or cancelling the
    /// restored Margin never starts it.
    public var capture: WrittenInterjectionCapture {
        WrittenInterjectionCapture(
            id: id, sessionId: sessionId, itemId: itemId, targetType: targetType, targetId: targetId,
            anchor: anchor, roughPercent: roughPercent, wasPlaying: false, replyTo: replyTo
        )
    }
}

/// One small JSON file per unsaved written Margin, in a folder of its own. It is not part of the database, so the
/// previous build still opens the database unchanged and a write here never touches the owner's Library. Every
/// write is atomic: a kill leaves the old file or the new one.
public final class WrittenMarginDraftJournal: @unchecked Sendable {
    public struct Loaded: Equatable, Sendable {
        /// Newest first.
        public var drafts: [WrittenMarginDraftRecord]
        /// Files that did not decode. They are left where they are and ignored.
        public var unreadableFileNames: [String]
    }

    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public static func standardDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "SpokenMargins/written-margin-drafts", directoryHint: .isDirectory)
    }

    /// Keeps the text. A draft with nothing in it is not worth keeping, so it removes any earlier file instead.
    public func write(_ record: WrittenMarginDraftRecord) throws {
        guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try remove(id: record.id)
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: fileURL(for: record.id), options: .atomic)
    }

    /// The order a launch tries drafts in: the one for the session that was just restored first, so a listener who
    /// is already there is not moved, then the newest. A draft is never skipped for being old or for sitting on a
    /// finished source (#1970 audit): the caller opens whichever session the winner belongs to.
    public static func restoreOrder(_ drafts: [WrittenMarginDraftRecord], restoredSessionId: String?) -> [WrittenMarginDraftRecord] {
        drafts.sorted {
            let lhsMatches = $0.sessionId == restoredSessionId, rhsMatches = $1.sessionId == restoredSessionId
            return lhsMatches != rhsMatches ? lhsMatches : $0.updatedAt > $1.updatedAt
        }
    }

    public func remove(id: String) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Every readable draft on disk. A missing folder is an empty journal.
    public func load() throws -> Loaded {
        guard fileManager.fileExists(atPath: directory.path) else { return Loaded(drafts: [], unreadableFileNames: []) }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        var drafts: [WrittenMarginDraftRecord] = []
        var unreadable: [String] = []
        for name in names {
            if let data = try? Data(contentsOf: directory.appending(path: name)),
               let record = try? Self.decoder.decode(WrittenMarginDraftRecord.self, from: data) {
                drafts.append(record)
            } else {
                unreadable.append(name)
            }
        }
        return Loaded(drafts: drafts.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }, unreadableFileNames: unreadable)
    }

    private func fileURL(for id: String) -> URL {
        // Ids are UUIDs the engine makes; keep a stray separator from leaving the folder.
        directory.appending(path: "\(id.replacingOccurrences(of: "/", with: "_")).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
