import Foundation
import SessionKit
import SessionKitPersistence

/// Builds the Markdown notes for "Save Margins to Notes Folder" away from the main actor (#161).
///
/// Each note re-reads its item, transcript and Margins from SQLite. With ~200 sessions and ~465 notes that took
/// about 1.4 s, and it ran on the main actor every 15 s, freezing the UI. The store is thread-safe, and the export
/// engine here is private to the background task, so nothing is shared with the playback engine.
enum AutomaticMarginNoteGatherer {
    struct Result: Sendable {
        var notes: [AutomaticMarginWriter.Note]
        var sessionCount: Int
        var elapsedMs: Int
    }

    static func gather(store: SQLiteSessionStore) async throws -> Result {
        try await Task.detached(priority: .utility) {
            let started = ProcessInfo.processInfo.systemUptime
            let engine = SessionEngine(
                profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
                repository: store
            )
            let sessions = try store.loadSessions()
            var notes: [AutomaticMarginWriter.Note] = []
            for session in sessions {
                try Task.checkCancellation()
                guard let item = try? store.loadItem(id: session.itemId), item.deletedAt == nil else { continue }
                for margin in try store.loadInterjections(sessionId: session.id) where margin.status == "active" {
                    // Every spoken Margin gets a note, even before or without a transcript (#171).
                    guard SessionExportMarkdownRenderer.writesMarginNote(
                        captureKind: margin.captureKind, text: margin.cleanedTranscript ?? margin.transcript
                    ) else { continue }
                    let export = try engine.buildExport(options: ExportOptions(
                        sessionId: session.id,
                        includeFullText: false, includeReference: true, includeListeningMap: false,
                        includeInterjections: true, includeTurns: false,
                        scope: "selected_interjections", interjectionIds: [margin.id]
                    ))
                    let markdown = SessionExportMarkdownRenderer.renderMargin(export, createdAt: margin.recordedAt(in: session))
                    guard !markdown.isEmpty else { continue }
                    notes.append(.init(id: session.id + ":" + margin.id, markdown: markdown))
                }
            }
            return Result(
                notes: notes,
                sessionCount: sessions.count,
                elapsedMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            )
        }.value
    }
}
