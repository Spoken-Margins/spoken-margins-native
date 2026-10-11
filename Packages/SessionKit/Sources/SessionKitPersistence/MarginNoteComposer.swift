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
        /// The file name the note asks for, or nil for the writer's own `Margin-<digest>.md`. Only an item note (#587)
        /// has one.
        public let fileName: String?
        public init(id: String, markdown: String, fileName: String? = nil) {
            self.id = id
            self.markdown = markdown
            self.fileName = fileName
        }
    }

    public struct Composed: Sendable {
        public var notes: [Note]
        /// How many sessions were read.
        public var sessionCount: Int
    }

    /// `sessionIds` nil reads every session; a set reads only those (in a fixed order).
    ///
    /// `shape` is the listener's choice (#587). The default writes a note for each Margin, as always. With
    /// `.itemOnCompletion` no Margin gets a note of its own: each item that has a session in scope and has been
    /// marked complete gets one note holding all its Margins, across all its sessions, not only the ones in scope.
    /// `completedSince` limits that to items completed at or after it, so turning the mode on doesn't write a note
    /// for every item already finished.
    ///
    /// `content` is a destination's choice (#492): all Margins or only starred ones, with or without the passage around
    /// each, and the cleaned or the original transcript. It shapes a Margin note; an item note (#587) keeps its own form.
    public static func compose(
        store: SQLiteSessionStore, sessionIds: Set<String>? = nil,
        shape: MarginNotesShape = .eachMargin, completedSince: Date? = nil,
        content: MarginNoteContent = .standard
    ) throws -> Composed {
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
        switch shape {
        case .eachMargin:
            return Composed(notes: try marginNotes(sessions: sessions, content: content, store: store, engine: engine), sessionCount: sessions.count)
        case .itemOnCompletion:
            return Composed(
                notes: try itemNotes(sessions: sessions, shape: shape, completedSince: completedSince, store: store, engine: engine),
                sessionCount: sessions.count
            )
        }
    }

    /// The export an item note is built from: one whole session, with its Margins and the item's reference.
    static func itemNoteOptions(sessionId: String) -> ExportOptions {
        ExportOptions(
            sessionId: sessionId,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false
        )
    }

    private static func itemNotes(
        sessions: [Session], shape: MarginNotesShape, completedSince: Date?, store: SQLiteSessionStore, engine: SessionEngine
    ) throws -> [Note] {
        var itemIds: [String] = []
        var seen: Set<String> = []
        for session in sessions where seen.insert(session.itemId).inserted { itemIds.append(session.itemId) }
        var notes: [Note] = []
        for itemId in itemIds {
            try Task.checkCancellation()
            guard let item = try? store.loadItem(id: itemId), item.deletedAt == nil,
                  let completedAt = item.sourceCompletedAt, completedSince.map({ completedAt >= $0 }) ?? true
            else { continue }
            // Oldest first, as `ItemMarginNote` expects; the id breaks a tie so the order never changes between passes.
            let itemSessions = try store.loadSessions(itemId: itemId).sorted {
                ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id)
            }
            let exports = try itemSessions.map { try engine.buildExport(options: itemNoteOptions(sessionId: $0.id)) }
            if let note = ItemMarginNote.note(shape: shape, completedAt: completedAt, exports: exports) {
                notes.append(Note(id: note.id, markdown: note.markdown, fileName: note.fileName))
            }
        }
        return notes
    }

    private static func marginNotes(sessions: [Session], content: MarginNoteContent, store: SQLiteSessionStore, engine: SessionEngine) throws -> [Note] {
        var notes: [Note] = []
        for session in sessions {
            try Task.checkCancellation()
            guard let item = try? store.loadItem(id: session.itemId), item.deletedAt == nil else { continue }
            for margin in try store.loadInterjections(sessionId: session.id) where margin.status == "active" {
                if content.scope == .starred, margin.isStarredForSharing != true { continue }
                // Every spoken Margin gets a note, even before or without a transcript (#171).
                guard SessionExportMarkdownRenderer.writesMarginNote(
                    captureKind: margin.captureKind, text: margin.cleanedTranscript ?? margin.transcript
                ) else { continue }
                var export = try engine.buildExport(options: .marginNote(sessionId: session.id, marginId: margin.id))
                shape(&export, for: margin, content: content)
                let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.recordedAt(in: session))
                guard !markdown.isEmpty else { continue }
                notes.append(Note(id: session.id + ":" + margin.id, markdown: markdown))
            }
        }
        return notes
    }

    /// Applies a destination's choices to the export a Margin note is rendered from. The default changes nothing.
    /// A written Margin has only the words the listener typed, so "original" only differs for a spoken one, and it
    /// falls back to the cleaned text when the recognizer's own is missing.
    private static func shape(_ export: inout SessionExport, for margin: Interjection, content: MarginNoteContent) {
        guard export.interjections.count == 1 else { return }
        if !content.includesContext {
            export.interjections[0].anchorBefore = ""
            export.interjections[0].anchorAfter = ""
        }
        if content.text == .original, margin.captureKind != .written,
           let original = margin.transcript, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            export.interjections[0].transcript = original
        }
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
        /// The completions this pass covers (#587), forgotten once the pass is committed.
        fileprivate var completedItemIDs: Set<String> = []
    }

    public static let repairInterval: TimeInterval = 30 * 60

    private var targetKey: String?
    private var settledThrough: String?
    private var lastFullAt: Date?
    private var transcriptSizes: [String: Int] = [:]
    private var knownNoteIDs: Set<String> = []
    private var keptEditIDs: Set<String> = []
    /// Items marked complete (or marked unfinished and complete again) since the last committed pass (#587).
    private var completedItemIDs: Set<String> = []

    /// The whole folder as of the last committed pass, for the status line: a pass that covers a few notes still
    /// reports every Margin saved.
    public var folderSummary: MarginNoteDelivery.Summary {
        MarginNoteDelivery.Summary(saved: knownNoteIDs.count - keptEditIDs.count, keptEdits: keptEditIDs.count)
    }

    public init() {}

    /// An item was marked complete (#587). Completing writes no Margin row, so the change check below can't see it:
    /// the next pass rebuilds this item's sessions, which is what writes its note in "one note per item" mode.
    /// A completion that happens inside the app's own engine, such as finishing an item by listening, isn't reported
    /// here and waits for the next repair pass.
    public mutating func noteCompletion(ofItem itemId: String) {
        completedItemIDs.insert(itemId)
    }

    public func plan(store: SQLiteSessionStore, targetKey: String, now: Date = Date()) throws -> Pass {
        let transcripts = try store.sourceTranscriptSizes()
        if let settledThrough, let lastFullAt, self.targetKey == targetKey, now >= lastFullAt,
           now.timeIntervalSince(lastFullAt) < Self.repairInterval {
            let changes = try store.marginNoteChanges(after: settledThrough)
            var sessionIds = changes.sessionIds
            for (itemId, size) in transcripts where transcriptSizes[itemId] != size {
                sessionIds.formUnion(try store.loadSessions(itemId: itemId).map(\.id))
            }
            for itemId in completedItemIDs {
                sessionIds.formUnion(try store.loadSessions(itemId: itemId).map(\.id))
            }
            return Pass(
                scope: sessionIds.isEmpty ? .nothing : .sessions(sessionIds),
                targetKey: targetKey, settledThrough: changes.settledThrough, plannedAt: now, transcriptSizes: transcripts,
                completedItemIDs: completedItemIDs
            )
        }
        let changes = try store.marginNoteChanges(after: nil)
        return Pass(
            scope: .everything, targetKey: targetKey, settledThrough: changes.settledThrough, plannedAt: now,
            transcriptSizes: transcripts, completedItemIDs: completedItemIDs
        )
    }

    /// Call once the pass has been delivered: `noteIDs` are the notes it handed to the writer and `keptEditIDs`
    /// the ones the writer left because the listener edited them.
    public mutating func commit(_ pass: Pass, noteIDs: [String], keptEditIDs kept: Set<String>) {
        targetKey = pass.targetKey
        settledThrough = pass.settledThrough
        transcriptSizes = pass.transcriptSizes
        completedItemIDs.subtract(pass.completedItemIDs)
        switch pass.scope {
        case .everything:
            lastFullAt = pass.plannedAt
            knownNoteIDs = Set(noteIDs)
            keptEditIDs = kept
        case .sessions(let sessionIds):
            // A session's notes are rebuilt as a set: one whose Margin was deleted drops out of the count. An item
            // note (`item:<id>`) isn't tied to one session and its file stays in the folder, so it only joins the count.
            let prefixes = sessionIds.map { $0 + ":" }
            func isRebuilt(_ id: String) -> Bool { prefixes.contains { id.hasPrefix($0) } }
            knownNoteIDs = knownNoteIDs.filter { !isRebuilt($0) }.union(noteIDs)
            keptEditIDs = keptEditIDs.filter { !isRebuilt($0) }.union(kept)
        case .nothing:
            break
        }
    }
}
