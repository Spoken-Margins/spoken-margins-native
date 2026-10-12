/// A passive summary of transcript work for the item and session named by the Now screen.
/// Persisted pending state does not establish that a transcription worker is running.
public struct PlaybackMarginTranscriptionStatus: Equatable, Sendable {
    public let pendingCount: Int
    public let attentionCount: Int

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
            return
        }
        var pending = 0
        var attention = 0
        for note in interjections {
            guard note.itemId == playingItemId, note.sessionId == sessionId,
                  note.status == "active", note.captureKind != .written else { continue }
            // Existing words are still available during a retranscription. This tag describes
            // unfinished transcripts, not every running attempt or an unknown future state.
            guard note.transcriptionStatus == "pending" || note.transcriptionStatus == "failed" else { continue }
            if isRetrying(note) {
                pending += 1
            } else if note.transcriptionStatus == "pending", note.audioPath != nil, note.audioStatus != "missing" {
                pending += 1
            } else {
                attention += 1
            }
        }
        pendingCount = pending
        attentionCount = attention
    }

    public var text: String? {
        var parts: [String] = []
        if pendingCount > 0 {
            parts.append("\(pendingCount) transcript\(pendingCount == 1 ? "" : "s") pending")
        }
        if attentionCount > 0 {
            parts.append(pendingCount > 0
                ? "\(attentionCount) need\(attentionCount == 1 ? "s" : "") attention"
                : "\(attentionCount) Margin\(attentionCount == 1 ? " needs" : "s need") attention")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public var accessibilityLabel: String? {
        var parts: [String] = []
        if pendingCount > 0 {
            parts.append("\(pendingCount) Margin transcript\(pendingCount == 1 ? "" : "s") pending")
        }
        if attentionCount > 0 {
            parts.append("\(attentionCount) Margin\(attentionCount == 1 ? " needs" : "s need") attention")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}
