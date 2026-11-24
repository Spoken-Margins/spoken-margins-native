import Foundation

/// A tidier version of a spoken Margin's transcript, and the check that keeps a rewrite honest (#4339).
///
/// `MarginTidy.fillerOnly` is the version every iPhone can offer with no model: it removes fillers, an immediately
/// repeated word and a spoken run-up at the very start, and puts the spacing and capital letters right. It never
/// removes "like", "actually", "just" or "right": they carry meaning too often. It only removes, so it is not run through
/// `MarginTidyGuard`, which is what a model's rewrite must pass before the author is shown it. Pure functions over strings:
/// no screen or store uses them yet.
public enum MarginTidy {
    /// `text` with the fillers, an immediately repeated word and a spoken run-up taken out; the same text when there
    /// is nothing to take out or nothing would be left.
    ///
    /// Words inside a quotation are left as they were said. Text in another language is left alone: a word from the
    /// common function words of German, Dutch, French, Spanish or Portuguese rules the text out, and "um" and "er", which
    /// are real words there ("he", "at"), only count as fillers when the text also has an English function word.
    public static func fillerOnly(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(Token.init)
        // A lone punctuation mark ("um , the") belongs to the word before it.
        var merged: [Token] = []
        for token in tokens {
            if token.core.isEmpty, token.text.allSatisfy(\.isPunctuation), var last = merged.last, !last.core.isEmpty {
                last.trailing += token.leading
                merged[merged.count - 1] = last
            } else {
                merged.append(token)
            }
        }
        tokens = merged
        guard tokens.contains(where: { !$0.core.isEmpty }), !looksForeign(tokens) else { return text }
        // Nothing but fillers: there is nothing to say once they are gone, so the text is left as it was.
        guard tokens.contains(where: { !DeterministicInterjectionCleanup.unambiguousFillers.contains($0.core.lowercased())
            && !["um", "er"].contains($0.core.lowercased()) }) else { return text }
        let hasEnglishEvidence = hasEnglishFunctionWord(tokens)
        let protected = quotedIndices(tokens)
        var removed = Set<Int>()

        /// Takes out `range`; its sentence-ending marks move to `previous`, the word before it.
        func remove(_ range: ClosedRange<Int>, after previous: Int?) {
            if let previous {
                // A filler set off by commas on both sides takes the pair with it: "the result, um, was" -> "the result was".
                let lastRemoved = tokens[range.upperBound].trailing
                if lastRemoved.contains(where: { ",;:".contains($0) }), tokens[previous].trailing.contains(where: { ",;:".contains($0) }),
                   !tokens[previous].trailing.contains(where: { ".!?".contains($0) }) {
                    tokens[previous].trailing = tokens[previous].trailing.filter { !",;:".contains($0) }
                }
                let ending = String(tokens[range.upperBound].trailing.filter { ".!?".contains($0) })
                if !ending.isEmpty, !tokens[previous].trailing.contains(where: { ".!?".contains($0) }) {
                    tokens[previous].trailing = tokens[previous].trailing.filter { !",;:".contains($0) } + ending
                }
            }
            removed.formUnion(range)
        }

        // Fillers. "um" and "er" are words in other languages, so they need English around them.
        var previous: Int?
        for index in tokens.indices {
            let word = tokens[index].core.lowercased()
            let isFiller = DeterministicInterjectionCleanup.unambiguousFillers.contains(word)
                && (hasEnglishEvidence || !["um", "er"].contains(word)) && !protected.contains(index)
            if isFiller { remove(index...index, after: previous) } else { previous = index }
        }

        // An isolated "you know": set off by punctuation, or the ends of the text, on both sides. "You know?" is a question.
        let remaining = tokens.indices.filter { !removed.contains($0) }
        var stack: [Int] = []
        var position = 0
        while position < remaining.count {
            let you = remaining[position]
            if position + 1 < remaining.count {
                let know = remaining[position + 1]
                let opens = stack.isEmpty || tokens[stack[stack.count - 1]].trailing.contains(where: { ",.!?;:".contains($0) })
                let closes = position + 2 == remaining.count || tokens[know].trailing.contains(where: { ",.!;:".contains($0) })
                if tokens[you].core.lowercased() == "you", tokens[know].core.lowercased() == "know",
                   tokens[you].leading.isEmpty, tokens[know].leading.isEmpty, opens, closes,
                   !protected.contains(you), !protected.contains(know) {
                    remove(you...know, after: stack.last)
                    position += 2
                    continue
                }
            }
            stack.append(you)
            position += 1
        }

        // An immediately repeated word: nothing between the two but a space.
        let afterFillers = tokens.indices.filter { !removed.contains($0) }
        var last: Int?
        for index in afterFillers {
            if let first = last, tokens[first].trailing.isEmpty, tokens[index].leading.isEmpty,
               !protected.contains(first), !protected.contains(index),
               tokens[index].core.rangeOfCharacter(from: .letters) != nil,
               tokens[first].core.lowercased() == tokens[index].core.lowercased(),
               !["had", "that", "so"].contains(tokens[index].core.lowercased()),
               !isRepeatedName(tokens, first: first, second: index) {
                tokens[first].trailing = tokens[index].trailing
                removed.insert(index)
                continue
            }
            last = index
        }

        // A spoken run-up at the very start.
        let order = tokens.indices.filter { !removed.contains($0) }
        if order.count > 1, !protected.contains(order[0]) {
            let first = tokens[order[0]]
            let lowered = first.core.lowercased()
            let plainOrComma = first.leading.isEmpty && (first.trailing.isEmpty || first.trailing == ",")
            let second = tokens[order[1]]
            // "So" is a run-up only before a word that starts a new thought, or after a comma: "So true" and "So do I" are said content.
            func runUp(_ token: Token, followedBy next: Token?) -> Bool {
                token.trailing == "," || next.map { startsAThought.contains($0.core.lowercased()) } == true
            }
            if lowered == "so", plainOrComma, runUp(first, followedBy: second) {
                removed.insert(order[0])
            } else if ["okay", "ok"].contains(lowered), plainOrComma, order.count > 2, second.core.lowercased() == "so",
                      second.leading.isEmpty, second.trailing.isEmpty || second.trailing == ",",
                      runUp(second, followedBy: tokens[order[2]]) {
                removed.formUnion([order[0], order[1]])
            } else if lowered == "well", first.leading.isEmpty, first.trailing == "," {
                removed.insert(order[0])
            }
        }

        let kept = tokens.indices.filter { !removed.contains($0) }
        guard !removed.isEmpty, kept.contains(where: { !tokens[$0].core.isEmpty }) else { return text }
        // A word that now follows a removal at the start of the text, or after a sentence end, takes a capital letter.
        var pieces: [String] = []
        var gap = false
        var before: Int?
        for index in tokens.indices {
            if removed.contains(index) { gap = true; continue }
            var token = tokens[index]
            let startsSentence = before.map { endsSentence(tokens[$0]) } ?? true
            if gap, startsSentence { token.core = capitalizingFirstLetter(token.core) }
            gap = false
            before = index
            pieces.append(token.text)
        }
        var result = pieces.joined(separator: " ")
        // The comma that opened the text, or ends it, is left over from a removed word.
        while let first = result.first, ",;:".contains(first) { result.removeFirst() }
        while let end = result.last, ",;:".contains(end) { result.removeLast() }
        return result
    }

    // MARK: Tokens

    /// A whitespace-separated piece: punctuation in front, the word, punctuation behind.
    private struct Token {
        var leading: String
        var core: String
        var trailing: String
        var text: String { leading + core + trailing }

        init(_ piece: Substring) {
            let characters = Array(piece)
            let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
            var start = 0
            while start < characters.count, !isWordCharacter(characters[start]) { start += 1 }
            var end = characters.count
            while end > start, !isWordCharacter(characters[end - 1]) { end -= 1 }
            leading = String(characters[..<start])
            core = String(characters[start..<end])
            trailing = String(characters[end...])
            if core.isEmpty { leading = String(piece); trailing = "" }
        }
    }

    /// A full stop, question or exclamation mark ends a sentence; an ellipsis does not.
    private static func endsSentence(_ token: Token) -> Bool {
        guard let last = token.trailing.last(where: { !"\"'”’)]".contains($0) }), ".!?".contains(last) else { return false }
        return !token.trailing.contains("..") && !token.trailing.contains("…")
    }

    /// The tokens inside a quotation: from one that opens with a quote mark to one that closes with it.
    private static func quotedIndices(_ tokens: [Token]) -> Set<Int> {
        var inside = Set<Int>()
        var open = false
        for (index, token) in tokens.enumerated() {
            let opens = token.leading.contains(where: { "\"“‘".contains($0) })
            let closes = token.trailing.contains(where: { "\"”’".contains($0) })
            if opens { open = true }
            if open { inside.insert(index) }
            if closes { open = false }
        }
        return inside
    }

    /// "Bora Bora", "Duran Duran": two capitalised copies that are not the start of a sentence are a name, not a stutter.
    private static func isRepeatedName(_ tokens: [Token], first: Int, second: Int) -> Bool {
        guard tokens[first].core != "I", tokens[first].core.first?.isUppercase == true, tokens[second].core.first?.isUppercase == true else { return false }
        let previous = (0..<first).last { !tokens[$0].core.isEmpty }
        return previous.map { !endsSentence(tokens[$0]) } ?? false
    }

    /// Only a word with plain lower-case letters is capitalised: "iOS", "eBay" and "ß" are left as they are.
    private static func capitalizingFirstLetter(_ value: String) -> String {
        guard let first = value.first, first.isLowercase, value.dropFirst().allSatisfy({ !$0.isUppercase }) else { return value }
        let upper = first.uppercased()
        return upper.count == 1 ? upper + String(value.dropFirst()) : value
    }

    /// Words that open a new thought after "so": "so I think", "so the result".
    private static let startsAThought: Set<String> = [
        "the", "a", "an", "i", "we", "they", "you", "he", "she", "it", "this", "that", "there", "these", "those", "my", "our",
        "their", "his", "her", "what", "how", "when", "if", "in", "on", "at", "and", "but", "then", "as", "for", "basically",
        "anyway", "yeah", "yes", "okay", "ok", "first", "now", "um", "uh",
    ]

    /// Whether `text` reads as another language by the same test `fillerOnly` uses to leave it alone.
    static func isForeign(_ text: String) -> Bool {
        looksForeign(text.split(whereSeparator: \.isWhitespace).map(Token.init))
    }

    /// Whether `text` has an English function word.
    static func isEnglish(_ text: String) -> Bool {
        hasEnglishFunctionWord(text.split(whereSeparator: \.isWhitespace).map(Token.init))
    }

    /// Whether a common function word of another language rules the text out, or most of its letters are not Latin.
    private static func looksForeign(_ tokens: [Token]) -> Bool {
        let words = tokens.map { $0.core.lowercased() }
        if words.contains(where: { foreignFunctionWords.contains($0) }) { return true }
        let letters = tokens.flatMap { $0.core }.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        let notLatin = letters.filter { !$0.isASCII && !"áàâäãåçéèêëíìîïñóòôöõúùûüýÿœæ".contains($0.lowercased()) }.count
        return Double(notLatin) / Double(letters.count) > 0.2
    }

    /// Whether there is at least one English function word ("a" alone does not count: it is a word in other languages).
    private static func hasEnglishFunctionWord(_ tokens: [Token]) -> Bool {
        tokens.contains { englishFunctionWords.contains($0.core.lowercased()) }
    }

    private static let englishFunctionWords: Set<String> = [
        "the", "an", "and", "of", "to", "in", "is", "was", "it", "that", "this", "i", "we", "not", "for", "on", "with", "as",
        "are", "be", "but", "have", "has", "they", "you", "so", "there", "what", "from", "by", "at", "or", "if", "my", "would",
        "can", "do", "just", "about", "he", "she", "his", "her", "were", "which", "when", "then", "because", "like", "think",
    ]

    /// Common function words that are not English words, from the languages most likely to be spoken into a Margin.
    private static let foreignFunctionWords: Set<String> = [
        "ist", "und", "der", "das", "nicht", "ich", "ein", "eine", "einen", "mit", "auf", "dass", "wir", "sie", "auch", "aber",
        "het", "een", "niet", "ik", "zijn", "dat", "je", "ook", "maar", "wat",
        "est", "une", "les", "des", "que", "qui", "dans", "pour", "avec", "c'était", "pas",
        "el", "los", "las", "una", "por", "muy", "pero", "esto", "está",
        "não", "uma", "são", "então", "isso", "é", "ele", "ela", "foi",
    ]
}

/// What a proposed tidy version must pass before its author is shown it (#4339). It catches a rewrite that lost or
/// invented meaning: a number, a name, a quotation or a negation gone, a text much shorter or longer than what was said,
/// or a long stretch lifted from the passage the Margin sits on. Pure: the filler-only tidy passes it by construction, and
/// a model's rewrite that fails it is dropped for the filler-only one.
public enum MarginTidyGuard {
    public enum Rejection: Equatable, Sendable {
        case emptyOriginal
        case emptyProposal
        case numberMissing(String)
        case nameMissing(String)
        case quotationMissing(String)
        case negationDropped
        /// A capitalised word, not first in its sentence, that the speaker never said: a name the model brought in,
        /// usually from the passage ("the colonel" becoming "Colonel Varga").
        case nameAdded(String)
        /// The Margin was said in another language and the proposal is in English.
        case languageChanged
        case tooShort
        case tooLong
        case copiedFromPassage
    }

    /// Words of 40% to 110% of the original's.
    static let lengthRange = 0.4...1.1
    /// A run this long that is in the passage and not in the original was lifted from the passage.
    static let copiedRunLength = 8

    public static func accepts(original: String, proposal: String, passage: String = "") -> Bool {
        rejection(original: original, proposal: proposal, passage: passage) == nil
    }

    /// The first rule the proposal breaks, or nil.
    public static func rejection(original: String, proposal: String, passage: String = "") -> Rejection? {
        let originalWords = words(original)
        let proposalWords = words(proposal)
        guard !originalWords.isEmpty else { return .emptyOriginal }
        guard !proposalWords.isEmpty else { return .emptyProposal }

        // Every number, spelled as digits or as the words for small numbers, hundreds, thousands and percent.
        // A hyphenated number ("twenty-five") counts as its parts.
        let proposalLowered = Set(proposalWords.flatMap { $0.lowercased().split(separator: "-").map(String.init) })
        let proposalNumbers = Set(numbers(in: proposal))
        for number in numbers(in: original) where !proposalNumbers.contains(number) { return .numberMissing(number) }
        // "one" after "the", "this", "no" and the like is a pronoun ("the one by Chen"), not a count.
        let originalLowered = originalWords.map { $0.lowercased() }
        for (index, whole) in originalLowered.enumerated() {
            for word in whole.split(separator: "-").map(String.init) where numberWords.contains(word) && !proposalLowered.contains(word) {
                if word == "one", whole == "one", index > 0, pronounOneLeaders.contains(originalLowered[index - 1]) { continue }
                return .numberMissing(word)
            }
        }

        // Every capitalised word that is not the first of a sentence.
        // "Sarah's" and "Sarah" are the same name, and "Jean-Luc" is kept when either part is.
        let proposalNames = Set(proposalWords.flatMap(nameStems))
        for name in capitalisedMidSentenceWords(in: original) where !nameStems(name).contains(where: proposalNames.contains) {
            return .nameMissing(name)
        }

        // Every quoted span, verbatim.
        // (Any quote style will do for the proposal's marks; the words between them must be the same.)
        let proposalSpans = Set(quotedSpans(in: proposal))
        for span in quotedSpans(in: original) where !proposalSpans.contains(span) { return .quotationMissing(span) }

        // As many negations as were said, or more. A false start said twice ("it's not, it's not the whole story",
        // "no no no") counts once: tidying it away is the point.
        if negationCount(in: proposalWords) < negationCount(in: withoutRepeatedRuns(originalWords)) { return .negationDropped }

        // No name the speaker did not say.
        let originalLowerSet = Set(originalWords.flatMap { word in
            [word.lowercased()] + word.lowercased().split(separator: "-").map(String.init) + nameStems(word).map { $0.lowercased() }
        })
        for name in capitalisedMidSentenceWords(in: proposal) {
            let stems = nameStems(name).map { $0.lowercased() } + [name.lowercased()]
            if !stems.contains(where: originalLowerSet.contains) { return .nameAdded(name) }
        }

        // Said in another language, answered in English.
        if MarginTidy.isForeign(original), !MarginTidy.isForeign(proposal), MarginTidy.isEnglish(proposal) { return .languageChanged }

        let ratio = Double(spokenWordCount(proposalWords)) / Double(spokenWordCount(originalWords))
        if ratio < lengthRange.lowerBound { return .tooShort }
        if ratio > lengthRange.upperBound { return .tooLong }

        // No stretch taken from the passage that the speaker did not say.
        if !passage.isEmpty {
            // What the speaker said, with and without the fillers a tidy takes out: removing "uh" joins words into new runs.
            let originalRuns = runs(normalized(originalWords)).union(runs(normalized(words(MarginTidy.fillerOnly(original)))))
            let passageRuns = runs(normalized(words(passage)))
            let normalizedProposal = normalized(proposalWords)
            if normalizedProposal.count >= copiedRunLength {
                for start in 0...(normalizedProposal.count - copiedRunLength) {
                    let run = normalizedProposal[start..<start + copiedRunLength].joined(separator: " ")
                    if passageRuns.contains(run), !originalRuns.contains(run) { return .copiedFromPassage }
                }
            }
        }
        return nil
    }

    // MARK: Pieces

    /// The name without a possessive, and its hyphenated parts: "Sarah's" -> ["Sarah"], "Jean-Luc" -> ["Jean", "Luc"].
    private static func nameStems(_ word: String) -> [String] {
        var base = word
        for suffix in ["'s", "'"] where base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)); break }
        return base.split(separator: "-").map(String.init).filter { !$0.isEmpty }
    }

    /// Words as spoken: a hyphenated word is its parts, a contraction is two ("can't", "we're"), so "it is" and "it's" weigh the same in the length check.
    private static func spokenWordCount(_ words: [String]) -> Int {
        words.reduce(0) { total, word in
            let lowered = word.lowercased()
            let contracted = ["n't", "'re", "'ve", "'ll", "'m", "'d"].contains { lowered.hasSuffix($0) }
            // "twenty-five" and "twenty five" weigh the same.
            return total + max(lowered.split(separator: "-").count, 1) + (contracted ? 1 : 0)
        }
    }

    /// Whitespace-separated words with the punctuation around them trimmed (inner apostrophes and hyphens stay;
    /// a curly apostrophe becomes a straight one).
    private static func words(_ text: String) -> [String] {
        text.replacingOccurrences(of: "’", with: "'").split(whereSeparator: \.isWhitespace).map { piece in
            piece.trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'’")))
                .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        }.filter { !$0.isEmpty }
    }

    /// Lowercased words without punctuation, for comparing runs.
    private static func normalized(_ words: [String]) -> [String] {
        words.map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
    }

    private static func runs(_ words: [String]) -> Set<String> {
        guard words.count >= copiedRunLength else { return [] }
        return Set((0...(words.count - copiedRunLength)).map { words[$0..<$0 + copiedRunLength].joined(separator: " ") })
    }

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "hundred", "thousand", "percent",
    ]

    /// Digit runs, with a decimal or thousands separator kept inside: "12", "3.5", "1,200".
    private static func numbers(in text: String) -> [String] {
        var result: [String] = [], current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isNumber && character.isASCII {
                current.append(character)
            } else if ".,".contains(character), !current.isEmpty, index + 1 < characters.count, characters[index + 1].isNumber, characters[index + 1].isASCII {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func capitalisedMidSentenceWords(in text: String) -> [String] {
        var names: [String] = [], startOfSentence = true
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let word = words(String(piece)).first ?? ""
            if !word.isEmpty, !startOfSentence, word.first?.isUppercase == true, word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’") {
                names.append(word)
            }
            if !word.isEmpty { startOfSentence = false }
            if let last = piece.last(where: { !"\"'”’)]”".contains($0) }), ".!?".contains(last) { startOfSentence = true }
        }
        return names
    }

    private static func quotedSpans(in text: String) -> [String] {
        let patterns = ["\"([^\"]+)\"", "“([^”]+)”", "(?<![A-Za-z0-9])'([^']+)'(?![A-Za-z0-9])", "(?<![A-Za-z0-9])‘([^’]+)’(?![A-Za-z0-9])"]
        var spans: [String] = []
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, range: range) where match.numberOfRanges > 1 {
                if let inner = Range(match.range(at: 1), in: text) { let span = normalizedSpan(String(text[inner])); if !span.isEmpty { spans.append(span) } }
            }
        }
        return spans
    }

    /// A quoted span compared by its words: punctuation at the ends ("no way,") and the apostrophe style do not matter.
    private static func normalizedSpan(_ span: String) -> String {
        span.replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.whitespacesAndNewlines))
            .lowercased()
    }

    private static let negations: Set<String> = [
        "not", "no", "never", "nothing", "none", "neither", "nor", "without", "cannot", "nobody", "nowhere",
    ]

    /// Words before a "one" that make it a pronoun rather than a number.
    private static let pronounOneLeaders: Set<String> = ["the", "this", "that", "which", "each", "every", "any", "no", "another"]

    /// `words` with a run of one to six words said again straight away dropped to one copy, comparing lowercased words
    /// without punctuation and skipping fillers: "it's not, uh, it's not the whole story" -> "it's not the whole story".
    static func withoutRepeatedRuns(_ words: [String]) -> [String] {
        let spoken = words.filter { !DeterministicInterjectionCleanup.unambiguousFillers.contains($0.lowercased()) }
        let keys = spoken.map { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        var result: [String] = [], resultKeys: [String] = []
        for (word, key) in zip(spoken, keys) {
            result.append(word)
            resultKeys.append(key)
            var length = min(6, resultKeys.count / 2)
            while length >= 1 {
                let tail = resultKeys.suffix(length), before = resultKeys.dropLast(length).suffix(length)
                if Array(tail) == Array(before) {
                    result.removeLast(length)
                    resultKeys.removeLast(length)
                    length = min(6, resultKeys.count / 2)
                } else {
                    length -= 1
                }
            }
        }
        return result
    }

    private static func negationCount(in words: [String]) -> Int {
        words.filter { word in
            let lowered = word.lowercased().replacingOccurrences(of: "’", with: "'")
            return negations.contains(lowered) || lowered.hasSuffix("n't")
        }.count
    }
}
