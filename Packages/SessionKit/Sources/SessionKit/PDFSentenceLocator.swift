import Foundation

/// Where a Margin's sentence sits on the pages of a PDF, as text ranges (#4338).
///
/// `MarginCommentPlan` says which sentence each Margin comments on and which page to look on first. Putting a comment
/// on that sentence needs its place on the page, and PDFKit gives a page's text as one string whose line breaks,
/// hyphenation, quotes and spacing are the PDF's own. This is the rule that finds the sentence anyway, as a pure function
/// over page strings so host tests can drive it without PDFKit. The PDFKit side later turns the returned range into
/// highlight rectangles. Nothing here is shown to a listener yet.
///
/// The rule (the Design on #4338, PR 3):
/// 1. Both texts are normalized: composed form, lower case, curly quotes made straight, soft hyphens and the hyphens
///    of a word broken at a line end removed, and runs of white space made one space.
/// 2. The whole sentence is looked for on the hinted page, then on the page before and the page after.
/// 3. Failing that, the longest start of the sentence (at least 8 words and 40 characters) is looked for on the same
///    pages. A sentence that runs onto the next page is therefore highlighted on its first page only.
/// 4. Failing that, the comment is a note at the top of the hinted page.
/// 5. When the text is on a page twice, the place whose 80 characters before it share the longest ending with the
///    Margin's own `preceding` text wins; a tie goes to the first.
public enum PDFSentenceLocator {
    public enum Placement: Equatable, Sendable {
        /// `range` is `Character` offsets into the page's own text, the unit a `String` index counts. `wholeSentence`
        /// is false when only the start of the sentence was found.
        case highlight(page: Int, range: Range<Int>, wholeSentence: Bool)
        /// No exact place: a note at the top of this page.
        case pageNote(page: Int)
    }

    /// A prefix is accepted only with at least this many words and characters, so a common opening ("In the") cannot
    /// land on another sentence.
    public static let minimumPrefixWords = 8
    public static let minimumPrefixCharacters = 40
    /// How much text before a match is compared with the Margin's `preceding` text.
    public static let contextLength = 80

    /// - Parameters:
    ///   - sentence: the sentence as the document spells it (`MarginCommentPlan.Entry.sentenceText`).
    ///   - hintedPage: the zero-based page to look on first (`Entry.pageIndex`), nil when the document has none.
    ///   - preceding: text just before the sentence, used only to choose between two matches. Any length.
    ///   - pageCount: the number of pages in the PDF.
    ///   - pageText: a page's text, nil or empty for a page with no text layer (a scan).
    public static func locate(
        sentence: String,
        hintedPage: Int?,
        preceding: String = "",
        pageCount: Int,
        pageText: (Int) -> String?
    ) -> Placement {
        let notePage = noteHome(hintedPage, pageCount: pageCount)
        let target = Normalized(sentence).characters
        guard !target.isEmpty, pageCount > 0 else { return .pageNote(page: notePage) }
        let pages = searchOrder(hintedPage, pageCount: pageCount)
        let context = Array(Normalized(preceding).characters.suffix(contextLength))

        let loaded: [(page: Int, text: Normalized)] = pages.compactMap { page in
            guard let text = pageText(page), text.contains(where: { !$0.isWhitespace }) else { return nil }
            return (page, Normalized(text))
        }
        if let whole = bestMatch(of: target, in: loaded, context: context) {
            return .highlight(page: whole.page, range: whole.range, wholeSentence: true)
        }
        if let prefix = prefixes(of: target) {
            for candidate in prefix {
                if let found = bestMatch(of: candidate, in: loaded, context: context) {
                    return .highlight(page: found.page, range: found.range, wholeSentence: false)
                }
            }
        }
        return .pageNote(page: notePage)
    }

    // MARK: - Where to look

    /// The page a note goes on: the hinted page, kept inside the document; the first page when there is no hint.
    static func noteHome(_ hintedPage: Int?, pageCount: Int) -> Int {
        guard let hintedPage, pageCount > 0 else { return 0 }
        return min(max(0, hintedPage), pageCount - 1)
    }

    /// The hinted page, then the one before it, then the one after. With no hint every page, in order.
    static func searchOrder(_ hintedPage: Int?, pageCount: Int) -> [Int] {
        guard let hintedPage else { return Array(0..<max(0, pageCount)) }
        let home = noteHome(hintedPage, pageCount: pageCount)
        return [home, home - 1, home + 1].filter { $0 >= 0 && $0 < pageCount }
    }

    /// The starts of `target` to try, longest first: whole words only, at least `minimumPrefixWords` words and
    /// `minimumPrefixCharacters` characters. Nil when the sentence is too short to have one.
    static func prefixes(of target: [Character]) -> [[Character]]? {
        var ends: [Int] = []
        for index in target.indices where target[index] == " " { ends.append(index) }
        ends.append(target.count)
        // `ends[k]` is where word k+1 ends, so a prefix of `words` words is `target[..<ends[words - 1]]`.
        let fullWords = ends.count
        guard fullWords > minimumPrefixWords else { return nil }
        var result: [[Character]] = []
        for words in stride(from: fullWords - 1, through: minimumPrefixWords, by: -1) {
            let end = ends[words - 1]
            if end >= minimumPrefixCharacters { result.append(Array(target[..<end])) }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Matching

    private struct Match {
        var page: Int
        var range: Range<Int>
    }

    /// The best place of `needle` on the first of `pages` that holds it. Pages are in search order, so the hinted page
    /// beats its neighbours, and a match on it is never traded for a better-looking one elsewhere.
    private static func bestMatch(of needle: [Character], in pages: [(page: Int, text: Normalized)], context: [Character]) -> Match? {
        for (page, text) in pages {
            let starts = occurrences(of: needle, in: text.characters).filter {
                onWordBoundaries(start: $0, length: needle.count, in: text.characters)
            }
            guard !starts.isEmpty else { continue }
            let chosen = starts.count == 1 ? starts[0] : starts.max { lhs, rhs in
                let (left, right) = (sharedEnding(text.characters, before: lhs, with: context), sharedEnding(text.characters, before: rhs, with: context))
                return left < right || (left == right && lhs > rhs) // a tie goes to the earlier one
            }!
            let first = text.original[chosen], last = text.original[chosen + needle.count - 1]
            return Match(page: page, range: first..<(last + 1))
        }
        return nil
    }

    /// Whether the match neither begins nor ends inside a word of the page ("in the" is not "within the", and a start
    /// ending "sleep" is not "sleeping"). A neighbour that is not a letter or digit, or the page's edge, is a boundary.
    private static func onWordBoundaries(start: Int, length: Int, in text: [Character]) -> Bool {
        if start > 0, text[start - 1].isLetter || text[start - 1].isNumber,
           text[start].isLetter || text[start].isNumber { return false }
        let end = start + length
        if end < text.count, text[end].isLetter || text[end].isNumber,
           text[end - 1].isLetter || text[end - 1].isNumber { return false }
        return true
    }

    /// The offsets in `haystack` where `needle` starts (Knuth-Morris-Pratt, so a page of repeated words costs one pass).
    static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        var failure = [Int](repeating: 0, count: needle.count)
        var k = 0
        for index in 1..<needle.count {
            while k > 0, needle[index] != needle[k] { k = failure[k - 1] }
            if needle[index] == needle[k] { k += 1 }
            failure[index] = k
        }
        var found: [Int] = []
        k = 0
        for (index, character) in haystack.enumerated() {
            while k > 0, character != needle[k] { k = failure[k - 1] }
            if character == needle[k] { k += 1 }
            if k == needle.count {
                found.append(index - needle.count + 1)
                k = failure[k - 1]
            }
        }
        return found
    }

    /// How many characters at the end of the text before `start` agree with the end of `context`.
    /// The space the page puts between that text and the sentence is not part of either, so it is skipped.
    private static func sharedEnding(_ text: [Character], before start: Int, with context: [Character]) -> Int {
        let end = start > 0 && text[start - 1] == " " ? start - 1 : start
        var shared = 0
        while shared < context.count, shared < end,
              text[end - 1 - shared] == context[context.count - 1 - shared] { shared += 1 }
        return shared
    }

    // MARK: - Normalizing

    /// A text folded for comparison, with where each folded character came from in the original.
    struct Normalized {
        var characters: [Character] = []
        /// For each folded character, the `Character` offset in the original text it came from.
        var original: [Int] = []

        init(_ text: String) {
            let source = Array(text)
            var index = 0
            while index < source.count {
                let character = source[index]
                if character.isWhitespace {
                    // One space for a run of white space; none at the start.
                    if let last = characters.last, last != " " {
                        characters.append(" ")
                        original.append(index)
                    }
                } else if character == "\u{00AD}" {
                    // Invisible in the page and absent from the document's text; before a line break it takes the
                    // break with it, so "hun<soft hyphen>\ndred" folds to "hundred".
                    index += Self.softHyphenSkip(in: source, at: index)
                    continue
                } else if Self.isHyphen(character) {
                    if let skip = Self.hyphenSkip(in: source, at: index) {
                        index += skip
                        continue
                    }
                    append(character, from: index)
                } else {
                    append(character, from: index)
                }
                index += 1
            }
            if characters.last == " " { characters.removeLast(); original.removeLast() }
        }

        private mutating func append(_ character: Character, from index: Int) {
            var folded: String
            switch character {
            case "\u{2018}", "\u{2019}", "\u{201B}", "\u{02BC}": folded = "'"
            case "\u{201C}", "\u{201D}", "\u{201F}": folded = "\""
            default: folded = String(character).precomposedStringWithCanonicalMapping.lowercased()
            }
            // A soft hyphen is invisible in the page and absent from the document's text.
            if folded == "\u{00AD}" { return }
            for piece in folded where piece != "\u{00AD}" {
                characters.append(piece)
                original.append(index)
            }
        }

        private static func isHyphen(_ character: Character) -> Bool {
            character == "-" || character == "\u{2010}" || character == "\u{2011}"
        }

        /// A soft hyphen goes alone, or with the white space after it when that holds a line break and a word follows.
        private static func softHyphenSkip(in source: [Character], at index: Int) -> Int {
            var next = index + 1
            var sawBreak = false
            while next < source.count, source[next].isWhitespace {
                if source[next].isNewline { sawBreak = true }
                next += 1
            }
            let afterIsWord = next < source.count && (source[next].isLetter || source[next].isNumber)
            return sawBreak && afterIsWord ? next - index : 1
        }

        /// How many characters to skip when the hyphen at `index` is not part of the words: one that ends a line (its
        /// white space with a line break goes too), and one inside a word, which a wrapped copy and a joined copy of
        /// the same word then spell alike. Nil keeps the hyphen (a dash between spaces, a leading minus).
        private static func hyphenSkip(in source: [Character], at index: Int) -> Int? {
            var next = index + 1
            var sawBreak = false
            while next < source.count, source[next].isWhitespace {
                if source[next].isNewline { sawBreak = true }
                next += 1
            }
            let afterIsWord = next < source.count && (source[next].isLetter || source[next].isNumber)
            if sawBreak, afterIsWord, index > 0, source[index - 1].isLetter || source[index - 1].isNumber {
                return next - index
            }
            if next == index + 1, afterIsWord, index > 0, source[index - 1].isLetter || source[index - 1].isNumber {
                return 1
            }
            return nil
        }
    }
}
