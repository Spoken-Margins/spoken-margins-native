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
        projectionMemo.projection(of: source, kind: .speech) { computeNormalizedWithSourceOffsets(source) }
    }

    private static func computeNormalizedWithSourceOffsets(_ source: String) -> NormalizedSpeechText {
        var rendered = source.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }

        rendered = projectAudibleContent(rendered)
        return finish(rendered, sourceLength: source.count)
    }

    /// The projections of the one long text a play is about to start, so a play does not project it on the main
    /// thread when something off it already has (#2256). Short texts, such as streamed chunks, never use it.
    static let projectionMemo = SpeechProjectionMemo()

    /// Which players a text may be spoken by, so the projection can be made ahead for each of them.
    public struct PrewarmVoiceKinds: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The on-device voices' own projection (`normalizeWithSourceOffsets`).
        public static let onDevice = PrewarmVoiceKinds(rawValue: 1)
        /// Apple's system speech (`projectForSystemSpeech`).
        public static let system = PrewarmVoiceKinds(rawValue: 2)

        /// The kinds a play may use when the listener picked an on-device voice or a system one. An on-device voice
        /// hands over to the system voice mid-play (Low Power Mode, a missing model, a render failure), and that voice
        /// projects the text its own way, so both are made ahead (#2256). The system voice never hands over the
        /// other way.
        public static func forSelection(onDeviceVoice: Bool) -> PrewarmVoiceKinds {
            onDeviceVoice ? [.onDevice, .system] : [.system]
        }
    }

    /// Projects `source` for the players of the given kinds and keeps the results for the play that follows. Call it
    /// off the main thread; the call is the whole cost, and a text too short or too long for the memo is left alone.
    public static func prewarm(_ source: String, kinds: PrewarmVoiceKinds = .onDevice) {
        guard SpeechProjectionMemo.holds(utf8Count: source.utf8.count) else { return }
        // The memo's byte budget counts each kind's copy of the text. A book that would fit once but not twice keeps
        // only the first kind, never the second pushing the first out (the first is the chosen voice's own).
        let wanted = [(PrewarmVoiceKinds.onDevice, { _ = normalizeWithSourceOffsets(source) }),
                      (PrewarmVoiceKinds.system, { _ = projectForSystemSpeech(source) })]
            .filter { kinds.contains($0.0) }
        for (index, kind) in wanted.enumerated() {
            guard SpeechProjectionMemo.fits(utf8Count: source.utf8.count, copies: index + 1) else { return }
            kind.1()
        }
    }

    /// Produces the conservative plain-text representation handed to Apple's
    /// system speech APIs. The source remains unchanged; every retained spoken
    /// character maps back to its original Character offset.
    public static func projectForSystemSpeech(_ source: String) -> NormalizedSpeechText {
        projectionMemo.projection(of: source, kind: .systemSpeech) { computeProjectionForSystemSpeech(source) }
    }

    /// `projectForSystemSpeech` of `source` from `sourceOffset` on: the spoken characters at or after that offset, each
    /// still mapped to its offset in the whole `source`, and `sourceLength` that of the whole `source`.
    ///
    /// The tail is always the tail of the whole projection, never the projection of the remaining text on its own:
    /// the projection rewrites some things as a unit (a table, a social card, a link's address), and the remaining
    /// text alone starts in the middle of one and reads its leftovers, the pipes of a table row among them (#4189).
    /// A text the memo holds is projected once, whole, and a play from a saved offset (a resume, a rate change, a
    /// hand-over) takes the tail of that projection, so it does not project the remaining text again on the thread
    /// that plays (#2256). A text too short for the memo projects whole in a few milliseconds, kept or not. The tail
    /// drops the space the cut leaves, so it reads as the projection of the remaining text does. Only a text too long
    /// for the memo is projected from the offset: a whole projection would cost more than the tail and nothing could
    /// keep it, so a table cut in two there still reads its leftover rows.
    public static func projectForSystemSpeech(_ source: String, fromSourceOffset sourceOffset: Int) -> NormalizedSpeechText {
        guard source.utf8.count <= SpeechProjectionMemo.maximumBytes else {
            let characters = Array(source)
            let start = max(0, min(sourceOffset, characters.count))
            let tail = projectForSystemSpeech(String(characters[start...]))
            return NormalizedSpeechText(
                text: tail.text,
                sourceOffsets: tail.sourceOffsets.map { start + $0 },
                sourceLength: characters.count
            )
        }
        let whole = projectForSystemSpeech(source)
        var first = whole.spokenCharacterOffset(atOrAfterSourceOffset: sourceOffset)
        // Two separate characters can join into one once something between them is dropped (a Hangul lead and
        // vowel jamo around an emoji), so the text can hold fewer characters than `sourceOffsets` does: stop at the end.
        var index = whole.text.index(whole.text.startIndex, offsetBy: first, limitedBy: whole.text.endIndex) ?? whole.text.endIndex
        while index < whole.text.endIndex, whole.text[index].isWhitespace {
            index = whole.text.index(after: index)
            first += 1
        }
        return NormalizedSpeechText(
            text: String(whole.text[index...]),
            sourceOffsets: Array(whole.sourceOffsets[first...]),
            sourceLength: whole.sourceLength
        )
    }

    private static func computeProjectionForSystemSpeech(_ source: String) -> NormalizedSpeechText {
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

    public static func normalizeImportedText(_ source: String) -> String {
        normalizeImportedTextWithSourceOffsets(source).text
    }

    /// `normalizeImportedText` with each kept character's offset in `source`, so
    /// ranges found before cleaning (a PDF's superscript markers) can follow it.
    static func normalizeImportedTextWithSourceOffsets(_ source: String) -> NormalizedSpeechText {
        let mapped = source.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }
        return finish(projectAudibleContent(mapped, speakIdentifiers: false), sourceLength: source.count)
    }

    private static func projectAudibleContent(_ input: [MappedCharacter], speakIdentifiers: Bool = true) -> [MappedCharacter] {
        var rendered = reduceSocialCards(in: input)
        rendered = removeSocialInterfaceLines(in: rendered)

        let unspokenBlockPattern = #"(?is)<\s*(script|style|video|audio|figure|svg|iframe|canvas|noscript)\b[^>]*>.*?<\s*/\s*\1\s*>"#
        rendered = replace(pattern: unspokenBlockPattern, in: rendered, replacement: spaceReplacement)

        let unspokenStandalonePattern = #"(?is)<\s*(?:source|img|video|audio|iframe)\b[^>]*>"#
        rendered = replace(pattern: unspokenStandalonePattern, in: rendered, replacement: spaceReplacement)

        // Import cleaning keeps the old pattern: stored text stays byte-identical, so no Margin moves (I13 rule 1a).
        let remainingTagPattern = speakIdentifiers ? markupTagPattern : #"(?s)<[^>]*>"#
        rendered = replace(pattern: remainingTagPattern, in: rendered, replacement: spaceReplacement)

        let markdownImagePattern = #"!\[[^\]]*\]\([^)]*\)"#
        rendered = replace(pattern: markdownImagePattern, in: rendered, replacement: spaceReplacement)

        if speakIdentifiers {
            // Speech only: import cleaning keeps stored text byte-identical (I13 rule 1a), tables included.
            rendered = replaceMarkdownTables(in: rendered)
            rendered = speakReferenceMarkers(in: rendered)
            rendered = speakDefangedDomains(in: rendered)
        }
        rendered = removeLinks(in: rendered)
        if speakIdentifiers {
            rendered = speakLinkAndEmailFragments(in: rendered)
            rendered = speakMathAlphabet(in: rendered)
        }
        return rendered
    }

    /// What a table is replaced with. It is the notice `DocumentSpeechRules.treatment(forRole: "table")` says for a
    /// table in a PDF or other structured document, so a table sounds the same wherever it came from.
    static let tableNotice = "Table not read."

    /// A web article's table reaches speech as markdown rows, and a voice read the pipes and the `| --- |` line aloud
    /// (#4048). A table is a header row, a separator row with the same number of cells, and the pipe rows after
    /// them. It becomes `tableNotice`, mapped to the header's offset. A lone pipe in a sentence, a rule line with no
    /// pipe, a header whose cell count differs from the separator's, and anything inside a fenced code block stay as
    /// they are. A row indented four spaces or more is code, so it never starts a table.
    private static func replaceMarkdownTables(in input: [MappedCharacter]) -> [MappedCharacter] {
        guard input.contains(where: { $0.character == "|" }) else { return input }

        var lines: [(start: Int, end: Int)] = []
        var lineStart = 0
        for (index, mapped) in input.enumerated() where mapped.character.isNewline {
            lines.append((lineStart, index))
            lineStart = index + 1
        }
        lines.append((lineStart, input.count))

        func text(_ line: (start: Int, end: Int)) -> String {
            String(input[line.start..<line.end].map(\.character))
        }

        var output: [MappedCharacter] = []
        output.reserveCapacity(input.count)
        /// Emits `lines[first..<after]` with the newline that ends each, the last one's included when the source has it.
        func keep(_ first: Int, _ after: Int) {
            let lower = lines[first].start
            let upper = min(lines[after - 1].end + 1, input.count)
            output.append(contentsOf: input[lower..<upper])
        }

        let fences = lines.map { codeFence(in: text($0)) }
        var openFence: (marker: Character, length: Int)?
        // Openers known to have no closer anywhere after them, so a text of many stray fences is still one pass.
        var unclosed: [String: Bool] = [:]
        var index = 0
        while index < lines.count {
            let line = text(lines[index])
            if let fence = fences[index] {
                if let open = openFence {
                    if fence.marker == open.marker, fence.length >= open.length, fence.closes { openFence = nil }
                } else if opens(fence, at: index, in: fences, unclosed: &unclosed) {
                    openFence = (fence.marker, fence.length)
                }
                keep(index, index + 1)
                index += 1
                continue
            }
            if openFence == nil,
               index + 1 < lines.count,
               let headerCells = tableCells(in: line, allowingIndent: false),
               let separatorCells = tableSeparatorCells(in: text(lines[index + 1])),
               headerCells.count == separatorCells {
                let edgePipes = line.drop(while: { $0 == " " }).first == "|"
                var after = index + 2
                while after < lines.count,
                      let cells = tableCells(in: text(lines[after]), allowingIndent: true),
                      isTableBodyRow(text(lines[after]), cells: cells, edgePipes: edgePipes, columns: headerCells.count) {
                    after += 1
                }
                let start = input[lines[index].start].sourceOffset
                output.append(contentsOf: mappedCharacters(tableNotice, sourceOffset: start))
                if lines[after - 1].end < input.count { output.append(input[lines[after - 1].end]) }
                index = after
                continue
            }
            keep(index, index + 1)
            index += 1
        }
        return output
    }

    /// A line after the separator belongs to the table when it is shaped like a row of it: it starts with a pipe when
    /// the header does, and otherwise has the header's number of cells. A sentence or list item that merely holds a
    /// pipe ends the table and stays text (GFM would keep taking rows to the blank line; deleting prose costs more).
    private static func isTableBodyRow(_ line: String, cells: [String], edgePipes: Bool, columns: Int) -> Bool {
        if edgePipes { return line.drop(while: { $0 == " " }).first == "|" }
        return cells.count == columns
    }

    /// Whether `fence` opens a code block: a closing fence of the same kind has to follow it. A stray fence line with
    /// no closer is text, and must not switch table replacement off for the rest of the document.
    private static func opens(
        _ fence: (marker: Character, length: Int, closes: Bool),
        at index: Int,
        in fences: [(marker: Character, length: Int, closes: Bool)?],
        unclosed: inout [String: Bool]
    ) -> Bool {
        let key = "\(fence.marker)\(fence.length)"
        if unclosed[key] == true { return false }
        var next = index + 1
        while next < fences.count {
            if let other = fences[next], other.marker == fence.marker, other.length >= fence.length, other.closes { return true }
            next += 1
        }
        unclosed[key] = true
        return false
    }

    /// The cells of a pipe row, or nil when the line has no unescaped pipe (or is code-indented and
    /// `allowingIndent` is false). One leading and one trailing pipe are the row's edges, not cells.
    private static func tableCells(in line: String, allowingIndent: Bool) -> [String]? {
        var body = Substring(line)
        var indent = 0
        while body.first == " " { body = body.dropFirst(); indent += 1 }
        if !allowingIndent, indent >= 4 || body.first == "\t" { return nil }
        while let last = body.last, last.isWhitespace { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var sawPipe = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
                sawPipe = true
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        guard sawPipe else { return nil }
        if cells.first?.allSatisfy(\.isWhitespace) == true { cells.removeFirst() }
        if cells.last?.allSatisfy(\.isWhitespace) == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The cell count of a separator row (`| --- | :-: |`), or nil when the line is not one: every cell is dashes with
    /// an optional colon at either end, and the line has a pipe.
    private static func tableSeparatorCells(in line: String) -> Int? {
        guard let cells = tableCells(in: line, allowingIndent: true), !cells.isEmpty else { return nil }
        for cell in cells {
            var dashes = Substring(cell)
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        }
        return cells.count
    }

    /// A line that opens or closes a fenced code block: three or more backticks or tildes, indented at most three
    /// spaces. `closes` is true when nothing but whitespace follows the fence, which is what a closing fence needs.
    private static func codeFence(in line: String) -> (marker: Character, length: Int, closes: Bool)? {
        var body = Substring(line)
        var indent = 0
        while body.first == " ", indent < 4 { body = body.dropFirst(); indent += 1 }
        guard indent < 4, let marker = body.first, marker == "`" || marker == "~" else { return nil }
        let length = body.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let rest = body.dropFirst(length)
        if marker == "`", rest.contains("`") { return nil }
        return (marker, length, rest.allSatisfy(\.isWhitespace))
    }

    /// Real markup only. Speech normalizes a whole document at once, and a bare `<[^>]*>` ran from a table note's
    /// "p<0.05" to the next ">" pages later: one match took 107,043 characters, more than half of a paper's words (#3813).
    /// Comparisons keep their words: a tag's name follows the "<" directly, and anything after the name is attributes.
    private static let markupTagPattern = #"(?s)<!--.*?-->|<![A-Za-z][^<>]*>|<\?[A-Za-z][^<>]*\?>|</?[A-Za-z][-A-Za-z0-9:_]*(?:\s+[-A-Za-z0-9_:.@]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+)(?:\s+[-A-Za-z0-9_:.@]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)?\s*/?>"#

    /// Math letters and private-use glyphs in any text (a PDF on the old reader, a pasted equation) are said as words:
    /// a voice has no tokens for them and makes noise instead. Everything else passes through untouched.
    private static func speakMathAlphabet(in input: [MappedCharacter]) -> [MappedCharacter] {
        guard PDFMathSpeech.containsMathAlphabet(String(input.map(\.character))) else { return input }
        let spoken = PDFMathSpeech.speakingInlineMath(input.map(\.character), offsets: input.map(\.sourceOffset))
        return zip(spoken.characters, spoken.offsets).map { MappedCharacter(character: $0, sourceOffset: $1) }
    }

    /// Characters that can be part of one URL or address token. Brackets and quotes end it, so
    /// "(portal/content/acl-code-ethics)" keeps its parentheses around the replacement.
    private static let addressTokenCharacters = #"[^\s()\[\]<>"“”]"#

    /// URLs and addresses that survive link removal, usually because PDF extraction dropped
    /// their first line, were read as words ("portal content, ACL code ethics") (#358). A token
    /// holding "@" before a letter or digit is spoken as "email"; a token with two or more "/"
    /// and a letter (not a date like 1/2/2024) as "link". Trailing sentence punctuation stays.
    /// Parentheses or brackets left empty by removed links are dropped.
    private static func speakLinkAndEmailFragments(in input: [MappedCharacter]) -> [MappedCharacter] {
        let token = addressTokenCharacters
        var rendered = replace(pattern: "\(token)*@[A-Za-z0-9]\(token)*", in: input) { match, text, characters in
            spokenAddress("email", match: match, text: text, characters: characters)
        }
        rendered = replace(pattern: "\(token)*/\(token)*/\(token)*", in: rendered) { match, text, characters in
            guard let range = Range(match.range, in: text), looksLikeURLPath(String(text[range])) else {
                return matchedCharacters(match, text: text, characters: characters)
            }
            return spokenAddress("link", match: match, text: text, characters: characters)
        }
        return replace(pattern: #"\(\s*\)|\[\s*\]"#, in: rendered, replacement: spaceReplacement)
    }

    /// A slash-separated token that reads as a URL, not as prose: it names a domain
    /// ("royalsocietypublishing.org/journal/rsos") or is a lowercase path with a hyphen, dot or
    /// underscore ("portal/content/acl-code-ethics"). Lists and units in papers stay words:
    /// "T/NK/ILC", "p53/Mdm2/Mdmx", "Live/CD31−/CD45−", "v/cm/mm", "102905/Z/13/Z".
    static func looksLikeURLPath(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        if trimmed.range(of: #"[A-Za-z0-9]\.[A-Za-z]{2,}"#, options: .regularExpression) != nil { return true }
        let segments = trimmed.split(separator: "/").map(String.init)
        guard segments.count >= 2,
              segments.allSatisfy({ $0.range(of: #"^[a-z0-9._~%-]+$"#, options: .regularExpression) != nil }),
              segments.contains(where: { $0.contains(where: { "-._".contains($0) }) }),
              trimmed.contains(where: \.isLetter) else { return false }
        return true
    }

    private static func spokenAddress(
        _ word: String,
        match: NSTextCheckingResult,
        text: String,
        characters: [MappedCharacter]
    ) -> [MappedCharacter] {
        let matched = matchedCharacters(match, text: text, characters: characters)
        guard let first = matched.first else { return [] }
        let trailing = matched.reversed().prefix { ".,;:!?".contains($0.character) }.reversed()
        return mappedCharacters(word, sourceOffset: first.sourceOffset) + trailing
    }

    private static func matchedCharacters(_ match: NSTextCheckingResult, text: String, characters: [MappedCharacter]) -> [MappedCharacter] {
        guard let range = Range(match.range, in: text) else { return [] }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.distance(from: text.startIndex, to: range.upperBound)
        return Array(characters[lower..<upper])
    }

    private static func speakReferenceMarkers(in input: [MappedCharacter]) -> [MappedCharacter] {
        replace(pattern: #"\[(\^?)([0-9]{1,3}(?:\s*[,–-]\s*[0-9]{1,3})*)\]"#, in: input) { match, text, characters in
            guard let range = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 2), in: text) else { return [] }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let label = match.range(at: 1).length > 0 ? " footnote " : " citation "
            let value = String(text[numberRange]).replacingOccurrences(of: "–", with: " to ").replacingOccurrences(of: "-", with: " to ")
            return (label + value + " ").map { MappedCharacter(character: $0, sourceOffset: characters[lower].sourceOffset) }
        }
    }

    private static func speakDefangedDomains(in input: [MappedCharacter]) -> [MappedCharacter] {
        replace(pattern: #"(?i)\b[a-z0-9][a-z0-9-]*(?:\[\.\][a-z0-9-]+)+\b"#, in: input) { match, text, characters in
            guard let range = Range(match.range, in: text) else { return [] }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            var result: [MappedCharacter] = []
            let matched = Array(characters[lower..<upper])
            var index = 0
            for character in "domain " { result.append(MappedCharacter(character: character, sourceOffset: matched[0].sourceOffset)) }
            while index < matched.count {
                if index + 2 < matched.count, matched[index].character == "[", matched[index + 1].character == ".", matched[index + 2].character == "]" {
                    result += " dot ".map { MappedCharacter(character: $0, sourceOffset: matched[index].sourceOffset) }
                    index += 3
                } else {
                    if matched[index].character == "-" {
                        result += " hyphen ".map { MappedCharacter(character: $0, sourceOffset: matched[index].sourceOffset) }
                    } else { result.append(matched[index]) }
                    index += 1
                }
            }
            result.append(MappedCharacter(character: ".", sourceOffset: matched.last!.sourceOffset))
            return result
        }
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
        var rendered = removeMarkdownLinks(in: input, onlyEmptyDestinations: false)

        let rawURLPattern = #"(?i)\b(?:https?://|www\.)[^\s<>()]+"#
        rendered = replace(pattern: rawURLPattern, in: rendered) { _, _, _ in [] }

        // A bare domain needs at least two letters in its top-level label.
        // Single-letter labels delete ordinary prose such as U.S., i.e., and
        // Ph.D. Explicit URLs remain handled above. Keep decimal references.
        let bareDomainPattern = #"(?i)(?<!@)\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)*\.[a-z]{2,}(?:/[^\s<>()]*)?\b"#
        rendered = replace(pattern: bareDomainPattern, in: rendered) { _, _, _ in [] }

        return rendered
    }

    /// Removes the links that imports before #560 left in an item's text with their title and no
    /// URL, `[book]( "Book")`. Display text such as a Margin note's context runs through this;
    /// nothing else in the text changes, so notes without those links stay byte-for-byte the same.
    /// The other remnant, `margins "Margin (typography)")` from a URL with parentheses, can't be
    /// told apart from a quoted title in prose, so it stays until the article is shared again.
    static func removingLinkTitleRemnants(from text: String) -> String {
        let mapped = text.enumerated().map { MappedCharacter(character: $0.element, sourceOffset: $0.offset) }
        return String(removeMarkdownLinks(in: mapped, onlyEmptyDestinations: true).map(\.character))
    }

    /// A destination that is an address: a web address (`https://`, `www.`, or anything with a dot),
    /// a place in the same page (`#executive-summary`, a table of contents' links), a path on the
    /// same site (`/docs`, `./next`), or a mail or phone link. Only the link's words are read.
    private static let linkDestinationPattern = #"(?i)^(?:https?://|www\.)\S|\S\.\S|^#|^\.{0,2}/|^(?:mailto|tel):"#

    /// A Markdown link keeps only its text. The destination may hold parentheses
    /// (`https://en.wikipedia.org/wiki/Margin_(typography)`) and may be followed by a title
    /// (`[book](https://en.wikipedia.org/wiki/Book "Book")`), which Wikipedia gives nearly every
    /// link; the title was read aloud after the link text (#560). A destination that isn't an
    /// address (`[1](2)`) is left as written, unless it is empty and has a title: that is a
    /// link whose URL an earlier import already removed.
    private static func removeMarkdownLinks(in input: [MappedCharacter], onlyEmptyDestinations: Bool) -> [MappedCharacter] {
        let destination = #"(?:[^()\s"]|\([^()\s"]*\)|\()*"#
        let title = #"\s+(?:"[^"\n]*"|'[^'\n]*')"#
        let pattern = #"\[([^\]]+)\]\(\s*("# + destination + #")("# + title + #")?\s*\)"#
        return replace(pattern: pattern, in: input) { match, text, characters in
            guard let textRange = Range(match.range(at: 1), in: text),
                  let destinationRange = Range(match.range(at: 2), in: text) else {
                return matchedCharacters(match, text: text, characters: characters)
            }
            let target = text[destinationRange]
            let hasTitle = match.range(at: 3).location != NSNotFound
            let isLink = target.isEmpty
                ? hasTitle
                : !onlyEmptyDestinations && target.range(of: linkDestinationPattern, options: .regularExpression) != nil
            guard isLink else { return matchedCharacters(match, text: text, characters: characters) }
            let lower = text.distance(from: text.startIndex, to: textRange.lowerBound)
            let upper = text.distance(from: text.startIndex, to: textRange.upperBound)
            return Array(characters[lower..<upper])
        }
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
        // Newlines, tabs and CRLF are word boundaries, even though their
        // scalars are controls. Preserve them before filtering unsafe scalars.
        if mapped.character.isWhitespace {
            return [MappedCharacter(character: " ", sourceOffset: mapped.sourceOffset)]
        }
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

/// The latest few projections per kind, for texts long enough that projecting them is felt (282 ms for a long
/// article, #2256). A text is matched by its exact UTF-8 bytes, never by Swift's canonical equivalence, so a changed
/// or re-normalised text is never served another text's projection. Several slots, because the text a play speaks
/// (preface and text) is not the one a background render projects, and the render must not push the play's out.
final class SpeechProjectionMemo: @unchecked Sendable {
    enum Kind { case speech, systemSpeech }

    /// About 20 KB of text and up: below it the projection takes a few milliseconds, and streamed chunks come through here.
    static let minimumBytes = 20_000
    /// Above this the projection's offsets alone would be tens of megabytes, so it is computed and not kept.
    static let maximumBytes = 4_000_000
    static let slotsPerKind = 3
    /// All kinds together, newest kept: a few long articles, never several books.
    static let totalBytes = 6_000_000

    private struct Entry { let kind: Kind; let source: String; let projection: NormalizedSpeechText }
    private let lock = NSLock()
    private var entries: [Entry] = [] // oldest first

    static func holds(utf8Count: Int) -> Bool { utf8Count >= minimumBytes && utf8Count <= maximumBytes }

    /// Whether `copies` projections of one text stay inside the byte budget together.
    static func fits(utf8Count: Int, copies: Int) -> Bool { utf8Count * copies <= totalBytes }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
    }

    private func find(_ source: String, _ kind: Kind) -> Int? {
        entries.firstIndex { $0.kind == kind && Self.same($0.source, source) }
    }

    func projection(of source: String, kind: Kind, compute: () -> NormalizedSpeechText) -> NormalizedSpeechText {
        guard Self.holds(utf8Count: source.utf8.count) else { return compute() }
        lock.lock()
        if let index = find(source, kind) {
            let entry = entries.remove(at: index)
            entries.append(entry) // used last
            lock.unlock()
            return entry.projection
        }
        lock.unlock()
        let projection = compute()
        lock.lock()
        if find(source, kind) == nil { entries.append(Entry(kind: kind, source: source, projection: projection)) }
        trim()
        lock.unlock()
        return projection
    }

    private func trim() {
        for kind in [Kind.speech, .systemSpeech] {
            while entries.filter({ $0.kind == kind }).count > Self.slotsPerKind,
                  let oldest = entries.firstIndex(where: { $0.kind == kind }) {
                entries.remove(at: oldest)
            }
        }
        while entries.count > 1, entries.reduce(0, { $0 + $1.source.utf8.count }) > Self.totalBytes {
            entries.removeFirst()
        }
    }

    func forget() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func remembers(_ source: String, kind: Kind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return find(source, kind) != nil
    }
}
