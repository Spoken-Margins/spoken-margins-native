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

    /// Resolves a canonical source offset to the first retained spoken
    /// character at or after it. Removed markup, URLs, and repeated whitespace
    /// therefore seek forward to the next audible character instead of being
    /// treated as offsets in the shorter normalized string.
    public func spokenCharacterOffset(atOrAfterSourceOffset offset: Int) -> Int {
        let clamped = max(0, min(offset, sourceLength))
        guard clamped < sourceLength, !sourceOffsets.isEmpty else { return text.count }
        var lower = 0
        var upper = sourceOffsets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sourceOffsets[middle] < clamped {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

public enum SpeechTextNormalizer {
    public static func normalize(_ source: String) -> String {
        normalizeWithSourceOffsets(source).text
    }

    public static func normalizeWithSourceOffsets(_ source: String) -> NormalizedSpeechText {
        var rendered = source.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }

        rendered = projectAudibleContent(rendered)
        return finish(rendered, sourceLength: source.count)
    }

    /// Produces the conservative plain-text representation handed to Apple's
    /// system speech APIs. The source remains unchanged; every retained spoken
    /// character maps back to its original Character offset.
    public static func projectForSystemSpeech(_ source: String) -> NormalizedSpeechText {
        var rendered = source.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }

        rendered = projectAudibleContent(rendered)
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

    private static func projectAudibleContent(_ input: [MappedCharacter]) -> [MappedCharacter] {
        var rendered = reduceSocialCards(in: input)
        rendered = removeSocialInterfaceLines(in: rendered)

        let unspokenBlockPattern = #"(?is)<\s*(script|style|video|audio|figure|svg|iframe|canvas|noscript)\b[^>]*>.*?<\s*/\s*\1\s*>"#
        rendered = replace(pattern: unspokenBlockPattern, in: rendered, replacement: spaceReplacement)

        let unspokenStandalonePattern = #"(?is)<\s*(?:source|img|video|audio|iframe)\b[^>]*>"#
        rendered = replace(pattern: unspokenStandalonePattern, in: rendered, replacement: spaceReplacement)

        let remainingTagPattern = #"(?s)<[^>]*>"#
        rendered = replace(pattern: remainingTagPattern, in: rendered, replacement: spaceReplacement)

        let markdownImagePattern = #"!\[[^\]]*\]\([^)]*\)"#
        rendered = replace(pattern: markdownImagePattern, in: rendered, replacement: spaceReplacement)

        return removeLinks(in: rendered)
    }

    private static func removeSocialInterfaceLines(in input: [MappedCharacter]) -> [MappedCharacter] {
        var result: [MappedCharacter] = []
        var line: [MappedCharacter] = []

        func appendLine(endingWith newline: MappedCharacter?) {
            let trimmed = trimWhitespace(in: line)
            let text = String(trimmed.map(\.character))
            let danglingDestination = wholeMatch(
                #"\]\(https?://(?:www\.)?(?:x\.com|twitter\.com|bsky\.app|threads\.net|instagram\.com)/[^)\r\n\s]+\)"#,
                in: text
            )
            if !isSocialMetadataLine(text) && !danglingDestination {
                result.append(contentsOf: line)
            }
            if let newline {
                result.append(newline)
            }
            line.removeAll(keepingCapacity: true)
        }

        for character in input {
            if character.character == "\n" {
                appendLine(endingWith: character)
            } else {
                line.append(character)
            }
        }
        appendLine(endingWith: nil)
        return result
    }

    private static func reduceSocialCards(in input: [MappedCharacter]) -> [MappedCharacter] {
        let socialCardPattern = #"(?ims)^[ \t]*\[[ \t]*\r?\n(.*?)\r?\n\]\((https?://(?:www\.)?(?:x\.com|twitter\.com|bsky\.app|threads\.net|instagram\.com)/[^)\r\n\s]+)\)[ \t]*$"#
        return replace(pattern: socialCardPattern, in: input) { match, text, characters in
            guard match.numberOfRanges > 1,
                  let contentRange = Range(match.range(at: 1), in: text) else {
                return []
            }
            let lower = text.distance(from: text.startIndex, to: contentRange.lowerBound)
            let upper = text.distance(from: text.startIndex, to: contentRange.upperBound)
            return renderSocialCard(Array(characters[lower..<upper]))
        }
    }

    private static func renderSocialCard(_ content: [MappedCharacter]) -> [MappedCharacter] {
        var rendered = content
        let mediaBlockPattern = #"(?is)<\s*(video|audio|iframe)\b[^>]*>.*?<\s*/\s*\1\s*>"#
        rendered = replace(pattern: mediaBlockPattern, in: rendered, replacement: mediaAttachedReplacement)
        let standaloneMediaPattern = #"(?is)<\s*(?:video|audio|iframe)\b[^>]*\/?>"#
        rendered = replace(pattern: standaloneMediaPattern, in: rendered, replacement: mediaAttachedReplacement)
        let markdownImagePattern = #"!\[[^\]]*\]\([^\n)]*\)"#
        rendered = replace(pattern: markdownImagePattern, in: rendered, replacement: spaceReplacement)
        rendered = replace(pattern: #"(?s)<[^>]*>"#, in: rendered, replacement: spaceReplacement)

        var lines: [[MappedCharacter]] = [[]]
        for character in rendered {
            if character.character == "\n" {
                lines.append([])
            } else {
                lines[lines.count - 1].append(character)
            }
        }

        var result: [MappedCharacter] = []
        var authorCount = 0
        var previousPartWasMedia = false
        for rawLine in lines {
            let line = trimWhitespace(in: rawLine)
            guard let first = line.first else { continue }
            let text = String(line.map(\.character))
            if ["---", "___", "***"].contains(text) || isSocialMetadataLine(text) {
                continue
            }

            let author = socialAuthorDisplayName(text)
            let part: [MappedCharacter]
            if let author {
                let label = authorCount == 0 ? "Post" : "Quoted post"
                part = mappedCharacters("\(label) from \(author).", sourceOffset: first.sourceOffset)
                authorCount += 1
            } else {
                part = line
            }

            let isMedia = String(part.map(\.character)) == "Media attached."
            if isMedia && previousPartWasMedia { continue }
            if !result.isEmpty,
               (isMedia || (author != nil && authorCount > 1)),
               !socialCardEndsWithSentencePunctuation(String(result.map(\.character))),
               let previous = result.last {
                result.append(MappedCharacter(character: ".", sourceOffset: previous.sourceOffset))
            }
            if !result.isEmpty {
                result.append(MappedCharacter(character: " ", sourceOffset: first.sourceOffset))
            }
            result.append(contentsOf: part)
            previousPartWasMedia = isMedia
        }

        if let last = result.last,
           !socialCardEndsWithSentencePunctuation(String(result.map(\.character))) {
            result.append(MappedCharacter(character: ".", sourceOffset: last.sourceOffset))
        }
        return result
    }

    private static func mediaAttachedReplacement(
        _ match: NSTextCheckingResult,
        _ text: String,
        _ characters: [MappedCharacter]
    ) -> [MappedCharacter] {
        guard let range = Range(match.range, in: text) else { return [] }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        guard offset < characters.count else { return [] }
        return mappedCharacters("\nMedia attached.\n", sourceOffset: characters[offset].sourceOffset)
    }

    private static func mappedCharacters(_ text: String, sourceOffset: Int) -> [MappedCharacter] {
        text.map { MappedCharacter(character: $0, sourceOffset: sourceOffset) }
    }

    private static func socialAuthorDisplayName(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.*?)\s*@([A-Za-z0-9_]{1,30})$"#),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let displayRange = Range(match.range(at: 1), in: line),
              let handleRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        let display = line[displayRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return display.isEmpty ? "@\(line[handleRange])" : display
    }

    private static func isSocialMetadataLine(_ line: String) -> Bool {
        let atoms = line
            .split(whereSeparator: { $0 == "·" || $0 == "•" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !atoms.isEmpty, atoms.contains(where: isSocialMetric) else { return false }
        return atoms.allSatisfy { atom in
            isSocialMetric(atom)
                || wholeMatch(#"\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?"#, in: atom)
                || wholeMatch(#"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2},\s+\d{4}"#, in: atom)
        }
    }

    private static func isSocialMetric(_ value: String) -> Bool {
        wholeMatch(
            #"\d[\d,.]*[KMBT]?\s+(?:Views?|Replies?|Reposts?|Likes?|Bookmarks?|Quotes?)"#,
            in: value
        )
    }

    private static func wholeMatch(_ pattern: String, in value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)?.range == range
    }

    private static func socialCardEndsWithSentencePunctuation(_ value: String) -> Bool {
        let closingCharacters = CharacterSet(charactersIn: "\"'”’)]")
        let stripped = value.trimmingCharacters(in: closingCharacters)
        return stripped.last.map { ".!?".contains($0) } ?? true
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

        // Require an alphabetic top-level label. The previous expression also
        // treated decimal document references such as `Claim 2.5` and
        // `Section 3.2.1` as domains, deleting them from imported PDF text.
        let bareDomainPattern = #"(?i)(?<!@)\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)*\.[a-z][a-z0-9-]*(?:/[^\s<>()]*)?\b"#
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
