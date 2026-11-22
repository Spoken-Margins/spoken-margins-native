import Foundation

/// What the player's controls and the Now pane's card need to know about the note being read (#3777). Every rule here
/// is a pure function of the plan's chunks, so the audio client, the transport and the card all give one answer and a
/// host test can pin it. Nothing calls this yet; the slices that wire it into the player, the paragraph button and the
/// card come after it.
///
/// `tags` is the plan's chunks' `footnote` tags in order (`NarrationChunkPlanner.SpokenChunk.footnote`), and `texts`
/// the same chunks' spoken text. An index outside them is never a note.
public enum FootnoteNoteControls {
    public typealias Tag = NarrationChunkPlanner.FootnoteTag

    /// Whether the chunk at `index` is an aside (a note read where it is cited).
    public static func isAside(at index: Int, tags: [Tag?]) -> Bool {
        guard tags.indices.contains(index), case .aside? = tags[index] else { return false }
        return true
    }

    /// What the paragraph-forward button (¶›) does at a chunk (Design, Flow 3).
    public enum ParagraphForward: Hashable, Sendable {
        /// The chunk is not an aside: the button moves by paragraph as it always did.
        case notOnANote
        /// The note ends early and playback goes on at this chunk, the sentence of the main text after the citing one.
        case continueAt(Int)
        /// No chunk follows the note: the button ends the note and the text is over.
        case endOfText
    }

    /// ¶› during an aside leaves the note and goes on with the main text, not to the next paragraph from the held
    /// position (the citing sentence's end, which would skip the rest of the paragraph the listener is in). It leaves
    /// the whole run of asides at that citation: a sentence that cites three notes is not three presses of the button,
    /// and a note left unheard is still read in the notes chapter (Design, Flow 3 and 4). So a note in the text's last
    /// sentence continues into the notes chapter, where its own definition is read: the planner puts definition chunks
    /// after every aside, and a note cut short is not heard. `endOfText` is for a plan with nothing after the note. The
    /// caller applies
    /// `FootnoteHeardSet.firstPlayableIndex(from:tags:itemId:)` to the answer, so a heard definition is passed over.
    public static func paragraphForward(from index: Int, tags: [Tag?]) -> ParagraphForward {
        guard isAside(at: index, tags: tags) else { return .notOnANote }
        var next = index + 1
        while next < tags.count, isAside(at: next, tags: tags) { next += 1 }
        return next < tags.count ? .continueAt(next) : .endOfText
    }

    /// The chunk a position saved or resumed during a note belongs to (Design, Around it and `relaunch`): the chunk
    /// before the first aside at that citation (the last chunk of the citing sentence, which is its whole when the
    /// sentence is one chunk), so a relaunch replays that and then the note. An aside has no source characters, so its own offset is the citing sentence's end, and the note would
    /// then be skipped over. A chunk that is not an aside answers itself. A note that comes before any body chunk
    /// answers the first chunk after it. Nil for an index outside the plan.
    public static func resumeIndex(forChunkAt index: Int, tags: [Tag?]) -> Int? {
        guard tags.indices.contains(index) else { return nil }
        guard isAside(at: index, tags: tags) else { return index }
        var first = index
        while first > 0, isAside(at: first - 1, tags: tags) { first -= 1 }
        if first > 0 { return first - 1 }
        var after = index + 1
        while after < tags.count, isAside(at: after, tags: tags) { after += 1 }
        return after < tags.count ? after : index
    }

    /// Where a play that resumes during a note starts, in the plan's own offsets: the start of the chunk
    /// `resumeIndex(forChunkAt:tags:)` names. An aside's own offset is the citing sentence's end, which the next body
    /// chunk shares, so a resume at it would start that body chunk and drop the note without a word. Resuming at the
    /// citing sentence's last chunk plays it again and the player's own order then reads the note, which is "the note
    /// plays again after it" of the Design's Around it. Nil when the chunk at `index` is not an aside (the play keeps
    /// its own offset then) or when `startOffsets` does not line up with `tags`.
    public static func heldStartOffset(forChunkAt index: Int, tags: [Tag?], startOffsets: [Int]) -> Int? {
        guard tags.count == startOffsets.count, isAside(at: index, tags: tags),
              let resume = resumeIndex(forChunkAt: index, tags: tags) else { return nil }
        return startOffsets[resume]
    }

    /// The index range of the one note whose aside chunks include `index`: every neighbouring aside chunk with the
    /// same label (a note longer than the chunk budget is split into several). Nil when `index` is not an aside.
    public static func noteRange(containing index: Int, tags: [Tag?]) -> Range<Int>? {
        guard tags.indices.contains(index), case .aside(let label)? = tags[index] else { return nil }
        var lower = index
        while lower > 0, tags[lower - 1] == .aside(label) { lower -= 1 }
        var upper = index + 1
        while upper < tags.count, tags[upper] == .aside(label) { upper += 1 }
        return lower..<upper
    }
}

/// The words of the Footnote card on Now (Design, Screens). It carries no Margin record and no person's name: a note
/// belongs to the source, and the card must not be mistaken for a friend's Margin.
public struct FootnoteCard: Equatable, Sendable {
    /// The source's own label (`[^a]` is "a").
    public let label: String
    /// The note's text as the narrator reads it, without the "Note 3." lead, whole across every chunk the planner split
    /// it into. The card shows up to six lines of it; VoiceOver reads all of it.
    public let body: String

    public init(label: String, body: String) {
        self.label = label
        self.body = body
    }

    /// "Footnote 3", using the source's own label.
    public var title: String { "Footnote \(label)" }

    /// The card's header line: "Footnote 3", and "Footnote 3 · Reading" while the note is being read.
    public func header(reading: Bool) -> String {
        reading ? "\(title) · Reading" : title
    }

    /// What VoiceOver reads for the card: "Footnote 3. <text>". The Hear note button is its own element after it.
    public var voiceOverLabel: String { "\(title). \(body)" }

    /// The card for the note whose aside includes the chunk at `index`. Nil when that chunk is not an aside, when
    /// `texts` does not line up with `tags`, or when nothing is left of the note once the lead is removed (the planner
    /// makes no aside for such a note, so a card for it would be a card with nothing to say).
    public static func forChunk(at index: Int, tags: [FootnoteNoteControls.Tag?], texts: [String]) -> FootnoteCard? {
        guard tags.count == texts.count,
              let range = FootnoteNoteControls.noteRange(containing: index, tags: tags),
              case .aside(let label)? = tags[index] else { return nil }
        let joined = texts[range]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let body = strippingLead(joined, label: label)
        return body.isEmpty ? nil : FootnoteCard(label: label, body: body)
    }

    /// The aside's text without the lead the narrator says before it ("Note 3." or "Note."), which the planner puts on
    /// the first chunk of every note. The planner normalizes the lead together with the note's text, which can rewrite
    /// it (a label `.` gives "Note..", a math-alphabet letter gives a plain one), so the lead is matched as written and
    /// as normalized. Text that starts with neither is left alone.
    ///
    /// Known limit: the chunks are joined with a space. A note with 180 or more characters and no space in them is cut
    /// inside a word by the chunker, and the card then shows a space there.
    static func strippingLead(_ text: String, label: String) -> String {
        let lead = NarrationChunkPlanner.asideLead(forLabel: label)
        for candidate in [lead, SpeechTextNormalizer.normalize(lead).trimmingCharacters(in: .whitespacesAndNewlines)]
        where text.hasPrefix(candidate) {
            return String(text.dropFirst(candidate.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
