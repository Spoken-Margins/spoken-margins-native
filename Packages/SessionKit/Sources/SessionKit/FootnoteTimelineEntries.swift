import Foundation

/// One footnote as the Timeline shows it (#3777, Design PR 7): "Footnote 3" at its citation's place, with the note's
/// first words under it. A tap goes to the note and reads it.
///
/// The rows are the notes `NarrationChunkPlanner` plans as asides (`FootnoteAnchors`, matched only when certain), so a
/// row never names a note the narrator cannot read where it is cited.
public struct FootnoteTimelineEntry: Equatable, Sendable, Identifiable {
    /// The label as the definition writes it (`3`, `a`), the same one the plan's aside chunks carry.
    public let label: String
    /// Where the note's first citation starts, in characters of the stored article text.
    public let citationStart: Int
    /// Where the sentence that cites it starts, in the same characters: the place a tap goes to when the player has no plan
    /// to ask for the note by. It is never the citation itself, because a listener's seek at the place a note is cited means
    /// the text after the note (`FootnoteNoteControls.restoredStartOffset`), so the note would be passed over without a word.
    public let sentenceStart: Int
    /// The note's words, ready to read, as the Footnote card shows them.
    public let noteText: String

    public init(label: String, citationStart: Int, sentenceStart: Int, noteText: String) {
        self.label = label
        self.citationStart = citationStart
        self.sentenceStart = sentenceStart
        self.noteText = noteText
    }

    public var id: String { "footnote.\(label)" }

    /// "Footnote 3", the card's title on Now.
    public var title: String { "Footnote \(label)" }

    /// The note's first 120 characters, cut at a word.
    public var detail: String {
        TimelineTextPresentation.excerpt(noteText, characterLimit: FootnoteTimelineEntries.detailCharacterLimit)
    }
}

/// Which footnotes the Timeline lists for an article.
public enum FootnoteTimelineEntries {
    /// How much of a note the row shows (Design, Screens: "the note's first 120 characters").
    public static let detailCharacterLimit = 120

    /// The Timeline's footnote rows, in the order of their citations.
    ///
    /// - Parameters:
    ///   - articleText: the item's stored text, the text the notes were matched in.
    ///   - mode: the listener's Footnotes setting. In "Read at the end" the notes are in their own chapter, as before,
    ///     so there are no rows (Design, Screens: "These only appear when the mode is not Read at the end").
    ///   - isNarratedFromText: false for a podcast or other audio, and for a PDF or other structured document. A PDF's
    ///     footnote blocks are skipped where they sit and its markers are silent, so it has no note to hear where it is
    ///     cited (Design, Defaults taken 4); a podcast's text is not narrated.
    public static func entries(
        in articleText: String, mode: FootnoteMode, isNarratedFromText: Bool = true
    ) -> [FootnoteTimelineEntry] {
        guard mode.plansAsides, isNarratedFromText else { return [] }
        let anchors = NarrationChunkPlanner.matchedFootnotes(in: articleText).filter {
            // A note with nothing left to say once normalised has no aside in the plan (`asidePlan`), so it gets no row.
            !SpeechTextNormalizer.normalize($0.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !anchors.isEmpty else { return [] }
        let characters = Array(articleText)
        return anchors.map {
            FootnoteTimelineEntry(
                label: $0.label, citationStart: $0.citationRange.lowerBound,
                sentenceStart: sentenceStart(citedAt: $0.citationRange.lowerBound, in: characters), noteText: $0.text)
        }
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    /// The offset just past a `[^label]` marker that starts at `index`, or nil when none does.
    private static func markerEnd(at index: Int, in characters: [Character]) -> Int? {
        guard index + 2 < characters.count, characters[index] == "[", characters[index + 1] == "^" else { return nil }
        var cursor = index + 2
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "]" { return cursor > index + 2 ? cursor + 1 : nil }
            if character == "[" || character.isWhitespace { return nil }
            cursor += 1
        }
        return nil
    }

    /// Where the sentence that holds the citation at `citation` starts. A marker written after the full stop
    /// (`...a day.[^1] Then...`) belongs to the sentence before it, as the planner reads it, so the spaces, closing marks,
    /// full stop and markers just before the citation are stepped back over first; then the nearest earlier full stop
    /// followed by a space, or line break, ends the previous sentence. The result is before the citation, so a seek there
    /// plays the citing sentence and the narrator's own order reads the note after it.
    static func sentenceStart(citedAt citation: Int, in characters: [Character]) -> Int {
        guard citation > 0, citation <= characters.count else { return 0 }
        var scan = citation
        stepBack: while scan > 0 {
            let character = characters[scan - 1]
            if character == "]" {
                // Another marker just before: step over all of it.
                var open = scan - 2
                while open >= 0, characters[open] != "[" { open -= 1 }
                if open >= 0, markerEnd(at: open, in: characters) == scan { scan = open; continue stepBack }
            }
            if character == " " || character == "\t" || sentenceEnders.contains(character)
                || (character != "]" && closers.contains(character)) {
                scan -= 1
            } else {
                break
            }
        }
        var index = scan
        while index > 0 {
            let before = characters[index - 1]
            if before == "\n" || before == "\r" || before == "\r\n" { break }
            if sentenceEnders.contains(before) {
                var after = index
                while after < characters.count {
                    if sentenceEnders.contains(characters[after]) || closers.contains(characters[after]) {
                        after += 1
                    } else if let end = markerEnd(at: after, in: characters) {
                        after = end
                    } else {
                        break
                    }
                }
                if after < characters.count, characters[after].isWhitespace { index = after; break }
            }
            index -= 1
        }
        while index < scan, characters[index].isWhitespace { index += 1 }
        return min(index, citation - 1)
    }

    /// The rows for an open item: only an item whose text is narrated as it is stored. A podcast or audio file, and a PDF
    /// (the item carries its document structure), have none.
    public static func entries(for item: ItemDetailState, mode: FootnoteMode) -> [FootnoteTimelineEntry] {
        entries(in: item.text, mode: mode, isNarratedFromText: !item.isNativeAudio && item.documentStructure == nil)
    }

    /// The row for `label`, or nil when the article has no such matched note (the text changed, or the mode did).
    public static func entry(
        label: String, in articleText: String, mode: FootnoteMode, isNarratedFromText: Bool = true
    ) -> FootnoteTimelineEntry? {
        entries(in: articleText, mode: mode, isNarratedFromText: isNarratedFromText).first { $0.label == label }
    }

    /// The row of `item` for `label`, or nil.
    public static func entry(label: String, for item: ItemDetailState, mode: FootnoteMode) -> FootnoteTimelineEntry? {
        entries(for: item, mode: mode).first { $0.label == label }
    }
}
