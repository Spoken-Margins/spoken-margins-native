import Foundation

/// The result of lining up a publisher's recording with its article (#546, slice 2 of #239).
public enum PublisherAudioAlignment: Equatable, Sendable {
    /// Enough sentences were found in the recording; the map's segments are article sentences.
    case aligned(TranscriptTimeline, placedSentences: Int, totalSentences: Int)
    /// Some sentences were found, but too few to trust the map.
    case tooFewPlaced(placedSentences: Int, totalSentences: Int)
    /// The recording doesn't read this article.
    case noMatch(placedSentences: Int, totalSentences: Int)

    public var timeline: TranscriptTimeline? {
        if case .aligned(let timeline, _, _) = self { return timeline }
        return nil
    }

    /// A short reason for diagnostics and the stored record.
    public var status: String {
        switch self {
        case .aligned(_, let placed, let total):
            return "aligned(\(placed) of \(total) sentences)"
        case .tooFewPlaced(let placed, let total):
            return "too_few_sentences_placed(\(placed) of \(total), needs \(Int(PublisherAudioAligner.minimumPlacedFraction * 100))%)"
        case .noMatch(let placed, let total):
            return "no_match(\(placed) of \(total) sentences)"
        }
    }
}

/// Lines up an article's text with the on-device transcript of the publisher's recording of it.
///
/// The transcriber's timeline carries its own recognised words, and its character offsets point
/// into that transcript, not the article. This finds the article's words in the recognised ones
/// and returns a map whose segments are article sentences, each with `startChar`/`endChar` into
/// `articleText` (in `Character`s, like `Item.text` offsets) and times from the recording.
///
/// Words are matched in two passes. First, word triples that occur exactly once in the article
/// and once in the transcript, kept only where they run in the same order (a longest increasing
/// subsequence), so repeated phrases can't pull the map back or forward. Then the short stretches
/// between those anchors are matched word by word, and a sentence is placed only when most of its
/// words matched, so a skipped paragraph, a spoken intro or ad, or a different article isn't
/// placed on common words like "the" and "and".
public enum PublisherAudioAligner {
    /// The share of sentences that must be placed for the map to be kept (#546).
    public static let minimumPlacedFraction = 0.8
    /// Below this share the recording is taken to be of something else.
    public static let noMatchFraction = 0.25
    /// A sentence is placed when at least this share of its words is matched.
    static let sentenceMatchFraction = 0.5
    /// Stretches between anchors longer than this, on either side, are left unmatched. Real gaps
    /// between anchors are a few misheard words; this keeps the word-by-word pass cheap.
    static let maximumGapWords = 80

    public static func align(articleText: String, recognised: TranscriptTimeline) -> PublisherAudioAlignment {
        let article = Array(articleText)
        let articleWords = words(in: article)
        let sentences = self.sentences(in: article, words: articleWords)
        guard !sentences.isEmpty else { return .noMatch(placedSentences: 0, totalSentences: 0) }
        let spoken = recognisedWords(in: recognised)
        let matches = match(articleWords.map(\.normalized), spoken.map(\.normalized))

        var segments: [MediaTimelineSegment] = []
        var previousEndMs = 0
        for (index, sentence) in sentences.enumerated() {
            let wordRange = sentence.wordRange
            let matched = wordRange.compactMap { word in matches[word].map { (word, $0) } }
            let needed = max(1, Int((Double(wordRange.count) * sentenceMatchFraction).rounded(.up)))
            guard let first = matched.first, let last = matched.last, matched.count >= needed else { continue }

            // Unmatched words at either end of the sentence are usually misrecognised, so take the
            // recognised words that sit in their place, without crossing into another match.
            let leading = first.0 - wordRange.lowerBound
            let previousMatch = wordRange.lowerBound > 0
                ? (0..<wordRange.lowerBound).reversed().lazy.compactMap { matches[$0] }.first ?? -1
                : -1
            let startWord = max(previousMatch + 1, first.1 - leading)
            let trailing = wordRange.upperBound - 1 - last.0
            let nextMatch = (wordRange.upperBound..<articleWords.count).lazy.compactMap { matches[$0] }.first ?? spoken.count
            let endWord = min(nextMatch - 1, last.1 + trailing)

            let startMs = max(previousEndMs, spoken[min(startWord, first.1)].startMs)
            let endMs = max(startMs + 1, spoken[max(endWord, last.1)].endMs)
            previousEndMs = endMs
            segments.append(MediaTimelineSegment(
                id: "publisher-audio-\(String(format: "%04d", index + 1))",
                startMs: startMs,
                endMs: endMs,
                startChar: sentence.startChar,
                endChar: sentence.endChar,
                text: String(article[sentence.startChar..<sentence.endChar])
            ))
        }

        let placed = segments.count
        let fraction = Double(placed) / Double(sentences.count)
        if fraction < noMatchFraction {
            return .noMatch(placedSentences: placed, totalSentences: sentences.count)
        }
        if fraction < minimumPlacedFraction {
            return .tooFewPlaced(placedSentences: placed, totalSentences: sentences.count)
        }
        let durationMs = recognised.durationMs ?? recognised.segments.map(\.endMs).max()
        return .aligned(
            TranscriptTimeline(segments: segments, chapters: [], durationMs: durationMs),
            placedSentences: placed,
            totalSentences: sentences.count
        )
    }

    // MARK: - Words and sentences

    struct ArticleWord: Equatable {
        var normalized: String
        var startChar: Int
        var endChar: Int
    }

    struct SpokenWord: Equatable {
        var normalized: String
        var startMs: Int
        var endMs: Int
    }

    struct Sentence: Equatable {
        var startChar: Int
        var endChar: Int
        var wordRange: Range<Int>
    }

    static func words(in characters: [Character]) -> [ArticleWord] {
        var result: [ArticleWord] = []
        var start: Int?
        var current = ""
        for (index, character) in characters.enumerated() {
            if isWordCharacter(character) {
                if start == nil { start = index }
                current += normalize(character)
            } else if character == "'" || character == "\u{2019}", start != nil,
                      index + 1 < characters.count, isWordCharacter(characters[index + 1]) {
                continue // "don't" is one word
            } else if let wordStart = start {
                if !current.isEmpty { result.append(ArticleWord(normalized: current, startChar: wordStart, endChar: index)) }
                start = nil
                current = ""
            }
        }
        if let wordStart = start, !current.isEmpty {
            result.append(ArticleWord(normalized: current, startChar: wordStart, endChar: characters.count))
        }
        return result
    }

    /// Sentences end at `.`, `!` or `?` (and any closing quotes or brackets) before a space, and at
    /// line breaks. Each keeps its own range of article characters, trimmed of spaces.
    static func sentences(in characters: [Character], words: [ArticleWord]) -> [Sentence] {
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isNewline {
                ranges.append(start..<index)
                start = index + 1
            } else if [".", "!", "?", "\u{2026}"].contains(character) {
                var end = index + 1
                while end < characters.count, ["\"", "'", ")", "]", "\u{201D}", "\u{2019}", ".", "!", "?"].contains(characters[end]) {
                    end += 1
                }
                if end == characters.count || characters[end].isWhitespace {
                    ranges.append(start..<end)
                    start = end
                    index = end
                    continue
                }
            }
            index += 1
        }
        if start < characters.count { ranges.append(start..<characters.count) }

        var result: [Sentence] = []
        var wordIndex = 0
        for range in ranges {
            var lower = range.lowerBound
            var upper = range.upperBound
            while lower < upper, characters[lower].isWhitespace { lower += 1 }
            while upper > lower, characters[upper - 1].isWhitespace { upper -= 1 }
            while wordIndex < words.count, words[wordIndex].startChar < lower { wordIndex += 1 }
            let firstWord = wordIndex
            while wordIndex < words.count, words[wordIndex].endChar <= upper { wordIndex += 1 }
            guard wordIndex > firstWord else { continue }
            result.append(Sentence(startChar: lower, endChar: upper, wordRange: firstWord..<wordIndex))
        }
        return result
    }

    /// The transcript's words, each with a share of its segment's time in proportion to its length.
    static func recognisedWords(in timeline: TranscriptTimeline) -> [SpokenWord] {
        var result: [SpokenWord] = []
        for segment in timeline.segments.sorted(by: { $0.startMs < $1.startMs }) {
            let segmentWords = words(in: Array(segment.text)).map(\.normalized)
            guard !segmentWords.isEmpty else { continue }
            let weights = segmentWords.map { Double($0.count + 1) }
            let total = weights.reduce(0, +)
            let span = Double(max(0, segment.endMs - segment.startMs))
            var elapsed = 0.0
            for (word, weight) in zip(segmentWords, weights) {
                let startMs = segment.startMs + Int((span * elapsed / total).rounded())
                elapsed += weight
                let endMs = segment.startMs + Int((span * elapsed / total).rounded())
                result.append(SpokenWord(normalized: word, startMs: startMs, endMs: max(startMs, endMs)))
            }
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func normalize(_ character: Character) -> String {
        String(character).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Matching

    /// For each article word, the index of the recognised word it matched, or nil.
    /// Matched indices only go up.
    static func match(_ article: [String], _ spoken: [String]) -> [Int?] {
        var matches = [Int?](repeating: nil, count: article.count)
        let anchors = orderedAnchors(article, spoken, size: 3)

        // Each anchor matches three words; consecutive anchors often overlap.
        var lastArticle = -1
        var lastSpoken = -1
        var pairs: [(Int, Int)] = []
        for (a, s) in anchors {
            for offset in 0..<3 where a + offset > lastArticle && s + offset > lastSpoken {
                pairs.append((a + offset, s + offset))
                lastArticle = a + offset
                lastSpoken = s + offset
            }
        }

        var previous = (-1, -1)
        for pair in pairs + [(article.count, spoken.count)] {
            fillGap(article, spoken, from: previous, to: pair, into: &matches)
            if pair.0 < article.count { matches[pair.0] = pair.1 }
            previous = pair
        }
        return matches
    }

    /// Word triples found exactly once on each side, in an order both sides agree on.
    private static func orderedAnchors(_ article: [String], _ spoken: [String], size: Int) -> [(Int, Int)] {
        func uniqueGrams(_ words: [String]) -> [String: Int] {
            guard words.count >= size else { return [:] }
            var positions: [String: Int] = [:]
            var repeated = Set<String>()
            for start in 0...(words.count - size) {
                let gram = words[start..<(start + size)].joined(separator: " ")
                if positions[gram] != nil { repeated.insert(gram) } else { positions[gram] = start }
            }
            for gram in repeated { positions[gram] = nil }
            return positions
        }
        let spokenGrams = uniqueGrams(spoken)
        let candidates = uniqueGrams(article)
            .compactMap { gram, a in spokenGrams[gram].map { (a, $0) } }
            .sorted { $0.0 < $1.0 }
        return longestIncreasingRun(candidates)
    }

    /// The longest chain of pairs whose second index also increases (patience sorting).
    private static func longestIncreasingRun(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = [] // index into pairs of the smallest tail for each length
        var parent = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tails[mid]].1 < pair.1 { low = mid + 1 } else { high = mid }
            }
            if low > 0 { parent[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var chain: [(Int, Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            chain.append(pairs[cursor])
            cursor = parent[cursor]
        }
        return chain.reversed()
    }

    /// Matches the words strictly between two matched pairs by longest common subsequence, when
    /// both stretches are short.
    private static func fillGap(
        _ article: [String],
        _ spoken: [String],
        from start: (Int, Int),
        to end: (Int, Int),
        into matches: inout [Int?]
    ) {
        let articleRange = (start.0 + 1)..<end.0
        let spokenRange = (start.1 + 1)..<end.1
        guard !articleRange.isEmpty, !spokenRange.isEmpty,
              articleRange.count <= maximumGapWords, spokenRange.count <= maximumGapWords else { return }
        let a = Array(article[articleRange])
        let s = Array(spoken[spokenRange])
        var table = [[Int]](repeating: [Int](repeating: 0, count: s.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: s.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == s[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < a.count, j < s.count {
            if a[i] == s[j] {
                matches[articleRange.lowerBound + i] = spokenRange.lowerBound + j
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
    }
}
