import Foundation

/// A spoken Margin that has started recording and is not saved yet (#951). The engine keeps its source, place and
/// recording file only in memory; this is the copy that survives the app being killed before Save.
public struct RecordingDraft: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The recorder is writing the file.
        case recording
        /// The recorder closed the file and the Margin is not stored yet.
        case closed
        /// A launch found the file unreadable. The draft and the file are kept; nothing is recovered from them.
        case unrecoverable
    }

    public var id: String
    public var sessionId: String
    public var itemId: String
    public var targetType: InterjectionTargetType
    public var targetId: String
    public var createdAt: Date
    public var roughPercent: Int
    public var anchor: Anchor
    /// The recording as the Margin will name it, or nil when the recorder couldn't say where it writes.
    public var audioRef: String?
    public var state: State
    /// The Margin this recording answers, so a recovered reply is still threaded under its parent. Optional, so
    /// draft files written before replies existed still decode.
    public var replyTo: MarginReplyLink?

    public init(
        id: String = UUID().uuidString,
        sessionId: String,
        itemId: String,
        targetType: InterjectionTargetType,
        targetId: String,
        createdAt: Date,
        roughPercent: Int,
        anchor: Anchor,
        audioRef: String?,
        state: State = .recording,
        replyTo: MarginReplyLink? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.itemId = itemId
        self.targetType = targetType
        self.targetId = targetId
        self.createdAt = createdAt
        self.roughPercent = roughPercent
        self.anchor = anchor
        self.audioRef = audioRef
        self.state = state
        self.replyTo = replyTo
    }
}

/// One small JSON file per recording that has begun and is not yet a stored Margin, in a folder of its own beside
/// the recordings. It is not part of the database, so the previous build still opens the database unchanged, and a
/// write here never touches the owner's Library. Every write is atomic: a kill leaves the old file or the new one.
public final class RecordingDraftJournal: @unchecked Sendable {
    public struct Loaded: Equatable, Sendable {
        public var drafts: [RecordingDraft]
        /// Files in the folder that did not decode. They are left where they are.
        public var unreadableFileNames: [String]
    }

    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Where the app keeps drafts: beside `interjections`, under the app's support folder.
    public static func standardDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "SpokenMargins/recording-drafts", directoryHint: .isDirectory)
    }

    public func write(_ draft: RecordingDraft) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(draft).write(to: fileURL(for: draft.id), options: .atomic)
    }

    public func remove(id: String) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Every draft on disk, oldest first. A missing folder is an empty journal.
    public func load() throws -> Loaded {
        guard fileManager.fileExists(atPath: directory.path) else { return Loaded(drafts: [], unreadableFileNames: []) }
        let names = try fileManager.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        var drafts: [RecordingDraft] = []
        var unreadable: [String] = []
        for name in names {
            if let data = try? Data(contentsOf: directory.appending(path: name)),
               let draft = try? Self.decoder.decode(RecordingDraft.self, from: data) {
                drafts.append(draft)
            } else {
                unreadable.append(name)
            }
        }
        return Loaded(drafts: drafts.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }, unreadableFileNames: unreadable)
    }

    private func fileURL(for id: String) -> URL {
        // Ids are UUIDs the engine makes; keep a stray separator from leaving the folder.
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(safe).json")
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

/// What one launch did with one draft.
public struct RecordingDraftReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The file decoded; one Margin was stored for it and the draft is gone.
        case recovered(interjectionId: String)
        /// A Margin already names this recording (the kill came after the insert); the draft is gone.
        case alreadySaved
        /// The recorder never said where it writes; nothing could have been kept.
        case noRecording
        /// The file is gone (a Cancel, or iOS cleared it); the draft is gone.
        case fileMissing
        /// The session or source it belonged to is gone; the draft and file are kept.
        case sourceMissing
        /// The file does not decode. It and the draft are kept. `firstTime` is true on the launch that found out.
        case unreadable(firstTime: Bool)
    }

    public var draftId: String
    public var outcome: Outcome
}

/// Settles the drafts a launch finds. It runs once, before any recording can start, so a draft it sees is never
/// one a live recorder is writing. It never deletes a recording and never plays one, and a draft's place is the
/// one saved when recording began: nothing is guessed.
public struct RecordingDraftReconciler {
    private let journal: RecordingDraftJournal
    private let repository: SessionRepository
    private let applicationSupport: URL
    private let fileManager: FileManager
    private let isDecodable: (URL) -> Bool
    private let onRecovered: (_ sessionId: String, _ interjectionId: String) -> Void

    /// - Parameters:
    ///   - applicationSupport: the folder recording paths are relative to.
    ///   - isDecodable: true when the file opens and holds audio. The audio module supplies the real check.
    ///   - onRecovered: called right after a recovered Margin is stored, before its note is removed, so a later draft
    ///     failing or a kill cannot lose what the caller keeps about it.
    public init(
        journal: RecordingDraftJournal,
        repository: SessionRepository,
        applicationSupport: URL,
        fileManager: FileManager = .default,
        isDecodable: @escaping (URL) -> Bool,
        onRecovered: @escaping (_ sessionId: String, _ interjectionId: String) -> Void = { _, _ in }
    ) {
        self.journal = journal
        self.repository = repository
        self.applicationSupport = applicationSupport
        self.fileManager = fileManager
        self.isDecodable = isDecodable
        self.onRecovered = onRecovered
    }

    /// - Parameter savedAudioPaths: every recording any stored Margin names, quarantined ones included, so a
    ///   Margin the listener deleted is not brought back. It is read only when there are notes to settle, so a
    ///   launch with none never scans the Library, and if it throws nothing is settled (a note is never guessed at).
    @discardableResult
    public func reconcile(savedAudioPaths: () throws -> [String]) throws -> [RecordingDraftReport] {
        let drafts = try journal.load().drafts
        guard !drafts.isEmpty else { return [] }
        var saved = Set(try savedAudioPaths())
        var reports: [RecordingDraftReport] = []
        for draft in drafts {
            let outcome = try settle(draft, savedAudioPaths: saved)
            if case .recovered = outcome, let ref = draft.audioRef { saved.insert(ref) }
            reports.append(RecordingDraftReport(draftId: draft.id, outcome: outcome))
        }
        return reports
    }

    private func settle(_ draft: RecordingDraft, savedAudioPaths: Set<String>) throws -> RecordingDraftReport.Outcome {
        guard let ref = draft.audioRef else {
            try journal.remove(id: draft.id)
            return .noRecording
        }
        if savedAudioPaths.contains(ref) {
            try journal.remove(id: draft.id)
            return .alreadySaved
        }
        let url = fileURL(for: ref)
        guard fileManager.fileExists(atPath: url.path) else {
            try journal.remove(id: draft.id)
            return .fileMissing
        }
        guard (try? repository.loadSession(id: draft.sessionId)) != nil,
              (try? repository.loadItem(id: draft.itemId)) != nil else {
            return .sourceMissing
        }
        guard isDecodable(url) else {
            guard draft.state != .unrecoverable else { return .unreadable(firstTime: false) }
            var marked = draft
            marked.state = .unrecoverable
            try journal.write(marked)
            return .unreadable(firstTime: true)
        }
        let existing = try repository.loadInterjections(sessionId: draft.sessionId).count
        let margin = Interjection(
            id: Interjection.makeId(number: existing + 1, targetType: draft.targetType),
            itemId: draft.itemId,
            sessionId: draft.sessionId,
            targetType: draft.targetType,
            targetId: draft.targetId,
            createdAt: draft.createdAt,
            roughPercent: draft.roughPercent,
            anchor: draft.anchor,
            audioPath: ref,
            audioStatus: "saved",
            // The launch that follows settles an unstarted transcription as retryable, so the listener sees Retry.
            transcriptionStatus: "pending",
            transcript: nil,
            cleanedTranscript: nil,
            displayText: nil,
            status: "active",
            anchorContextStatus: Interjection.contextStatus(for: draft.anchor),
            replyTo: draft.replyTo
        )
        try repository.saveInterjection(margin)
        onRecovered(margin.sessionId, margin.id)
        try journal.remove(id: draft.id)
        return .recovered(interjectionId: margin.id)
    }

    private func fileURL(for ref: String) -> URL {
        let absolute = URL(fileURLWithPath: ref)
        if ref.hasPrefix("/"), fileManager.fileExists(atPath: absolute.path) { return absolute }
        if ref.hasPrefix("interjections/") { return applicationSupport.appending(path: "SpokenMargins").appending(path: ref) }
        return applicationSupport.appending(path: ref)
    }
}

extension Interjection {
    /// "ij-007" for the listener's own Margins, "ij-ai-007" for ones on an assistant turn.
    static func makeId(number: Int, targetType: InterjectionTargetType) -> String {
        (targetType == .assistantTurn ? "ij-ai-" : "ij-") + String(format: "%03d", number)
    }

    /// Whether the anchor already carries the text around it, or still waits for it.
    static func contextStatus(for anchor: Anchor) -> AnchorContextStatus {
        anchor.mediaTimeMs == nil || !anchor.anchorBefore.isEmpty || !anchor.anchorAfter.isEmpty ? .ready : .pending
    }
}
