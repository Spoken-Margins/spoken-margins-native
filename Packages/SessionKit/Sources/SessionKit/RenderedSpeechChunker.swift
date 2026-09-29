import Foundation

public enum RenderedSpeechChunkBoundary: String, Sendable {
    case sentence
    case comma
    case whitespace
    case hard

    public var transitionDelay: TimeInterval {
        switch self {
        case .sentence: 0.12
        case .comma: 0.05
        case .whitespace, .hard: 0
        }
    }
}

public struct RenderedSpeechSourceSlice: Equatable, Sendable {
    public var text: String
    public var sourceLength: Int
    public var boundary: RenderedSpeechChunkBoundary

    public init(text: String, sourceLength: Int, boundary: RenderedSpeechChunkBoundary) {
        self.text = text
        self.sourceLength = sourceLength
        self.boundary = boundary
    }
}

public struct RenderedSpeechPlannedSlice: Equatable, Sendable {
    public var startOffset: Int
    public var slice: RenderedSpeechSourceSlice

    public init(startOffset: Int, slice: RenderedSpeechSourceSlice) {
        self.startOffset = startOffset
        self.slice = slice
    }
}

public enum RenderedSpeechChunker {
    /// The most a chunk may cost to speak, in `spokenCost` units (about one per letter of prose).
    /// Supertonic babbles on chunks near 28 s (#240); prose speaks at about 14 letters a second,
    /// so 180 keeps prose chunks near 13 s and number-dense ones under about 16 s.
    public static let spokenCostBudget = 180

    /// Supertonic reads a digit or a symbol as a word: `91.1%` becomes "ninety one point one percent".
    /// On the owner's arXiv table, digit-heavy text spoke about four times slower per character.
    public static func spokenCost(of character: Character) -> Int {
        if character.isNumber || costlySymbols.contains(character) { return 4 }
        return 1
    }

    private static let costlySymbols: Set<Character> = ["%", "$", "€", "£", "#", "&", "+", "=", "<", ">", "×", "±", "°", "σ", "·", "@", "^", "~", "*", "|", "\\", "/"]

    /// The longest prefix of `text` whose spoken cost fits `budget`, at least one character.
    static func prefix(of text: Substring, withinSpokenCost budget: Int) -> Substring {
        var cost = 0
        var end = text.startIndex
        while end < text.endIndex {
            cost += spokenCost(of: text[end])
            if cost > budget, end > text.startIndex { break }
            end = text.index(after: end)
        }
        return text[..<end]
    }

    /// Plans a complete source in one forward pass. Repeatedly calling
    /// `sourceSlice(from:startOffset:)` for increasing offsets restarts String
    /// indexing at the beginning and becomes quadratic for book-length text.
    public static func sourceSlices(
        from source: String,
        maxCharacters: Int = spokenCostBudget
    ) -> [RenderedSpeechPlannedSlice] {
        let maximum = max(1, maxCharacters)
        var remaining = source[...]
        var startOffset = 0
        var result: [RenderedSpeechPlannedSlice] = []
        result.reserveCapacity(max(1, source.utf8.count / maximum))

        while !remaining.isEmpty {
            let prefix = prefix(of: remaining, withinSpokenCost: maximum)
            let slice = selectChunkPrefix(String(prefix), maxCharacters: maximum, endsText: prefix.endIndex == remaining.endIndex)
            guard !slice.text.isEmpty, slice.sourceLength > 0 else { break }
            result.append(RenderedSpeechPlannedSlice(startOffset: startOffset, slice: slice))
            guard let next = remaining.index(
                remaining.startIndex,
                offsetBy: slice.sourceLength,
                limitedBy: remaining.endIndex
            ) else { break }
            remaining = remaining[next...]
            startOffset += slice.sourceLength
        }
        return result
    }

    public static func sourceSlice(
        from source: String,
        startOffset: Int,
        maxCharacters: Int = spokenCostBudget
    ) -> RenderedSpeechSourceSlice {
        let clampedOffset = max(0, min(startOffset, source.count))
        let start = source.index(source.startIndex, offsetBy: clampedOffset)
        let prefix = prefix(of: source[start...], withinSpokenCost: max(1, maxCharacters))
        return selectChunkPrefix(String(prefix), maxCharacters: maxCharacters, endsText: prefix.endIndex == source.endIndex)
    }

    public static func selectChunkPrefix(
        _ prefix: String,
        maxCharacters: Int = spokenCostBudget,
        endsText: Bool = false
    ) -> RenderedSpeechSourceSlice {
        // A number-dense prefix is short in characters, so scale to it rather than the budget.
        let minimumUsefulLength = min(80, max(24, min(maxCharacters, prefix.count) / 3))
        let sentenceCharacters = CharacterSet(charactersIn: ".!?\n;:")
        if let sentence = boundary(
            in: prefix,
            characters: sentenceCharacters,
            includeBoundary: true,
            minimumUsefulLength: minimumUsefulLength,
            endsText: endsText
        ) {
            return sentence.withBoundary(.sentence)
        }
        if let comma = boundary(
            in: prefix,
            characters: CharacterSet(charactersIn: ","),
            includeBoundary: true,
            minimumUsefulLength: minimumUsefulLength,
            endsText: endsText
        ) {
            return comma.withBoundary(.comma)
        }
        if let whitespace = boundary(
            in: prefix,
            characters: .whitespacesAndNewlines,
            includeBoundary: false,
            minimumUsefulLength: minimumUsefulLength,
            endsText: endsText
        ) {
            return whitespace.withBoundary(.whitespace)
        }
        let normalized = SpeechTextNormalizer.normalize(prefix)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RenderedSpeechSourceSlice(
            text: normalized,
            sourceLength: prefix.count,
            boundary: .hard
        )
    }

    private static func boundary(
        in prefix: String,
        characters: CharacterSet,
        includeBoundary: Bool,
        minimumUsefulLength: Int,
        endsText: Bool
    ) -> RenderedSpeechSourceSlice? {
        // The last boundary character that doesn't sit inside a number: "0.8889" and "7,494"
        // split at their punctuation leave two halves Supertonic can't read (#240).
        var candidate = prefix.endIndex
        var found: Range<String.Index>?
        while candidate > prefix.startIndex {
            candidate = prefix.index(before: candidate)
            let character = prefix[candidate]
            guard character.unicodeScalars.allSatisfy(characters.contains) else { continue }
            if isInsideNumber(prefix, at: candidate, endsText: endsText) { continue }
            found = candidate..<prefix.index(after: candidate)
            break
        }
        guard let range = found else { return nil }
        let end = includeBoundary ? range.upperBound : range.lowerBound
        guard prefix.distance(from: prefix.startIndex, to: end) >= minimumUsefulLength else {
            return nil
        }
        let selected = String(prefix[..<end])
        let normalized = SpeechTextNormalizer.normalize(selected)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return RenderedSpeechSourceSlice(
            text: normalized,
            sourceLength: prefix.distance(from: prefix.startIndex, to: range.upperBound),
            boundary: .hard
        )
    }
}

extension RenderedSpeechChunker {
    /// Punctuation between digits, or at the end of the prefix right after a digit (where the
    /// next digit may follow): `0.|8889`, `7,|494`, `12:|30`.
    fileprivate static func isInsideNumber(_ text: String, at index: String.Index, endsText: Bool) -> Bool {
        guard [".", ",", ":"].contains(text[index]), index > text.startIndex,
              text[text.index(before: index)].isNumber else { return false }
        let next = text.index(after: index)
        return next == text.endIndex ? !endsText : text[next].isNumber
    }
}

private extension RenderedSpeechSourceSlice {
    func withBoundary(_ boundary: RenderedSpeechChunkBoundary) -> Self {
        .init(text: text, sourceLength: sourceLength, boundary: boundary)
    }
}
