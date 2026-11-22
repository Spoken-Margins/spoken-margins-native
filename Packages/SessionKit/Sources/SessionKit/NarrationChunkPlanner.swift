#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The one way an article is split into narration chunks (#312).
///
/// Three paths must agree on an article's chunks, or "ready offline" silently breaks: the live
/// player (which may speak an "Overview. …" preface first), background preparation, and the
/// assembly of prepared audio. They broke apart across Builds 29 and 30 (#258). All three now take
/// their chunks from here, and prepared audio is matched by `ArticlePlan.identity` rather than by
/// comparing texts.
public enum NarrationChunkPlanner {
    /// Bumping this invalidates every prepared manifest: change it only with the chunking itself.
    public static let version = "rendered-speech-chunker.v2"

    /// What a chunk is when it belongs to a footnote (#3777). `nil` on every body chunk.
    public enum FootnoteTag: Equatable, Sendable {
        /// An inserted chunk that reads the note `label` right after the sentence that cites it. It adds no source
        /// characters: its `sourceLength` is 0 and its `startOffset` is the citing sentence's end, so progress holds there.
        case aside(String)
        /// A chunk of that note's own definition in the notes section, which the player may skip once the aside was heard.
        case definition(String)
    }

    public struct Chunk: Equatable, Sendable {
        public var index: Int
        /// In the article's normalized spoken text.
        public var startOffset: Int
        public var sourceLength: Int
        public var text: String
        public var boundary: RenderedSpeechChunkBoundary
        public var footnote: FootnoteTag? = nil
    }

    public struct ArticlePlan: Equatable, Sendable {
        public var identity: String
        public var normalizedText: String
        public var chunks: [Chunk]
    }

    /// Identifies an article's plan: its text and the chunker version. Cheap, so lookups can check it.
    public static func identity(ofArticle articleText: String) -> String {
        identityHash(articleText, asides: false)
    }

    /// The identity of the plan `articlePlan(_:asides:)` makes. With `asides` false it is `identity(ofArticle:)`. With
    /// `asides` true it differs only when the article has a footnote that can be read where it is cited: the plan
    /// then has chunks no other plan has, so prepared audio saved for one must never be matched to the other. An
    /// article without such a note plans the same chunks either way and keeps its one identity, so turning the setting
    /// on does not invalidate its prepared audio.
    public static func identity(ofArticle articleText: String, asides: Bool) -> String {
        identityHash(articleText, asides: asides && !matchedFootnotes(in: articleText).isEmpty)
    }

    private static func identityHash(_ articleText: String, asides: Bool) -> String {
        var hash = SHA256()
        hash.update(data: Data(version.utf8))
        hash.update(data: Data([0x1f]))
        hash.update(data: Data(articleText.utf8))
        if asides {
            hash.update(data: Data([0x1f]))
            hash.update(data: Data("footnote-asides.v1".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The Character ranges of an article's footnote citations that the narrator stays silent at when the notes are read
    /// where they are cited: every citation of every matched note. Empty when no note matches. A caller that
    /// normalizes the article together with a preface passes these, moved by the preface's length, to
    /// `SpeechTextNormalizer.normalizeWithSourceOffsets(_:silencingSourceRanges:)`, so its spoken text is the one
    /// `articlePlan(_:asides: true)` plans.
    public static func silencedCitationRanges(inArticle articleText: String) -> [Range<Int>] {
        matchedFootnotes(in: articleText).flatMap(\.citationRanges)
    }

    /// The article's own chunks: what background preparation renders and saves.
    ///
    /// With `asides` true, a note that `FootnoteAnchors` matches is read where it is cited (#3777): its marker is
    /// silent, an aside chunk "Note 3. …" follows the citing sentence, and the note's definition in the notes
    /// section becomes its own `.definition` chunks, so the player can skip it once the aside was heard. An article
    /// with no matched note plans exactly as with `asides` false. `articlePlan(text)` is unchanged.
    public static func articlePlan(
        _ articleText: String, budget: Int = RenderedSpeechChunker.spokenCostBudget, asides: Bool = false
    ) -> ArticlePlan {
        if asides {
            let anchors = matchedFootnotes(in: articleText)
            if !anchors.isEmpty { return asidePlan(articleText, anchors: anchors, budget: budget) }
        }
        let normalized = SpeechTextNormalizer.normalize(articleText)
        let chunks = RenderedSpeechChunker.sourceSlices(from: normalized, maxCharacters: budget)
            .enumerated()
            .map { index, planned in
                Chunk(index: index, startOffset: planned.startOffset, sourceLength: planned.slice.sourceLength,
                      text: planned.slice.text, boundary: planned.slice.boundary)
            }
        return ArticlePlan(identity: identity(ofArticle: articleText), normalizedText: normalized, chunks: chunks)
    }

    /// A chunk the player renders. `articleIndex` is its index in the article plan, or nil for a
    /// preface chunk (prepared audio never includes the preface).
    public struct SpokenChunk: Equatable, Sendable {
        public var startOffset: Int
        public var sourceLength: Int
        public var text: String
        public var boundary: RenderedSpeechChunkBoundary
        public var articleIndex: Int?
        /// Set on the chunks of a footnote (an aside or its definition); never on body or preface chunks. This, not a
        /// nil `articleIndex` (which means the preface), is how the player recognises a note.
        public var footnote: FootnoteTag?

        public init(startOffset: Int, sourceLength: Int, text: String, boundary: RenderedSpeechChunkBoundary,
                    articleIndex: Int? = nil, footnote: FootnoteTag? = nil) {
            self.startOffset = startOffset
            self.sourceLength = sourceLength
            self.text = text
            self.boundary = boundary
            self.articleIndex = articleIndex
            self.footnote = footnote
        }
    }

    public struct SpokenPlan: Equatable, Sendable {
        public var chunks: [SpokenChunk]
        /// The article plan's identity when the article's chunks are exactly the prepared ones. Nil
        /// with no article text (the caller identifies the spoken text itself), or when the spoken
        /// text doesn't end in the article's normalized text (then no chunk has an article index).
        public var articleIdentity: String?
        public var articleSpokenStart: Int
    }

    /// What the player renders for `spokenText`, which is `articleText` normalized, optionally
    /// after a preface that ends at `articleSpokenStart`.
    ///
    /// With `asides` true the article is planned as `articlePlan(_:asides: true)` and `spokenText` must end in that
    /// plan's normalized text (the one with silent citation markers; see `silencedCitationRanges(inArticle:)`).
    /// A spoken text that still speaks the markers does not match, and is planned as plain text without asides.
    public static func spokenPlan(
        spokenText: String,
        articleText: String?,
        articleSpokenStart: Int,
        budget: Int = RenderedSpeechChunker.spokenCostBudget,
        asides: Bool = false
    ) -> SpokenPlan {
        let start = max(0, min(articleSpokenStart, spokenText.count))
        if let articleText, !articleText.isEmpty {
            let article = articlePlan(articleText, budget: budget, asides: asides)
            let split = spokenText.index(spokenText.startIndex, offsetBy: start)
            if String(spokenText[split...]) == article.normalizedText {
                var preface = start > 0
                    ? RenderedSpeechChunker.sourceSlices(from: String(spokenText[..<split]), maxCharacters: budget).map {
                        SpokenChunk(startOffset: $0.startOffset, sourceLength: $0.slice.sourceLength,
                                    text: $0.slice.text, boundary: $0.slice.boundary, articleIndex: nil)
                    }
                    : []
                // The chunker leaves trailing whitespace uncovered. Between preface and article that
                // gap made the chunk after the preface start one character early, off the plan.
                if let last = preface.indices.last, preface[last].startOffset + preface[last].sourceLength < start {
                    preface[last].sourceLength = start - preface[last].startOffset
                }
                let body = article.chunks.map {
                    SpokenChunk(startOffset: start + $0.startOffset, sourceLength: $0.sourceLength,
                                text: $0.text, boundary: $0.boundary, articleIndex: $0.index, footnote: $0.footnote)
                }
                return SpokenPlan(chunks: preface + body, articleIdentity: article.identity, articleSpokenStart: start)
            }
        }
        // No article text given: the spoken text is the article, as before #292 (identity nil; the
        // caller identifies it by its own source text). Given but not matching: plan the whole
        // spoken text and match no prepared audio.
        let isArticle = articleText == nil
        let chunks = RenderedSpeechChunker.sourceSlices(from: spokenText, maxCharacters: budget).enumerated().map { index, planned in
            SpokenChunk(startOffset: planned.startOffset, sourceLength: planned.slice.sourceLength,
                        text: planned.slice.text, boundary: planned.slice.boundary, articleIndex: isArticle ? index : nil)
        }
        return SpokenPlan(chunks: chunks, articleIdentity: nil, articleSpokenStart: 0)
    }
}

// MARK: - Footnotes read where they are cited (#3777)

extension NarrationChunkPlanner {
    /// The plan of an article with at least one matched footnote, read where cited.
    ///
    /// The spoken text is the article's normalized text with every matched citation left out. It is cut at three kinds
    /// of place, and each piece is chunked on its own, so no body chunk crosses a cut: the end of the sentence that
    /// holds each citation (where the aside goes), and the start and end of each matched note's definition (so its
    /// chunks carry `.definition`). Every body character is in exactly one non-aside chunk, as without asides.
    fileprivate static func asidePlan(_ articleText: String, anchors: [FootnoteAnchor], budget: Int) -> ArticlePlan {
        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(
            articleText, silencingSourceRanges: anchors.flatMap(\.citationRanges))
        let characters = Array(normalized.text)
        let length = characters.count
        func spoken(atOrAfter sourceOffset: Int) -> Int {
            min(length, normalized.spokenCharacterOffset(atOrAfterSourceOffset: sourceOffset))
        }

        // Where each definition sits in the spoken text, in order.
        let definitions = anchors
            .map { (label: $0.label, range: spoken(atOrAfter: $0.definitionRange.lowerBound)..<spoken(atOrAfter: $0.definitionRange.upperBound)) }
            .filter { !$0.range.isEmpty }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }

        let source = Array(articleText)
        var asidesByCut: [Int: [(label: String, chunks: [RenderedSpeechPlannedSlice])]] = [:]
        for anchor in anchors {
            let spokenLead = Self.asideLead(forLabel: anchor.label)
            // A note with nothing left to say once cleaned has no aside; its marker stays silent.
            guard !SpeechTextNormalizer.normalize(anchor.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let asideText = SpeechTextNormalizer.normalize("\(spokenLead) \(anchor.text)")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let citation = spoken(atOrAfter: anchor.citationRange.lowerBound)
            var cut = min(sentenceEnd(from: citation, in: characters),
                          spoken(atOrAfter: paragraphEnd(after: anchor.citationRange.upperBound, in: source)))
            cut = max(cut, citation)
            if let inside = definitions.first(where: { $0.range.lowerBound < cut && cut < $0.range.upperBound }) {
                cut = inside.range.lowerBound
            }
            asidesByCut[cut, default: []].append(
                (anchor.label, RenderedSpeechChunker.sourceSlices(from: asideText, maxCharacters: budget)))
        }

        var boundaries = Set(asidesByCut.keys)
        for definition in definitions {
            boundaries.insert(definition.range.lowerBound)
            boundaries.insert(definition.range.upperBound)
        }
        let edges = [0] + boundaries.filter { $0 > 0 && $0 < length }.sorted() + [length]

        var chunks: [Chunk] = []
        func appendAsides(at cut: Int) {
            // The anchors come in citation order, so the notes of one sentence are read in the order they are cited.
            for aside in asidesByCut[cut] ?? [] {
                for planned in aside.chunks {
                    chunks.append(Chunk(index: chunks.count, startOffset: cut, sourceLength: 0, text: planned.slice.text,
                                        boundary: planned.slice.boundary, footnote: .aside(aside.label)))
                }
            }
        }
        appendAsides(at: 0)
        // Whitespace the chunker leaves uncovered between pieces, waiting for the chunk that will start it.
        var carriedFrom: Int?
        for (from, to) in zip(edges, edges.dropFirst()) where from < to {
            let tag = definitions.first(where: { $0.range.contains(from) }).map { FootnoteTag.definition($0.label) }
            let first = chunks.count
            for planned in RenderedSpeechChunker.sourceSlices(from: String(characters[from..<to]), maxCharacters: budget) {
                chunks.append(Chunk(index: chunks.count, startOffset: from + planned.startOffset,
                                    sourceLength: planned.slice.sourceLength, text: planned.slice.text,
                                    boundary: planned.slice.boundary, footnote: tag))
            }
            if chunks.count == first {
                // A piece of only whitespace (a cut, a space, then a definition). It goes to the chunk after any aside
                // at this cut, never to the chunk before: that one would then cross the aside's offset.
                carriedFrom = carriedFrom ?? from
            } else {
                if let start = carriedFrom {
                    chunks[first].sourceLength += chunks[first].startOffset - start
                    chunks[first].startOffset = start
                    carriedFrom = nil
                }
                // The chunker leaves a piece's own trailing whitespace uncovered. Inside the text that made the next
                // chunk start late, off the plan, so the piece's last chunk takes it, up to the piece's end and no
                // further. The end of the text stays as it is without asides.
                if to < length, chunks[chunks.count - 1].startOffset + chunks[chunks.count - 1].sourceLength < to {
                    chunks[chunks.count - 1].sourceLength = to - chunks[chunks.count - 1].startOffset
                }
            }
            appendAsides(at: to)
        }
        return ArticlePlan(identity: identity(ofArticle: articleText, asides: true), normalizedText: normalized.text, chunks: chunks)
    }

    /// What the narrator says before a note: "Note 3." for the labels `3` and `a`, and for `note-3`; "Note." for a label
    /// with no number or letter to say, so a long label is never spelled out.
    fileprivate static func asideLead(forLabel label: String) -> String {
        if label.count == 1 || label.allSatisfy(\.isNumber) { return "Note \(label)." }
        let digits = String(label.reversed().prefix(while: \.isNumber).reversed())
        if !digits.isEmpty, label.dropLast(digits.count).allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }) {
            return "Note \(digits)."
        }
        return "Note."
    }

    private static let sentenceEnders: Set<Character> = [".", "!", "?"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]

    /// Where the sentence that holds a citation ends in the spoken text, as an offset (the first character of the next
    /// sentence or of the space before it). `citation` is where the silent marker sat. A marker written right after
    /// the sentence's full stop, the usual place, belongs to the sentence before it. Otherwise the sentence ends at the
    /// next full stop, question mark or exclamation mark that a space or the end follows. Digits like `3.5` and
    /// closing quotes or brackets after the stop are handled; an abbreviation's dot is not told apart.
    fileprivate static func sentenceEnd(from citation: Int, in characters: [Character]) -> Int {
        var back = citation - 1
        while back >= 0, characters[back] == " " || closers.contains(characters[back]) { back -= 1 }
        if back >= 0, sentenceEnders.contains(characters[back]) { return citation }
        var index = citation
        while index < characters.count {
            if sentenceEnders.contains(characters[index]) {
                var end = index + 1
                while end < characters.count, sentenceEnders.contains(characters[end]) || closers.contains(characters[end]) { end += 1 }
                if end >= characters.count || characters[end] == " " { return end }
                index = end
            } else {
                index += 1
            }
        }
        return characters.count
    }

    /// The source offset where the paragraph that holds `offset` ends: the end of its line when the line is a heading,
    /// a list item or a quote, else a line break followed by a blank line, by a heading, list item or quote, or by the
    /// start of a footnote definition line, or the end of the text. An aside never crosses it, so a citing sentence
    /// with no full stop does not carry its note into the next block, a heading or the notes.
    fileprivate static func paragraphEnd(after offset: Int, in source: [Character]) -> Int {
        func startsBlock(at start: Int) -> Bool {
            var index = start
            while index < source.count, source[index] == " " || source[index] == "\t" { index += 1 }
            guard index < source.count, !source[index].isNewline else { return false }
            let first = source[index]
            let second: Character? = index + 1 < source.count ? source[index + 1] : nil
            if first == "#" || first == ">" { return true }
            if first == "[", second == "^" { return true }
            if "-*+".contains(first), second == " " { return true }
            if first.isNumber {
                var digits = index
                while digits < source.count, source[digits].isNumber { digits += 1 }
                return digits < source.count - 1 && (source[digits] == "." || source[digits] == ")") && source[digits + 1] == " "
            }
            return false
        }
        var lineStart = max(0, min(offset, source.count))
        while lineStart > 0, !source[lineStart - 1].isNewline { lineStart -= 1 }
        let ownLineIsBlock = startsBlock(at: lineStart) && !(source[lineStart...].first(where: { $0 != " " && $0 != "\t" }) == "[")
        var index = max(0, offset)
        while index < source.count {
            if source[index].isNewline {
                if ownLineIsBlock { return index }
                var next = index + 1
                while next < source.count, source[next] == " " || source[next] == "\t" { next += 1 }
                if next >= source.count || source[next].isNewline { return index }
                if startsBlock(at: index + 1) { return index }
            }
            index += 1
        }
        return source.count
    }
}
