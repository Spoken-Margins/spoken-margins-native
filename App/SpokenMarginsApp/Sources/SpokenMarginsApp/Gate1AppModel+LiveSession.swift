import Foundation
import SessionKit

/// The live session's call site on the model (#1989, #2481). A finished session becomes an ordinary Library
/// item, so storage doesn't change:
/// - with a transcript and a recording: the recording, imported like an audiobook from Files, with the
///   transcript attached as its text;
/// - with a transcript only: a text item holding the transcript;
/// - with neither: a text item holding the session's notes.
/// Margins are written by `LiveSessionMarginPlacer`. The session's evidence (`LiveSessionRecord`) is kept as a
/// JSON file in Application Support for the Markdown export.
extension Gate1AppModel {
    static var liveSessionDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    func saveLiveSession(
        _ session: LiveSession, transcript: ImportedTranscript?, placed: [LiveSessionAlignment.Placed], recordingURL: URL?
    ) async throws {
        let store = try requireStore()
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? transcript?.title ?? "\(session.kind.label) session"
            : session.title
        let itemId: String
        var finalPlaced = placed
        var linked: [(liveId: String, saved: Interjection)] = []
        if let recordingURL {
            let importer = try requireLocalSourceImporter()
            let item = try await importer.importAudiobook(from: recordingURL)
            itemId = item.id
            if let transcript {
                attachSourceTranscriptTimeline(Self.timeline(for: transcript), itemId: itemId)
            }
            linked = try LiveSessionMarginPlacer.placeLinked(finalPlaced, itemId: itemId, repository: store)
        } else {
            let built = transcript.map { LiveSessionText.transcript($0, placed: placed) } ?? LiveSessionText.notes(session)
            finalPlaced = built.placed
            itemId = "item-live-\(UUID().uuidString.lowercased())"
            let item = Item(
                id: itemId,
                title: title,
                mediaType: "text",
                text: built.text,
                externalReference: "live-session",
                status: "needs_listening_map",
                externalReferenceType: "manual",
                createdAt: Date()
            )
            try store.seed(item: item)
            if engine == nil { installEngine(try makeEngine(store: store)) }
            linked = try LiveSessionMarginPlacer.placeLinked(finalPlaced, itemId: itemId, repository: store)
        }
        if let directory = Self.liveSessionDirectory {
            var named = session
            named.title = title
            try? LiveSessionRecord(
                itemId: itemId, session: named, transcript: transcript, placed: finalPlaced,
                savedMarginIds: Dictionary(linked.map { ($0.liveId, $0.saved.id) }, uniquingKeysWith: { first, _ in first })
            ).save(in: directory)
        }
        // The session stays in the session store as saved, so a late copy of one of its Margins is still known (#2487).
        await LiveSessionFileWorker.shared.markSaved(sessionId: session.id, itemId: itemId)
        // Nothing below reads the rows back, so the Library and the item are read off the main thread (#2505).
        try await reloadLibraryRowsOffMain(store: store)
        refreshMarginRowsInBackground(forItem: itemId)
        selectedItem = try await loadItemDetailOffMain(id: itemId, store: store)
        activeItemId = itemId
        screen = .item
        reportConfirmation("Saved \(title) with \(placed.count) Margin\(placed.count == 1 ? "" : "s").")
    }

    /// Removes a purged item's session record, which holds the meeting's transcript.
    func removeLiveSessionRecord(itemId: String) {
        guard let directory = Self.liveSessionDirectory else { return }
        // The record's folder walk and unlink go off the main actor (#2510).
        Task.detached(priority: .utility) { LiveSessionRecord.remove(itemId: itemId, from: directory) }
    }

    private static func timeline(for transcript: ImportedTranscript) -> TranscriptTimeline {
        let segments = transcript.cues.enumerated().map { index, cue in
            MediaTimelineSegment(
                id: "cue-\(index + 1)",
                startMs: cue.startMs,
                endMs: max(cue.endMs ?? cue.startMs + 1_000, cue.startMs + 1),
                text: cue.speaker.map { "\($0): \(cue.text)" } ?? cue.text
            )
        }
        return TranscriptTimeline(segments: segments, chapters: [], durationMs: transcript.durationMs)
    }
}
