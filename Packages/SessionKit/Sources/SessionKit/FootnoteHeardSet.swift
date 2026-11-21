import Foundation

/// The notes a listener has heard read where they were cited, in this session only (#3777). It is never stored:
/// a new launch hears every note again, and the notes chapter at the end then reads each one that was not heard.
///
/// A note counts as heard only when its aside played to its end. A note skipped past, cut short with the paragraph
/// button, or never reached (a resume at 50%) stays unheard, so the notes chapter still reads it. The chime mode uses the
/// same set: a note the listener ignored the tone for is read at the end.
///
/// The set is keyed by item and label, because two articles in one session can both have a note `1`.
public struct FootnoteHeardSet: Equatable, Sendable {
    private var heard: Set<Key> = []

    private struct Key: Hashable, Sendable {
        let itemId: String
        let label: String
    }

    public init() {}

    /// Records that the chunk at `index` played to its end. `tags` is the plan's chunks' `footnote` tags in order. A
    /// note counts as heard only when the chunk is the LAST aside chunk of its label: the planner splits a note longer
    /// than its chunk budget into several aside chunks, and a listener who skips during the second must still have the
    /// notes chapter read the note. A body chunk, a definition chunk, an index out of range or an earlier aside chunk
    /// of a longer note changes nothing.
    public mutating func recordPlayedToEnd(chunkAt index: Int, tags: [NarrationChunkPlanner.FootnoteTag?], itemId: String) {
        guard tags.indices.contains(index), case .aside(let label)? = tags[index] else { return }
        guard !tags[(index + 1)...].contains(where: { $0 == .aside(label) }) else { return }
        heard.insert(Key(itemId: itemId, label: label))
    }

    public func hasHeardNote(_ label: String, itemId: String) -> Bool {
        heard.contains(Key(itemId: itemId, label: label))
    }

    /// Whether the player skips this chunk: a definition chunk whose note was already heard where it was cited. Every
    /// other chunk is played, including the definition of a note that was not heard and an aside.
    public func skips(_ tag: NarrationChunkPlanner.FootnoteTag?, itemId: String) -> Bool {
        guard case .definition(let label)? = tag else { return false }
        return hasHeardNote(label, itemId: itemId)
    }

    /// The first chunk at or after `index` that the player plays, given the plan's chunks' `footnote` tags in order: the
    /// definition chunks of heard notes are passed over, and every other chunk is played. Nil when nothing playable is
    /// left, which is the end of the text. An index past the end is the end.
    public func firstPlayableIndex(from index: Int, tags: [NarrationChunkPlanner.FootnoteTag?], itemId: String) -> Int? {
        var next = max(0, index)
        while next < tags.count, skips(tags[next], itemId: itemId) { next += 1 }
        return next < tags.count ? next : nil
    }

    /// Forgets one item's notes, for when its text changes or the listener starts it over from the beginning.
    public mutating func forget(itemId: String) {
        heard = heard.filter { $0.itemId != itemId }
    }
}
