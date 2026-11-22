import Foundation

/// Which sentence of a PDF each of the listener's own Margins comments on, and what the comment would say (#4338).
///
/// Exporting a PDF with the listener's Margins as comments needs three answers per Margin before any PDF is touched:
/// the sentence the Margin was spoken on, the page to look on first, and the words the comment carries. This is
/// that rule as pure functions over the item's structured document and its Margins, so host tests can check it
/// without PDFKit. The writer that finds the sentence on a page and adds the annotation comes later and takes
/// this plan as its input. Nothing here is shown to a listener yet.
///
/// - Only the listener's own Margins are planned. A friend's Margins live in `ImportedCommentaryLayer`, a different
///   type, so they cannot reach this function; a Margin of another item, or one that was deleted, is left out.
/// - Offsets are `Character` offsets into `StructuredDocument.text`, the unit the anchors and segments use.
public struct MarginCommentPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public enum Status: Equatable, Sendable {
            /// The comment has words and goes out.
            case included
            /// A spoken Margin still transcribing: it has no words yet and cannot be included.
            case transcriptPending
            /// Transcription failed or came back empty: nothing to say, so nothing to export.
            case noTranscript
        }

        public var id: String { marginId }
        public var marginId: String
        /// The sentence around the Margin's anchor, as `Character` offsets into the document text. Nil only when the
        /// document has no text at all.
        public var sentence: Range<Int>?
        /// The sentence's characters, exactly as the document spells them (hard line breaks and all). Empty when
        /// `sentence` is nil.
        public var sentenceText: String
        /// Up to `precedingLength` characters of the document's text just before the sentence, as the document spells
        /// them. Only used to tell two copies of the same sentence on a page apart (`PDFSentenceLocator`). Empty when
        /// `sentence` is nil or starts the text.
        public var precedingText: String = ""
        /// The zero-based page of the segment the anchor sits in, the page to look on first. Nil when the document
        /// has no page for it (no segment holds the anchor, or its `pageIndex` is not a page of the document).
        public var pageIndex: Int?
        /// The Margin's words as the app shows them (`displayText ?? cleanedTranscript ?? transcript`), trimmed.
        /// Empty unless `status` is `.included`.
        public var commentText: String
        public var status: Status
    }

    /// How much text before the sentence an entry carries in `precedingText`.
    public static let precedingLength = 80

    /// One entry per own Margin of the item, in document order (then the order they were made).
    public var entries: [Entry]

    /// The app's export sheet starts from an empty plan before the Margins are read (#4690), so the initializer is
    /// public; Swift keeps a public struct's memberwise one internal to the package.
    public init(entries: [Entry]) { self.entries = entries }

    public var included: [Entry] { entries.filter { $0.status == .included } }

    /// Plans the comments for `margins` on the item `itemId` whose text is `document`.
    public static func make(itemId: String, document: StructuredDocument, margins: [Interjection]) -> MarginCommentPlan {
        make(itemId: itemId, text: document.text, margins: margins) { index in
            page(of: index, in: document.segments, pageCount: document.extraction.pageCount)
        }
    }

    /// Plans the comments for an item that has text and no pages: a Word document, whose item is its plain text (#4595).
    /// Every entry's `pageIndex` is nil, because a Word file has no page the app can name.
    public static func make(itemId: String, text: String, margins: [Interjection]) -> MarginCommentPlan {
        make(itemId: itemId, text: text, margins: margins) { _ in nil }
    }

    private static func make(
        itemId: String, text: String, margins: [Interjection], pageOf: (Int) -> Int?
    ) -> MarginCommentPlan {
        let characters = Array(text)
        let sentences = SentenceBounds.ranges(in: characters)
        let own = margins
            .filter { $0.itemId == itemId && $0.targetType == .item && $0.status == "active" && $0.anchor.anchorType == .text }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.anchor.startChar, rhs.anchor.startChar)
                if left != right { return left < right }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        let entries = own.map { margin -> Entry in
            let position = anchorPosition(margin.anchor.startChar, in: characters)
            let sentence = position.flatMap { sentenceRange(containing: $0, in: sentences) }
            let words = (margin.displayText ?? margin.cleanedTranscript ?? margin.transcript ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status: Entry.Status
            if !words.isEmpty {
                status = .included
            } else if margin.transcriptionStatus == "pending" {
                status = .transcriptPending
            } else {
                status = .noTranscript
            }
            return Entry(
                marginId: margin.id,
                sentence: sentence,
                sentenceText: sentence.map { String(characters[$0]) } ?? "",
                precedingText: sentence.map { String(characters[max(0, $0.lowerBound - precedingLength)..<$0.lowerBound]) } ?? "",
                pageIndex: position.flatMap(pageOf),
                commentText: status == .included ? words : "",
                status: status
            )
        }
        return MarginCommentPlan(entries: entries)
    }

    /// The character an anchor starts on, moved onto text: a start before the text or past its end is clamped, and a
    /// start on white space (the gap between paragraphs) moves forward to the next word, because the listener was
    /// about to hear it, or back to the last word when there is none after. Nil only for a text with no words.
    static func anchorPosition(_ startChar: Int, in characters: [Character]) -> Int? {
        guard characters.contains(where: { !$0.isWhitespace }) else { return nil }
        var index = min(max(0, startChar), characters.count - 1)
        if let forward = characters[index...].firstIndex(where: { !$0.isWhitespace }) { return forward }
        index = characters[...index].lastIndex(where: { !$0.isWhitespace }) ?? index
        return index
    }

    /// The sentence holding `index`. `sentences` is in order and does not overlap.
    private static func sentenceRange(containing index: Int, in sentences: [Range<Int>]) -> Range<Int>? {
        var low = 0
        var high = sentences.count
        while low < high {
            let middle = (low + high) / 2
            if sentences[middle].upperBound <= index { low = middle + 1 } else { high = middle }
        }
        return low < sentences.count && sentences[low].contains(index) ? sentences[low] : nil
    }

    /// The page of the segment that contains `index`: the narrowest one when segments overlap, nil when none does
    /// or when the segment has no page the document actually has (`0 ..< pageCount`).
    private static func page(of index: Int, in segments: [StructuredDocument.Segment], pageCount: Int) -> Int? {
        let containing = segments.filter { $0.range.start <= index && index < $0.range.end }
        guard let segment = containing.min(by: { ($0.range.length, $0.range.start) < ($1.range.length, $1.range.start) }),
              let page = segment.pageIndex, page >= 0, page < pageCount else { return nil }
        return page
    }
}

/// Where sentences end in extracted text. One pass over the characters, so a 300-page paper costs the same as
/// one paragraph per Margin looked up.
///
/// A sentence ends at `.`, `!`, `?` or `…` (with any closing quotes or brackets after it) that is followed by white
/// space and then an uppercase letter, a digit or an opening quote; or at a paragraph break, which is a blank line.
/// A full stop after "e.g.", "i.e.", "et al.", "Fig.", "Dr." and the like, or after a single capital letter (an initial,
/// "U.S."), never ends one. Text with no capitals (some scripts) therefore only splits at paragraph breaks.
enum SentenceBounds {
    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]", "»"]
    private static let openingQuotes: Set<Character> = ["\"", "“", "‘", "'", "«"]
    /// Never a sentence end, whatever follows. Lowercased, without the final full stop. Dotted forms ("e.g", "i.e",
    /// "u.s") are caught by `isDottedInitials`.
    private static let abbreviations: Set<String> = ["fig", "figs", "dr", "vs", "cf", "eq", "eqs", "ph.d"]
    /// Titles and name suffixes, matched with their capital: "Ms." is a title, "ms." is milliseconds.
    private static let titles: Set<String> = ["Mr", "Mrs", "Ms", "Prof", "St", "Jr", "Sr", "Inc", "Co", "Mt"]
    /// Abbreviations that are also ordinary words or units, so they only count when a digit follows: "p. 4",
    /// "No. 5", "Tab. 2" are one sentence, but "We set p. Then we ran." and "Wait 3 sec. Then go." are two.
    private static let abbreviationsBeforeANumber: Set<String> = ["p", "pp", "no", "tab", "ch", "sec", "sect", "vol", "ref", "refs", "approx"]

    /// The ranges of the sentences in `characters`, each trimmed of the white space around it, in order.
    static func ranges(in characters: [Character]) -> [Range<Int>] {
        let count = characters.count
        var result: [Range<Int>] = []
        var index = skipWhitespace(characters, from: 0)
        var start = index

        func finish(at end: Int) {
            var trimmed = end
            while trimmed > start, characters[trimmed - 1].isWhitespace { trimmed -= 1 }
            if trimmed > start { result.append(start..<trimmed) }
        }

        while index < count {
            let character = characters[index]
            if terminators.contains(character) {
                var runEnd = index
                while runEnd < count, terminators.contains(characters[runEnd]) { runEnd += 1 }
                var afterClosers = runEnd
                while afterClosers < count, closers.contains(characters[afterClosers]) { afterClosers += 1 }
                if afterClosers < count, characters[afterClosers].isWhitespace {
                    let next = skipWhitespace(characters, from: afterClosers)
                    if next < count,
                       startsSentence(characters[next]),
                       !(runEnd - index == 1 && characters[index] == "." && endsAbbreviation(characters, periodAt: index, before: characters[next])),
                       !isParagraphBreak(characters, from: afterClosers, to: next) {
                        finish(at: afterClosers)
                        start = next
                        index = next
                        continue
                    }
                }
                index = afterClosers
            } else if character.isWhitespace {
                let next = skipWhitespace(characters, from: index)
                if next < count, isParagraphBreak(characters, from: index, to: next) {
                    finish(at: index)
                    start = next
                }
                index = next
            } else {
                index += 1
            }
        }
        finish(at: count)
        return result
    }

    private static func skipWhitespace(_ characters: [Character], from index: Int) -> Int {
        var next = index
        while next < characters.count, characters[next].isWhitespace { next += 1 }
        return next
    }

    /// A blank line or a paragraph separator in `characters[from..<to]`. "\r\n" is one Character in Swift, so it
    /// counts as one line break.
    private static func isParagraphBreak(_ characters: [Character], from: Int, to: Int) -> Bool {
        var lineBreaks = 0
        for index in from..<to {
            let character = characters[index]
            if character == "\u{2029}" { return true }
            if character.isNewline { lineBreaks += 1 }
        }
        return lineBreaks >= 2
    }

    private static func startsSentence(_ character: Character) -> Bool {
        character.isUppercase || character.isWholeNumber || openingQuotes.contains(character)
    }

    /// Whether the full stop at `periodAt` closes an abbreviation or an initial instead of a sentence.
    private static func endsAbbreviation(_ characters: [Character], periodAt period: Int, before next: Character) -> Bool {
        var begin = period
        while begin > 0, !characters[begin - 1].isWhitespace, !openers.contains(characters[begin - 1]) { begin -= 1 }
        let word = String(characters[begin..<period])
        guard !word.isEmpty else { return false }
        let lowered = word.lowercased()
        if abbreviations.contains(lowered) || titles.contains(word) || isDottedInitials(word) { return true }
        if abbreviationsBeforeANumber.contains(lowered), next.isWholeNumber { return true }
        // A single capital letter is an initial ("J. Smith"); a single lowercase one is a word ("option a.").
        if word.count == 1, let only = word.first, only.isUppercase { return true }
        if lowered == "al" { return previousWord(characters, before: begin)?.lowercased() == "et" }
        return false
    }

    private static let openers: Set<Character> = ["(", "[", "“", "‘", "\"", "'", "«"]

    /// "e.g", "i.e", "U.S": two or more single letters joined by full stops.
    private static func isDottedInitials(_ word: String) -> Bool {
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
    }

    private static func previousWord(_ characters: [Character], before index: Int) -> String? {
        var end = index
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        var begin = end
        while begin > 0, !characters[begin - 1].isWhitespace { begin -= 1 }
        return begin < end ? String(characters[begin..<end]) : nil
    }
}
