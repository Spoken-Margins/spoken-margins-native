import Foundation
import SessionKit

/// Builds the Markdown notes for "Save Margins to Notes Folder" (#161, #171, #1192).
///
/// Each note re-reads its item, transcript and Margins from SQLite, so a pass over a big Library is real work.
/// `MarginNotePassPlanner` says which sessions a pass needs; this builds the notes for them.
public enum MarginNoteComposer {
    public struct Note: Equatable, Sendable {
        public let id: String
        public let markdown: String
        public init(id: String, markdown: String) {
            self.id = id
            self.markdown = markdown
        }
    }

    public struct Composed: Sendable {
        public var notes: [Note]
        /// How many sessions were read.
        public var sessionCount: Int
    }

    /// `sessionIds` nil reads every session; a set reads only those (in a fixed order).
    public static func compose(store: SQLiteSessionStore, sessionIds: Set<String>? = nil) throws -> Composed {
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
            repository: store
        )
        let sessions: [Session]
        if let sessionIds {
            sessions = try sessionIds.sorted().compactMap { try store.loadSession(id: $0) }
        } else {
            sessions = try store.loadSessions()
        }
        var notes: [Note] = []
        for session in sessions {
            try Task.checkCancellation()
            guard let item = try? store.loadItem(id: session.itemId), item.deletedAt == nil else { continue }
            for margin in try store.loadInterjections(sessionId: session.id) where margin.status == "active" {
                // Every spoken Margin gets a note, even before or without a transcript (#171).
                guard SessionExportMarkdownRenderer.writesMarginNote(
                    captureKind: margin.captureKind, text: margin.cleanedTranscript ?? margin.transcript
                ) else { continue }
                let export = try engine.buildExport(options: .marginNote(sessionId: session.id, marginId: margin.id))
                let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.recordedAt(in: session))
                guard !markdown.isEmpty else { continue }
                notes.append(Note(id: session.id + ":" + margin.id, markdown: markdown))
            }
        }
        return Composed(notes: notes, sessionCount: sessions.count)
    }
}

/// Decides what one notes-folder pass must do (#1192). With 273 sessions and 611 notes a full pass took 2 to 16 s, and
/// one ran every minute whether or not anything had changed.
///
/// - The first pass, a pass for a different folder, and a pass 30 minutes after the last full one rebuild everything.
///   That repair pass also covers what the change check can't see: an item renamed or deleted, a clock set
///   backwards, or a note the listener deleted.
/// - Any other pass rebuilds only the sessions whose Margins or AI turns were saved since the last pass that finished,
///   plus those of an item whose source transcript has just arrived or changed size (a note's context comes from it),
///   and does nothing when there are none. A renamed item or a transcript replaced by one of the same size waits for
///   the next repair pass.
///
/// A pass that fails is not committed, so the next one covers the same ground again.
public struct MarginNotePassPlanner: Sendable {
    public enum Scope: Equatable, Sendable {
        case everything
        case sessions(Set<String>)
        case nothing
    }

    public struct Pass: Equatable, Sendable {
        public var scope: Scope
        fileprivate var targetKey: String
        fileprivate var settledThrough: String
        fileprivate var plannedAt: Date
        fileprivate var transcriptSizes: [String: Int]
    }

    public static let repairInterval: TimeInterval = 30 * 60

    private var targetKey: String?
    private var settledThrough: String?
    private var lastFullAt: Date?
    private var transcriptSizes: [String: Int] = [:]
    private var knownNoteIDs: Set<String> = []
    private var keptEditIDs: Set<String> = []

    /// The whole folder as of the last committed pass, for the status line: a pass that covers a few notes still
    /// reports every Margin saved.
    public var folderSummary: MarginNoteDelivery.Summary {
        MarginNoteDelivery.Summary(saved: knownNoteIDs.count - keptEditIDs.count, keptEdits: keptEditIDs.count)
    }

    public init() {}

    public func plan(store: SQLiteSessionStore, targetKey: String, now: Date = Date()) throws -> Pass {
        let transcripts = try store.sourceTranscriptSizes()
        if let settledThrough, let lastFullAt, self.targetKey == targetKey, now >= lastFullAt,
           now.timeIntervalSince(lastFullAt) < Self.repairInterval {
            let changes = try store.marginNoteChanges(after: settledThrough)
            var sessionIds = changes.sessionIds
            for (itemId, size) in transcripts where transcriptSizes[itemId] != size {
                sessionIds.formUnion(try store.loadSessions(itemId: itemId).map(\.id))
            }
            return Pass(
                scope: sessionIds.isEmpty ? .nothing : .sessions(sessionIds),
                targetKey: targetKey, settledThrough: changes.settledThrough, plannedAt: now, transcriptSizes: transcripts
            )
        }
        let changes = try store.marginNoteChanges(after: nil)
        return Pass(
            scope: .everything, targetKey: targetKey, settledThrough: changes.settledThrough, plannedAt: now,
            transcriptSizes: transcripts
        )
    }

    /// Call once the pass has been delivered: `noteIDs` are the notes it handed to the writer and `keptEditIDs`
    /// the ones the writer left because the listener edited them.
    public mutating func commit(_ pass: Pass, noteIDs: [String], keptEditIDs kept: Set<String>) {
        targetKey = pass.targetKey
        settledThrough = pass.settledThrough
        transcriptSizes = pass.transcriptSizes
        switch pass.scope {
        case .everything:
            lastFullAt = pass.plannedAt
            knownNoteIDs = Set(noteIDs)
            keptEditIDs = kept
        case .sessions(let sessionIds):
            // A session's notes are rebuilt as a set: one whose Margin was deleted drops out of the count.
            let prefixes = sessionIds.map { $0 + ":" }
            func isRebuilt(_ id: String) -> Bool { prefixes.contains { id.hasPrefix($0) } }
            knownNoteIDs = knownNoteIDs.filter { !isRebuilt($0) }.union(noteIDs)
            keptEditIDs = keptEditIDs.filter { !isRebuilt($0) }.union(kept)
        case .nothing:
            break
        }
    }
}
