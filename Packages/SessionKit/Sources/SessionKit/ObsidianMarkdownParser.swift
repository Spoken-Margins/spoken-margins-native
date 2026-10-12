import Foundation

public enum DeterministicListeningMapPolicy: Equatable, Sendable {
    /// For every text source that has headings (web article, pasted text, Markdown or text file): the
    /// chapters are the author's headings at one level, in order, with the author's titles (#1468).
    /// A section is never merged into another however short it is (#1435). Only a very long one is
    /// split, at its sub-headings where it has them. Substantial text before the first heading, with
    /// the title heading that heads it, is a chapter of its own (#1435). A source with fewer than two
    /// headings at any level gets no map here, and the generated map takes over.
    case authoredSections
    case canonicalHeadings
}

public struct ParsedObsidianMarkdown: Equatable, Sendable {
    private static let minimumHeadingsPerLevel = 3
    private static let minimumHeadingsAtFallbackLevel = 2
    private static let canonicalMinimumChapterCount = 5
    private static let estimatedWordsPerMinute = 180
    /// A section over about 20 minutes is split; the parts aim at about 10 minutes each.
    private static let veryLongChapterWords = estimatedWordsPerMinute * 20
    private static let splitTargetWords = estimatedWordsPerMinute * 10
    /// Text before a long section's first sub-heading that is shorter than this (little more than the
    /// section's own heading line) isn't a chapter of its own.
    private static let minimumLeadWords = 20

    private struct DraftChapter {
        var baseTitle: String
        var partNumber: Int
        var level: Int
        var startChar: Int
        var endChar: Int

        var title: String {
            partNumber == 1 ? baseTitle : "\(baseTitle) — part \(partNumber)"
        }
    }

    public let title: String
    public let text: String
    public let source: String?
    public let metadata: [String: String]
    public let headings: [ParsedMarkdownHeading]
    /// Where a closing run of footnote definitions or a trailing "References"-style section starts,
    /// or nil when the text doesn't end in one (#124).
    public var notesStartChar: Int? = nil
    /// True when no front matter, heading or override gave the title and `parse`'s `fallbackTitle`
    /// was used as given.
    public var titleIsFallback = false

    public func deterministicListeningMap(
        itemId: String,
        policy: DeterministicListeningMapPolicy = .authoredSections
    ) -> ListeningMap? {
        guard !headings.isEmpty, !text.isEmpty else { return nil }
        let ordered = normalizedContentHeadings()
        guard !ordered.isEmpty else { return nil }
        // Text maps end the authored sections where the notes start and give the notes one chapter of
        // their own, so the tail is never split into "— part N" chapters of the last section (#124).
        // Canonical maps keep their authored headings.
        let adaptive = policy == .authoredSections
        let notesStart = adaptive ? notesStartChar.flatMap { start in
            ordered.contains { $0.startChar < start } && start < text.count ? start : nil
        } : nil
        let contentEnd = notesStart ?? text.count
        let selected: [ParsedMarkdownHeading]
        switch policy {
        case .authoredSections:
            selected = headingsAtOneLevel(from: ordered.filter { $0.startChar < contentEnd })
            // One heading is not a table of contents; the generated map is better than a single chapter.
            guard selected.count >= Self.minimumHeadingsAtFallbackLevel else { return nil }
        case .canonicalHeadings:
            // Preserve a flat anthology verbatim, but project deeply nested
            // authored structure at the shallowest useful depth for listening.
            // The source text still retains every subheading; the Timeline no
            // longer turns each subsection into a near-duplicate chapter.
            selected = headingsAtUsefulDepth(from: ordered)
        }

        let canonicalPrefix = selected.first.map {
            String(text.prefix($0.startChar)).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        let hasAuthoredFrontMatter = policy == .canonicalHeadings
            && !canonicalPrefix.isEmpty
            && Self.normalizedTitle(canonicalPrefix) != Self.normalizedTitle(title)

        // Text before the first chapter heading is a chapter of its own when it's substantial: the
        // listener hears the title and its preamble as that, not as the start of the first section, and
        // the first section starts at its own heading (#1435). It is named by the title heading that
        // heads it (the lone `#`), else by the item's title. A line or two of preamble is folded into
        // the first chapter, as before.
        // The heading at 0, if any, must be the title: the only heading at its level. A section heading
        // there (`## Group 1` with `###` chapters under it, and another `## Group 2`) has no title above
        // it, and its intro stays with its first sub-section, as the later groups' intros do.
        let titleHeading = headings.first { $0.startChar == 0 && $0.level < (selected.first?.level ?? 1) }
        let leadIsTitled = titleHeading.map { heading in headings.filter { $0.level == heading.level }.count == 1 } ?? true
        let leadChapterEnd: Int? = {
            guard adaptive, leadIsTitled, let first = selected.first, first.startChar > 0 else { return nil }
            let words = String(text.prefix(first.startChar)).split(whereSeparator: \.isWhitespace).count
            return words >= Self.minimumLeadWords ? first.startChar : nil
        }()

        var drafts: [DraftChapter] = []
        if let leadChapterEnd {
            drafts.append(DraftChapter(
                baseTitle: titleHeading?.title ?? title,
                partNumber: 1,
                level: 0,
                startChar: 0,
                endChar: leadChapterEnd
            ))
        }
        if hasAuthoredFrontMatter, let firstHeading = selected.first {
            drafts.append(DraftChapter(
                baseTitle: "Front Matter",
                partNumber: 1,
                level: 1,
                startChar: 0,
                endChar: firstHeading.startChar
            ))
        }

        drafts.append(contentsOf: selected.enumerated().map { index, heading in
            DraftChapter(
                baseTitle: heading.title,
                partNumber: 1,
                level: heading.level,
                startChar: index == 0 && leadChapterEnd == nil && (adaptive || !hasAuthoredFrontMatter)
                    ? 0
                    : heading.startChar,
                endChar: index + 1 < selected.count ? selected[index + 1].startChar : contentEnd
            )
        })
        if adaptive {
            splitVeryLongChapters(&drafts, subheadings: ordered.filter { $0.startChar < contentEnd })
        }
        if let notesStart {
            drafts.append(DraftChapter(
                baseTitle: "Notes and references",
                partNumber: 1,
                level: 1,
                startChar: notesStart,
                endChar: text.count
            ))
        }
        let chapters = drafts.enumerated().map { index, draft in
            return Chapter(
                id: "ch-markdown-\(String(format: "%02d", index + 1))-\(Self.slug(draft.title))",
                title: draft.title,
                startChar: draft.startChar,
                endChar: max(draft.startChar, draft.endChar),
                percent: min(100, max(0, Int((Double(draft.startChar) / Double(text.count)) * 100)))
            )
        }
        return ListeningMap(
            id: "map-\(itemId)-markdown",
            itemId: itemId,
            overview: ListeningMapOverviewText.appGenerated(title: title, chapterCount: chapters.count),
            chapters: chapters
        )
    }

    private func normalizedContentHeadings() -> [ParsedMarkdownHeading] {
        var seenOffsets = Set<Int>()
        var ordered = headings
            .sorted { lhs, rhs in
                lhs.startChar == rhs.startChar ? lhs.level < rhs.level : lhs.startChar < rhs.startChar
            }
            .filter { seenOffsets.insert($0.startChar).inserted }
        if let first = ordered.first,
           first.startChar == 0,
           Self.normalizedTitle(first.title) == Self.normalizedTitle(title) {
            ordered.removeFirst()
        }
        return ordered
    }

    /// The chapter level: the shallowest level with at least three headings, else the shallowest with two.
    /// One level only, so a page with four `##` and thirty `###` has four chapters, and the `###` are
    /// sub-headings of those.
    private func headingsAtOneLevel(from ordered: [ParsedMarkdownHeading]) -> [ParsedMarkdownHeading] {
        let counts = Dictionary(grouping: ordered, by: \.level).mapValues(\.count)
        for minimum in [Self.minimumHeadingsPerLevel, Self.minimumHeadingsAtFallbackLevel] {
            if let level = counts.keys.sorted().first(where: { counts[$0, default: 0] >= minimum }) {
                return ordered.filter { $0.level == level }
            }
        }
        return []
    }

    /// For a canonical (PDF) map: every heading down to the first level at which there are enough.
    private func headingsAtUsefulDepth(from ordered: [ParsedMarkdownHeading]) -> [ParsedMarkdownHeading] {
        let levels = Array(Set(ordered.map(\.level))).sorted()
        var selected = ordered
        for level in levels {
            let candidates = ordered.filter { $0.level <= level }
            selected = candidates
            if candidates.count >= Self.canonicalMinimumChapterCount {
                break
            }
        }
        return selected
    }

    /// Splits only a section over about 20 minutes: at the sub-headings it has (the shallowest level
    /// below its own), named by them, and any part still that long at natural breaks as "— part N".
    private func splitVeryLongChapters(_ drafts: inout [DraftChapter], subheadings: [ParsedMarkdownHeading]) {
        let characters = Array(text)
        var result: [DraftChapter] = []
        for draft in drafts {
            guard wordCount(in: draft, characters: characters) > Self.veryLongChapterWords else {
                result.append(draft)
                continue
            }
            let inside = subheadings.filter { $0.level > draft.level && $0.startChar > draft.startChar && $0.startChar < draft.endChar }
            var parts = [draft]
            if let level = inside.map(\.level).min() {
                let boundaries = inside.filter { $0.level == level }
                parts = []
                var start = draft.startChar
                var title = draft.baseTitle
                for boundary in boundaries {
                    let lead = DraftChapter(baseTitle: title, partNumber: 1, level: draft.level, startChar: start, endChar: boundary.startChar)
                    if parts.isEmpty, wordCount(in: lead, characters: characters) < Self.minimumLeadWords {
                        // The heading line and a few words: the first sub-section takes them with it.
                    } else {
                        parts.append(lead)
                        start = boundary.startChar
                    }
                    title = boundary.title
                }
                parts.append(DraftChapter(baseTitle: title, partNumber: 1, level: level, startChar: start, endChar: draft.endChar))
            }
            for part in parts {
                result.append(contentsOf: splitAtNaturalBreaks(part, characters: characters))
            }
        }
        drafts = result
    }

    private func splitAtNaturalBreaks(_ draft: DraftChapter, characters: [Character]) -> [DraftChapter] {
        let words = wordCount(in: draft, characters: characters)
        guard words > Self.veryLongChapterWords else { return [draft] }
        let partCount = max(2, Int((Double(words) / Double(Self.splitTargetWords)).rounded()))
        var parts: [DraftChapter] = []
        var remaining = draft
        var partsLeft = partCount
        let target = words / partCount
        while partsLeft > 1 {
            guard target > 0, let split = naturalSplitOffset(in: remaining, targetWords: target, characters: characters) else { break }
            var head = remaining
            head.endChar = split
            parts.append(head)
            remaining.startChar = split
            remaining.partNumber += 1
            partsLeft -= 1
        }
        parts.append(remaining)
        return parts
    }

    private func wordCount(in draft: DraftChapter, characters: [Character]) -> Int {
        let start = max(0, min(draft.startChar, characters.count))
        let end = max(start, min(draft.endChar, characters.count))
        return String(characters[start..<end]).split(whereSeparator: \.isWhitespace).count
    }

    private func naturalSplitOffset(in draft: DraftChapter, targetWords: Int, characters: [Character]) -> Int? {
        let start = max(0, min(draft.startChar, characters.count))
        let end = max(start, min(draft.endChar, characters.count))
        var words = 0
        var insideWord = false
        var candidate: Int?
        for index in start..<end {
            if characters[index].isWhitespace {
                insideWord = false
            } else if !insideWord {
                words += 1
                insideWord = true
                if words == targetWords {
                    candidate = index
                    break
                }
            }
        }
        guard let candidate else { return nil }
        let lower = max(start + 1, candidate - 400)
        let upper = min(end - 1, candidate + 400)
        guard lower < upper else { return nil }

        let paragraphBoundaries = (lower...upper).filter { index in
            index > start && characters[index - 1] == "\n" && characters[index] == "\n"
        }
        if let closest = paragraphBoundaries.min(by: { abs($0 - candidate) < abs($1 - candidate) }) {
            return closest + 1
        }
        let sentenceBoundaries = (lower...upper).filter { index in
            ".!?".contains(characters[index - 1]) && characters[index].isWhitespace
        }
        if let closest = sentenceBoundaries.min(by: { abs($0 - candidate) < abs($1 - candidate) }) {
            return closest
        }
        return candidate
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private static func slug(_ value: String) -> String {
        let slug = value.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "section" : slug).prefix(48))
    }
}

public struct ParsedMarkdownHeading: Equatable, Sendable {
    public let level: Int
    public let title: String
    public let startChar: Int
}

public enum ObsidianMarkdownParser {
    /// - Parameter fallbackTitle: the title to use, exactly as given, when neither the override, the
    ///   front matter nor a heading has one. Pass it when the name isn't a file name, such as a web
    ///   page's title: `fileName` is read as a path, so `v1.5 release` would lose `.5 release`.
    public static func parse(
        fileName: String,
        contents: String,
        titleOverride: String? = nil,
        fallbackTitle: String? = nil
    ) throws -> ParsedObsidianMarkdown {
        let parsed = splitFrontmatter(contents)
        let explicitTitle = firstNonEmpty([titleOverride, parsed.metadata["title"], firstMarkdownHeading(in: parsed.body)])
        let givenTitle = explicitTitle == nil ? firstNonEmpty([fallbackTitle]) : nil
        let title = explicitTitle.map(unquote) ?? givenTitle ?? fileNameTitle(fileName)
        let cleaned = cleanBody(parsed.body)
        guard !cleaned.text.isEmpty else {
            throw SessionKitError.persistenceFailed("obsidian_import_empty_text")
        }
        return ParsedObsidianMarkdown(
            title: title,
            text: cleaned.text,
            source: parsed.metadata["source"].map(unquote),
            metadata: parsed.metadata,
            headings: cleaned.headings,
            notesStartChar: cleaned.notesStartChar,
            titleIsFallback: givenTitle != nil
        )
    }

    /// The title a file name gives: its name without the extension, quotes trimmed.
    public static func fileNameTitle(_ fileName: String) -> String {
        unquote(firstNonEmpty([(fileName as NSString).deletingPathExtension]) ?? "Imported Markdown")
    }

    private static func splitFrontmatter(_ contents: String) -> (metadata: [String: String], body: String) {
        guard contents.hasPrefix("---") else {
            return ([:], contents)
        }
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else {
            return ([:], contents)
        }
        var metadata: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line == "---" {
                let body = lines.dropFirst(index + 1).joined(separator: "\n")
                return (metadata, body)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !value.isEmpty {
                    metadata[key] = unquote(value)
                }
            }
            index += 1
        }
        return (metadata, contents)
    }

    private enum NotesLine {
        case other
        case definition
        case continuation
    }

    private static func cleanBody(_ body: String) -> (text: String, headings: [ParsedMarkdownHeading], notesStartChar: Int?) {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        // Parallel to `output`; nil for the blank separators.
        var notesLines: [NotesLine?] = []
        var headings: [(level: Int, title: String, outputIndex: Int, boldOnly: Bool)] = []
        var skippingTimestampBlock = false
        var lineIsBoldOnly = false

        for (lineIndex, rawLine) in lines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if output.last?.isEmpty == false {
                    output.append("")
                    notesLines.append(nil)
                }
                skippingTimestampBlock = false
                continue
            }
            if line.localizedCaseInsensitiveContains("timestamps"),
               line.replacingOccurrences(of: #"[^\p{L}]"#, with: "", options: .regularExpression).localizedCaseInsensitiveContains("timestamps") {
                skippingTimestampBlock = true
                continue
            }
            if skippingTimestampBlock, isTimestampIndexLine(line) {
                continue
            }
            if line.range(of: #"^!\[[^\]]*\]\([^)]+\)$"#, options: .regularExpression) != nil {
                continue
            }

            // Preserve explicit Setext headings, and standalone bold lines as headings when the text has
            // no real ones (below), from pasted text.
            lineIsBoldOnly = false
            if lineIndex + 1 < lines.count,
               lines[lineIndex + 1].trimmingCharacters(in: .whitespaces).range(of: #"^(?:={3,}|-{3,})$"#, options: .regularExpression) != nil,
               !line.isEmpty {
                line = (lines[lineIndex + 1].contains("=") ? "# " : "## ") + line
            } else if line.range(of: #"^(?:={3,}|-{3,})$"#, options: .regularExpression) != nil {
                continue
            } else if line.range(of: #"^\*\*[^*\n]{1,160}\*\*:?$"#, options: .regularExpression) != nil {
                line = "## " + line
                lineIsBoldOnly = true
            }
            if let heading = markdownHeading(in: line) {
                headings.append((heading.level, heading.title, output.count, lineIsBoldOnly))
            }
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            line = stripTranscriptTimestampPrefix(line)
            line = line.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(?<!\*)\*([^*]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\\([\\`*{}\[\]()#+\-.!_>])"#, with: "$1", options: .regularExpression)
            let notesLine: NotesLine
            if line.range(of: #"^\[\^[^\]]+\]:"#, options: .regularExpression) != nil {
                notesLine = .definition
            } else if rawLine.first?.isWhitespace == true,
                      [.definition, .continuation].contains(notesLines.last(where: { $0 != nil }) ?? nil) {
                // An indented line continues the footnote above it.
                notesLine = .continuation
            } else {
                notesLine = .other
            }
            line = SpeechTextNormalizer.normalizeImportedText(line)
            if !line.isEmpty {
                output.append(line)
                notesLines.append(notesLine)
            }
        }

        let text = output
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A bold line is a heading only in a text with no real ones: "**Key point:**" lead-ins in an
        // article are not peers of its `##` sections (#1468).
        // (A lone top-level heading is the title, not a section.)
        var realHeadings = headings.filter { !$0.boldOnly }
        if realHeadings.first?.level == 1, realHeadings.filter({ $0.level == 1 }).count == 1 {
            realHeadings.removeFirst()
        }
        let hasRealHeadings = !realHeadings.isEmpty
        let resolvedHeadings = headings.filter { !hasRealHeadings || !$0.boldOnly }.compactMap { heading -> ParsedMarkdownHeading? in
            guard heading.outputIndex < output.count else { return nil }
            let prefix = output.prefix(heading.outputIndex).joined(separator: "\n")
            let start = prefix.isEmpty ? 0 : prefix.count + 1
            return ParsedMarkdownHeading(level: heading.level, title: heading.title, startChar: min(start, text.count))
        }
        let notesStart = [
            closingFootnotesStart(notesLines).map { index -> Int in
                let prefix = output.prefix(index).joined(separator: "\n")
                return min(prefix.isEmpty ? 0 : prefix.count + 1, text.count)
            },
            closingNotesHeadingStart(resolvedHeadings)
        ].compactMap { $0 }.min()
        return (text, resolvedHeadings, notesStart)
    }

    /// The output line where the text's closing run of footnote definitions starts: at least three
    /// `[^n]: …` definitions, with only their indented continuations and blank lines between them
    /// and the end.
    private static func closingFootnotesStart(_ lines: [NotesLine?]) -> Int? {
        var start: Int?
        var definitions = 0
        for index in lines.indices.reversed() {
            switch lines[index] {
            case .none, .some(.continuation):
                continue
            case .some(.definition):
                start = index
                definitions += 1
            case .some(.other):
                return definitions >= 3 ? start : nil
            }
        }
        return definitions >= 3 ? start : nil
    }

    /// The start of the text's closing "References" / "Notes" / "Bibliography" section, when every
    /// heading from it to the end is one of those and an authored heading comes before it.
    private static func closingNotesHeadingStart(_ headings: [ParsedMarkdownHeading]) -> Int? {
        var start: Int?
        for heading in headings.reversed() {
            guard isNotesTitle(heading.title) else { break }
            start = heading.startChar
        }
        guard let start, headings.contains(where: { $0.startChar < start }) else { return nil }
        return start
    }

    /// Titles that only ever head a list of notes or sources. A plain "Notes" section is often the
    /// author's (or the listener's own Obsidian) prose, so it isn't one; its footnote definitions
    /// are still found by `closingFootnotesStart`.
    private static let notesTitles: Set<String> = [
        "references", "bibliography", "footnotes", "endnotes", "workscited", "literaturecited",
        "notesandreferences", "referencesandnotes"
    ]

    private static func isNotesTitle(_ title: String) -> Bool {
        let letters = title.lowercased().replacingOccurrences(of: #"[^\p{L}]+"#, with: "", options: .regularExpression)
        return notesTitles.contains(letters)
    }

    private static func markdownHeading(in line: String) -> (level: Int, title: String)? {
        guard let match = line.firstMatch(of: /^(#{1,6})\s+(.+)$/) else { return nil }
        var title = String(match.2)
        title = title.replacingOccurrences(of: #"\\([\\`*{}\[\]()#+\-.!_>])"#, with: "$1", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        title = title.replacingOccurrences(of: #"(?<!\*)\*([^*]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
        title = title.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        title = SpeechTextNormalizer.normalize(title)
        guard !title.isEmpty else { return nil }
        return (match.1.count, title)
    }

    private static func isTimestampIndexLine(_ line: String) -> Bool {
        line.range(of: #"^\d{1,2}:\d{2}(?::\d{2})?\s+[-–—]\s+.+"#, options: .regularExpression) != nil
    }

    private static func stripTranscriptTimestampPrefix(_ line: String) -> String {
        let patterns = [
            #"^\*\*\d{1,2}:\d{2}(?::\d{2})?\*\*\s*[·\-–—]\s*"#,
            #"^\d{1,2}:\d{2}(?::\d{2})?\s*[·\-–—]\s*"#
        ]
        return patterns.reduce(line) { current, pattern in
            current.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private static func firstMarkdownHeading(in body: String) -> String? {
        body.components(separatedBy: .newlines).first { line in
            line.range(of: #"^#\s+\S"#, options: .regularExpression) != nil
        }?.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
