import Foundation

extension PreparedTextAudio {
    /// This audio with its text and every character offset expressed against `itemText` alone, or nil
    /// when `itemText` is missing, empty, or not the end of the prepared text.
    ///
    /// The on-device voice can speak an overview before the item's own words, so the prepared text is the
    /// overview plus `itemText`. A Margin or a highlight must land on the listener's text, so the
    /// overview's characters are cut off the front: segments inside the overview collapse to 0..<0, a
    /// chapter whose segment ends at 0 is dropped, and the remaining chapters are titled with the first
    /// seven words of their segment. With no overview the audio is returned as it is.
    public func canonicalized(toItemText itemText: String?) -> PreparedTextAudio? {
        guard let itemText, !itemText.isEmpty,
              normalizedText.hasSuffix(itemText) else {
            return nil
        }
        let prefixLength = normalizedText.count - itemText.count
        guard prefixLength > 0 else { return self }
        let itemCharacters = Array(itemText)
        let canonicalSegments = timeline.segments.map { segment -> MediaTimelineSegment in
            let originalStart = segment.startChar ?? 0
            let originalEnd = segment.endChar ?? originalStart
            let start = max(0, min(itemCharacters.count, originalStart - prefixLength))
            let end = max(start, min(itemCharacters.count, originalEnd - prefixLength))
            let canonicalText = end > start
                ? String(itemCharacters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                : segment.text
            return MediaTimelineSegment(
                id: segment.id,
                startMs: segment.startMs,
                endMs: segment.endMs,
                startChar: start,
                endChar: end,
                text: canonicalText
            )
        }
        let segmentByID = canonicalSegments.reduce(into: [String: MediaTimelineSegment]()) {
            $0[$1.id] = $1
        }
        let canonicalChapters = timeline.chapters.compactMap { chapter -> MediaTimelineChapter? in
            guard let segment = segmentByID[chapter.transcriptSegmentId],
                  (segment.endChar ?? 0) > 0 else { return nil }
            let titleWords = segment.text.split(separator: " ").prefix(7).joined(separator: " ")
            return MediaTimelineChapter(
                id: chapter.id,
                title: titleWords.isEmpty ? chapter.title : titleWords,
                description: chapter.description,
                startMs: chapter.startMs,
                transcriptSegmentId: chapter.transcriptSegmentId
            )
        }
        return PreparedTextAudio(
            normalizedText: itemText,
            media: media,
            timeline: TranscriptTimeline(
                segments: canonicalSegments,
                chapters: canonicalChapters,
                durationMs: timeline.durationMs
            ),
            createdAt: createdAt
        )
    }
}
