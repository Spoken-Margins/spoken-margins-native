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
        if let recordingURL {
            let importer = try requireLocalSourceImporter()
            let item = try await importer.importAudiobook(from: recordingURL)
            itemId = item.id
            if let transcript {
                attachSourceTranscriptTimeline(Self.timeline(for: transcript), itemId: itemId)
            }
            try LiveSessionMarginPlacer.place(finalPlaced, itemId: itemId, repository: store)
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
            try LiveSessionMarginPlacer.place(finalPlaced, itemId: itemId, repository: store)
        }
        if let directory = Self.liveSessionDirectory {
            var named = session
            named.title = title
            try? LiveSessionRecord(itemId: itemId, session: named, transcript: transcript, placed: finalPlaced).save(in: directory)
        }
        libraryItems = try loadLibraryRows(store: store)
        refreshMarginRows()
        selectedItem = try loadItemDetail(id: itemId, store: store)
        activeItemId = itemId
        screen = .item
        reportConfirmation("Saved \(title) with \(placed.count) Margin\(placed.count == 1 ? "" : "s").")
    }

    /// The live session's Markdown for the share sheet, when `itemId` came from one.
    func liveSessionMarkdownFileURL(itemId: String) -> URL? {
        guard let directory = Self.liveSessionDirectory,
              let record = LiveSessionRecord.load(itemId: itemId, from: directory) else { return nil }
        let folder = MarginMarkdownShare.shareDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = record.session.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let url = folder.appendingPathComponent((name.isEmpty ? "Live session" : name) + ".md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try LiveSessionMarkdown.render(record).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            reportFailure(error, context: "Live session export failed", itemId: itemId)
            return nil
        }
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
