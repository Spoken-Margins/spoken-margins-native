/// A passive summary of transcript work for the item and session named by the Now screen.
/// Persisted pending state does not establish that a transcription worker is running.
public struct PlaybackMarginTranscriptionStatus: Equatable, Sendable {
    public let pendingCount: Int
    /// Failed transcripts and missing recordings together: everything that is not simply waiting. `failedCount` and
    /// `missingCount` tell the two apart (#3790).
    public let attentionCount: Int
    /// A transcript that failed while its recording is still there.
    public let failedCount: Int
    /// A recording that is not there (never saved, or marked missing), whether its transcript was pending or failed.
    public let missingCount: Int

    public init(
        selectedItemId: String,
        playingItemId: String?,
        sessionId: String?,
        interjections: [Interjection],
        isRetrying: (Interjection) -> Bool = { _ in false }
    ) {
        guard selectedItemId == playingItemId, let sessionId else {
            pendingCount = 0
            attentionCount = 0
            failedCount = 0
            missingCount = 0
            return
        }
        var pending = 0
        var failed = 0
        var missing = 0
        for note in interjections {
            guard note.itemId == playingItemId, note.sessionId == sessionId,
                  note.status == "active", note.captureKind != .written else { continue }
            // Existing words are still available during a retranscription. This tag describes
            // unfinished transcripts, not every running attempt or an unknown future state.
            guard note.transcriptionStatus == "pending" || note.transcriptionStatus == "failed" else { continue }
            if isRetrying(note) {
                pending += 1
            } else if note.audioPath == nil || note.audioStatus == "missing" {
                missing += 1
            } else if note.transcriptionStatus == "pending" {
                pending += 1
            } else {
                failed += 1
            }
        }
        pendingCount = pending
        failedCount = failed
        missingCount = missing
        attentionCount = failed + missing
    }

    /// The status line's words, one part per kind present, in this order, joined with " · " (#3790): "1 transcript
    /// pending", "2 transcripts failed", "1 recording missing". Nil when there is nothing to say.
    public var words: String? {
        var parts: [String] = []
        if pendingCount > 0 { parts.append("\(pendingCount) transcript\(pendingCount == 1 ? "" : "s") pending") }
        if failedCount > 0 { parts.append("\(failedCount) transcript\(failedCount == 1 ? "" : "s") failed") }
        if missingCount > 0 { parts.append("\(missingCount) recording\(missingCount == 1 ? "" : "s") missing") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver says for `words`: a sentence per kind, joined with a space. A failed transcript says what to do.
    public var voiceOverWords: String? {
        var parts: [String] = []
        if pendingCount > 0 {
            parts.append(pendingCount == 1
                ? "1 Margin transcript pending."
                : "\(pendingCount) Margin transcripts pending.")
        }
        if failedCount > 0 {
            parts.append(failedCount == 1
                ? "1 Margin transcript failed. Open the Margin to try again."
                : "\(failedCount) Margin transcripts failed. Open the Margins to try again.")
        }
        if missingCount > 0 {
            parts.append(missingCount == 1
                ? "1 Margin recording is missing."
                : "\(missingCount) Margin recordings are missing.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
