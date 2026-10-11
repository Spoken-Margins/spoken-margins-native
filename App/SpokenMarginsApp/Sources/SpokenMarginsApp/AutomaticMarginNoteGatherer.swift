import Foundation
import SessionKit
import SessionKitPersistence

/// Builds the Markdown notes for "Save Margins to Notes Folder" away from the main actor (#161).
///
/// Each note re-reads its item, transcript and Margins from SQLite. With ~200 sessions and ~465 notes that took
/// about 1.4 s, and it ran on the main actor every 15 s, freezing the UI. The store is thread-safe, and the export
/// engine is private to the background task, so nothing is shared with the playback engine. `MarginNoteComposer`
/// does the reading; `sessionIds` limits a pass to the sessions that changed (#1192).
enum AutomaticMarginNoteGatherer {
    struct Result: Sendable {
        var notes: [AutomaticMarginWriter.Note]
        var sessionCount: Int
        var elapsedMs: Int
    }

    static func gather(store: SQLiteSessionStore, sessionIds: Set<String>? = nil) async throws -> Result {
        try await Task.detached(priority: .utility) {
            let started = ProcessInfo.processInfo.systemUptime
            let composed = try MarginNoteComposer.compose(store: store, sessionIds: sessionIds)
            return Result(
                notes: composed.notes.map { .init(id: $0.id, markdown: $0.markdown, fileName: $0.fileName) },
                sessionCount: composed.sessionCount,
                elapsedMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            )
        }.value
    }
}
