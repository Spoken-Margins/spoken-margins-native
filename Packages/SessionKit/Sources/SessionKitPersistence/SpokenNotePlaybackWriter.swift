import Foundation
import SessionKit

/// The database gives a spoken note's Library item its audio and transcript timeline (#3662), so the shared playback
/// engine plays the note like any item that has its own audio. Like `SpokenNoteItemWriting`, it is called off the main
/// thread, reads the stored row and changes only what playback needs, so a row the listener trashed or renamed is
/// neither brought back nor overwritten.
extension SQLiteSessionStore: SpokenNotePlaybackWriting {
    public func attachPlayback(itemId: String, audioURL: URL, durationMs: Int, timeline: MediaTimeline, text: String) throws -> Bool {
        // Read, compare and write under one hold of the connection lock, so a trash that lands in between can't be
        // overwritten by the row read before it (the lock is recursive; `saveItem` takes it again).
        try withConnectionLock {
            guard var row = try? loadItem(id: itemId), row.deletedAt == nil,
                  SpokenNoteItem.isSpokenNote(mediaType: row.mediaType) else { return false }
            let transcriptId = row.transcriptId ?? "transcript-\(itemId)"
            // The coordinator may have written newer words since the timeline was made (a transcript that arrived during the
            // join). A take is only ever added at the end, so stored text that continues the incoming text is the newer one
            // and is kept; the timeline's offsets still point at the same words in it.
            var rowText = text
            if let stored = row.text, stored.count > text.count, stored.hasPrefix(text) { rowText = stored }
            let media = ItemMedia(
                sourceType: .nativeMediaFile, url: audioURL.absoluteString, durationMs: durationMs,
                nativeMediaId: "spoken-note-audio-\(itemId)"
            )
            // Before #3662 a note could be started as text read aloud, which left a session that would resume in a synthetic
            // voice. Its audio is the listener's own now, so such a session is set aside (kept, not deleted) and Play starts afresh.
            for var session in try loadSessions(itemId: itemId)
            where session.currentTargetType == .itemTextTTS && session.phase != .abandoned && session.status == "in_progress" {
                session.phase = .abandoned
                try saveSession(session)
            }
            let stored = try loadTranscriptTimeline(itemId: itemId)
            // Playing the same note again, with nothing added, writes nothing.
            if row.media == media, row.text == rowText, row.transcriptId == transcriptId, stored?.timeline == timeline { return true }
            if stored?.timeline != timeline {
                try saveTranscriptTimeline(SourceTranscriptTimeline(id: transcriptId, itemId: itemId, createdAt: Date(), timeline: timeline))
            }
            row.media = media
            row.text = rowText
            row.transcriptId = transcriptId
            try saveItem(row)
            return true
        }
    }
}
