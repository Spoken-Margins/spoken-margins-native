import Foundation

/// Margins on a spoken note (#3664, part of #3658).
///
/// A note plays as an item with audio of its own (#3662), so a Margin added while it plays is anchored by the shared
/// engine like any Margin on audio: to the transcript segment at the playing time. A note's segments are its sentences,
/// and a sentence's segment id is its take's id and its place in the take. That id, not the time, is what names the
/// place: the joined audio is made again whenever a take is added, and a later record-over (#3109) will change what
/// sits where, but a sentence keeps its id. So a Margin finds its sentence from the id, and the time to play from is
/// read from the note's current timeline at the moment it is wanted.
public enum SpokenNoteMargins {
    /// The segment id of a note's sentence on the joined audio's timeline. The one place the id is made.
    public static func segmentId(takeId: String, sentenceIndex: Int) -> String {
        "\(segmentIdPrefix)\(takeId)-\(sentenceIndex)"
    }

    static let segmentIdPrefix = "note-"

    /// The anchor names a note's sentence by id.
    public static func isSentenceAnchored(_ anchor: Anchor) -> Bool {
        anchor.transcriptSegmentId?.hasPrefix(segmentIdPrefix) == true
    }

    /// The sentence a Margin's anchor names on `timeline`, or nil when it names none.
    ///
    /// The segment id is read first. An anchor with no id, or one whose sentence is no longer in the note (its take
    /// was removed, or its words changed), falls back to the media time it was recorded at, so a Margin is never lost
    /// from the screen.
    public static func sentence(of anchor: Anchor, on timeline: SpokenNoteWholeTimeline) -> SpokenNote.SentenceRef? {
        if let id = anchor.transcriptSegmentId, let entry = timeline.entries.first(where: { $0.segmentId == id }) {
            return entry.ref
        }
        guard let timeMs = anchor.mediaTimeMs else { return nil }
        return timeline.ref(atMs: timeMs)
    }

    /// The listener's active Margins on a note, grouped by the sentence they sit on, as the ids of the Margins in the
    /// order they were made. A Margin on anything but the note itself (a summary turn, a reply) is not on a sentence.
    public static func marginIdsBySentence(
        _ margins: [Interjection], itemId: String, on timeline: SpokenNoteWholeTimeline
    ) -> [SpokenNote.SentenceRef: [String]] {
        var grouped: [SpokenNote.SentenceRef: [String]] = [:]
        for margin in margins.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) })
        where margin.itemId == itemId && margin.targetType == .item && margin.status == "active" {
            guard let ref = sentence(of: margin.anchor, on: timeline) else { continue }
            grouped[ref, default: []].append(margin.id)
        }
        return grouped
    }

    /// Where on the joined audio a Margin's sentence starts now, read from the note's stored timeline by the segment
    /// id. Nil for an anchor that names no sentence of this timeline, so the caller keeps the time it was recorded at.
    public static func mediaTimeMs(of anchor: Anchor, in timeline: TranscriptTimeline?) -> Int? {
        guard let id = anchor.transcriptSegmentId, id.hasPrefix(segmentIdPrefix),
              let segment = timeline?.segments.first(where: { $0.id == id }) else { return nil }
        return segment.startMs
    }
}
