import Foundation

public struct NormalizedSpeechText: Equatable, Sendable {
    public let text: String
    public let sourceOffsets: [Int]
    public let sourceLength: Int

    public init(text: String, sourceOffsets: [Int], sourceLength: Int) {
        self.text = text
        self.sourceOffsets = sourceOffsets
        self.sourceLength = sourceLength
    }

    public func sourceOffset(atSpokenCharacterOffset offset: Int) -> Int {
        guard !sourceOffsets.isEmpty else { return sourceLength }
        let clamped = max(0, min(offset, sourceOffsets.count))
        guard clamped < sourceOffsets.count else { return sourceLength }
        return sourceOffsets[clamped]
    }
}

public enum SpeechTextNormalizer {
    public static func normalize(_ source: String) -> String {
        normalizeWithSourceOffsets(source).text
    }

    public static func normalizeWithSourceOffsets(_ source: String) -> NormalizedSpeechText {
        var rendered = source.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }

        rendered = removeLinks(in: rendered)
        return finish(rendered, sourceLength: source.count)
    }

    /// Produces the conservative plain-text representation handed to Apple's
    /// system speech APIs. The source remains unchanged; every retained spoken
    /// character maps back to its original Character offset.
    public static func projectForSystemSpeech(_ source: String) -> NormalizedSpeechText {
        var rendered = source.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }

        let unspokenBlockPattern = #"(?is)<\s*(script|style|video|audio|figure|svg)\b[^>]*>.*?<\s*/\s*\1\s*>"#
        rendered = replace(pattern: unspokenBlockPattern, in: rendered, replacement: spaceReplacement)

        let unspokenStandalonePattern = #"(?is)<\s*(?:source|img)\b[^>]*>"#
        rendered = replace(pattern: unspokenStandalonePattern, in: rendered, replacement: spaceReplacement)

        let remainingTagPattern = #"(?s)<[^>]*>"#
        rendered = replace(pattern: remainingTagPattern, in: rendered, replacement: spaceReplacement)

        let markdownImagePattern = #"!\[[^\]]*\]\([^)]*\)"#
        rendered = replace(pattern: markdownImagePattern, in: rendered, replacement: spaceReplacement)

        rendered = removeLinks(in: rendered)
        rendered = rendered.flatMap(systemSpeechCharacters)
        return finish(rendered, sourceLength: source.count)
    }

    public static func isSystemSpeechSafe(_ text: String) -> Bool {
        text.allSatisfy { character in
            let projected = systemSpeechCharacters(
                MappedCharacter(character: character, sourceOffset: 0)
            )
            return projected.count == 1 && projected[0].character == character
        }
    }

    private static func removeLinks(in input: [MappedCharacter]) -> [MappedCharacter] {
        var rendered = input

        let markdownPattern = #"\[([^\]]+)\]\((https?://[^)\s]+|www\.[^)\s]+|[^)\s]+\.[^)\s]+)\)"#
        rendered = replace(pattern: markdownPattern, in: rendered) { match, text, characters in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return []
            }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            return Array(characters[lower..<upper])
        }

        let rawURLPattern = #"(?i)\b(?:https?://|www\.)[^\s<>()]+"#
        rendered = replace(pattern: rawURLPattern, in: rendered) { _, _, _ in [] }

        let bareDomainPattern = #"(?i)(?<!@)\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+(?:/[^\s<>()]*)?\b"#
        rendered = replace(pattern: bareDomainPattern, in: rendered) { _, _, _ in [] }

        return rendered
    }

    private static func finish(_ input: [MappedCharacter], sourceLength: Int) -> NormalizedSpeechText {
        var rendered = input
        rendered = collapseWhitespace(in: rendered)
        rendered = removeSpacesBeforePunctuation(in: rendered)
        rendered = trimWhitespace(in: rendered)
        return NormalizedSpeechText(
            text: String(rendered.map(\.character)),
            sourceOffsets: rendered.map(\.sourceOffset),
            sourceLength: sourceLength
        )
    }

    private static func systemSpeechCharacters(_ mapped: MappedCharacter) -> [MappedCharacter] {
        let replacements: [Character: String] = [
            "“": "\"", "”": "\"", "„": "\"",
            "‘": "'", "’": "'", "‚": "'",
            "—": "-", "–": "-", "−": "-",
            "…": "...", "\u{00A0}": " "
        ]
        if let replacement = replacements[mapped.character] {
            return replacement.map { MappedCharacter(character: $0, sourceOffset: mapped.sourceOffset) }
        }

        let precomposed = String(mapped.character).precomposedStringWithCanonicalMapping
        return precomposed.compactMap { character in
            guard character.unicodeScalars.count == 1,
                  String(character).utf16.count == 1,
                  let scalar = character.unicodeScalars.first else {
                return nil
            }

            if scalar.properties.isEmoji, scalar.value > 0x7F {
                return nil
            }

            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned,
                 .nonspacingMark, .spacingMark, .enclosingMark, .otherSymbol:
                return nil
            default:
                return MappedCharacter(character: character, sourceOffset: mapped.sourceOffset)
            }
        }
    }

    private static func spaceReplacement(
        _ match: NSTextCheckingResult,
        _ text: String,
        _ characters: [MappedCharacter]
    ) -> [MappedCharacter] {
        guard let range = Range(match.range, in: text) else { return [] }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        guard offset < characters.count else { return [] }
        return [MappedCharacter(character: " ", sourceOffset: characters[offset].sourceOffset)]
    }

    private static func replace(
        pattern: String,
        in characters: [MappedCharacter],
        replacement: (NSTextCheckingResult, String, [MappedCharacter]) -> [MappedCharacter]
    ) -> [MappedCharacter] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return characters }
        let text = String(characters.map(\.character))
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range).reversed()
        var result = characters
        for match in matches {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let lower = text.distance(from: text.startIndex, to: swiftRange.lowerBound)
            let upper = text.distance(from: text.startIndex, to: swiftRange.upperBound)
            result.replaceSubrange(lower..<upper, with: replacement(match, text, characters))
        }
        return result
    }

    private static func collapseWhitespace(in characters: [MappedCharacter]) -> [MappedCharacter] {
        var result: [MappedCharacter] = []
        var previousWasWhitespace = false
        for mapped in characters {
            if mapped.character.isWhitespace {
                if !previousWasWhitespace {
                    result.append(MappedCharacter(character: " ", sourceOffset: mapped.sourceOffset))
                }
                previousWasWhitespace = true
            } else {
                result.append(mapped)
                previousWasWhitespace = false
            }
        }
        return result
    }

    private static func removeSpacesBeforePunctuation(in characters: [MappedCharacter]) -> [MappedCharacter] {
        var result: [MappedCharacter] = []
        for mapped in characters {
            if ".,?!".contains(mapped.character), result.last?.character == " " {
                result.removeLast()
            }
            result.append(mapped)
        }
        return result
    }

    private static func trimWhitespace(in characters: [MappedCharacter]) -> [MappedCharacter] {
        var lower = 0
        var upper = characters.count
        while lower < upper, characters[lower].character.isWhitespace {
            lower += 1
        }
        while upper > lower, characters[upper - 1].character.isWhitespace {
            upper -= 1
        }
        return Array(characters[lower..<upper])
    }

    private struct MappedCharacter: Equatable {
        var character: Character
        var sourceOffset: Int
    }
}
