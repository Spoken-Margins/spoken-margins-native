import Foundation

/// One scene of an article or PDF that the on-device model can summarise (#3450).
///
/// `startChar` and `endChar` are positions in the item's text as `Character` offsets, the unit the rest of the app
/// uses for text (`Chapter`, `Interjection.anchor`). `modelText` is what the model reads and the summary is checked
/// against: the scene's text without running heads and page numbers. The offsets always refer to the original text.
public struct TextSceneDraft: Equatable, Sendable {
    public let id: String
    public let order: Int
    public let startChar: Int
    public let endChar: Int
    /// The rule-based chapter title this scene grew from, which a scene without a model label keeps.
    public let fallbackTitle: String
    public let modelText: String
    /// False for a scene with too little to say for the model to summarise (a heading with no body, a stray line).
    public let isSummarizable: Bool

    public init(
        id: String, order: Int, startChar: Int, endChar: Int,
        fallbackTitle: String, modelText: String, isSummarizable: Bool
    ) {
        self.id = id
        self.order = order
        self.startChar = startChar
        self.endChar = endChar
        self.fallbackTitle = fallbackTitle
        self.modelText = modelText
        self.isSummarizable = isSummarizable
    }
}

/// Cuts an article or PDF into the scenes the on-device model summarises, for Skim (#3450). It is the text half of the
/// step a podcast gets from `EpisodeSceneSegmenter`: the same label call and validator read what this returns.
///
/// The sections are the rule-based chapters the item already has, so every scene start is also a chapter start.
/// - A section too short to say anything (a heading with no body) joins the section after it, or the one before it
///   when it is last, so every part of the text is read by some scene.
/// - A section longer than the model's reading limit is split into even pieces at the best break near each cut: a
///   blank line, then a sentence end, then a line end, then any space, then the exact character. Nothing is cut off.
/// - Running heads, page numbers and rule lines that repeat through a PDF are left out of what the model reads.
public enum TextSceneSummaryPlanner {
    /// The most the on-device model reads for one scene (`labelListeningMapChapter` takes the first 6,000 characters).
    public static let maximumSceneCharacters = 6_000
    /// A scene with fewer letters and digits than this, or no sentence at all, has nothing for the model to summarise.
    public static let minimumSummarizableCharacters = 40
    /// The most scenes one text gets, kept below a packet's 200-scene limit (`ListeningMapPacket.maximumScenes`) so a
    /// long PDF's map can still be shared (#3461). A text with more is cut into this many even groups of neighbouring
    /// scenes; each group is one scene and the model reads the first part of it.
    public static let maximumScenes = 190

    public static func plan(
        text: String,
        chapters: [Chapter],
        maximumSceneCharacters: Int = TextSceneSummaryPlanner.maximumSceneCharacters,
        maximumScenes: Int = TextSceneSummaryPlanner.maximumScenes
    ) -> [TextSceneDraft] {
        let characters = Array(text)
        guard !characters.isEmpty, maximumSceneCharacters > 0 else { return [] }
        let furniture = PageFurniture(characters: characters)
        func readable(_ start: Int, _ end: Int) -> String { furniture.modelText(characters, start, end) }
        func isSummarizable(_ text: String) -> Bool { Self.hasSomethingToSummarise(text) }

        let units = merged(sections(of: chapters, count: characters.count), characters: characters, readable: { isSummarizable(readable($0, $1)) })
        var drafts: [TextSceneDraft] = []
        for unit in units {
            let title = unit.title.isEmpty ? "Scene \(drafts.count + 1)" : unit.title
            let pieces = cut(unit.start, unit.end, characters: characters, maximum: maximumSceneCharacters)
            for (index, range) in pieces.enumerated() {
                let model = readable(range.lowerBound, range.upperBound)
                drafts.append(TextSceneDraft(
                    id: index == 0 ? unit.id : "\(unit.id)-part-\(index + 1)",
                    order: drafts.count,
                    startChar: range.lowerBound,
                    endChar: range.upperBound,
                    fallbackTitle: index == 0 ? title : "\(title) (continued)",
                    modelText: model,
                    isSummarizable: isSummarizable(model)
                ))
            }
        }
        return grouped(drafts, maximumScenes: maximumScenes, maximumSceneCharacters: maximumSceneCharacters)
    }

    /// At most `maximumScenes` drafts: more than that are merged, neighbours together, into even groups. A group keeps
    /// its first scene's id and title and covers all of its characters. The model reads the group's first
    /// `maximumSceneCharacters` of readable text, so a summary describes where the group begins.
    static func grouped(_ drafts: [TextSceneDraft], maximumScenes: Int, maximumSceneCharacters: Int) -> [TextSceneDraft] {
        guard maximumScenes > 0, drafts.count > maximumScenes else { return drafts }
        let size = (drafts.count + maximumScenes - 1) / maximumScenes
        return stride(from: 0, to: drafts.count, by: size).enumerated().map { order, from in
            let group = drafts[from..<min(from + size, drafts.count)]
            let first = group.first!
            let readable = group.filter(\.isSummarizable).map(\.modelText).joined(separator: "\n\n")
            return TextSceneDraft(
                id: first.id, order: order, startChar: first.startChar, endChar: group.last!.endChar,
                fallbackTitle: first.fallbackTitle,
                modelText: String(readable.prefix(maximumSceneCharacters)),
                isSummarizable: group.contains(where: \.isSummarizable)
            )
        }
    }

    /// Enough letters to say something, and prose rather than a list of headings: a sentence end somewhere, or one line
    /// of a dozen words or more (text with no punctuation, such as verse or a transcript).
    static func hasSomethingToSummarise(_ text: String) -> Bool {
        let letters = text.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
        guard letters >= minimumSummarizableCharacters else { return false }
        if text.contains(where: { ".!?…。！？".contains($0) }) { return true }
        return text.split(whereSeparator: \.isNewline).contains { $0.split(whereSeparator: { $0.isWhitespace }).count >= 12 }
    }

    // MARK: sections

    struct Section: Equatable {
        var id: String
        var title: String
        var start: Int
        var end: Int
    }

    /// The chapters as consecutive ranges over the whole text: sorted, clamped, each ending where the next begins, the
    /// first starting at zero. No chapters make one section.
    static func sections(of chapters: [Chapter], count: Int) -> [Section] {
        var seen = Set<Int>()
        var ordered: [Chapter] = []
        for chapter in chapters.sorted(by: { ($0.startChar, $0.id) < ($1.startChar, $1.id) }) {
            let start = min(max(0, chapter.startChar), count - 1)
            guard seen.insert(start).inserted else { continue }
            var copy = chapter
            copy.startChar = start
            ordered.append(copy)
        }
        guard !ordered.isEmpty else { return [Section(id: "text-scene-01", title: "", start: 0, end: count)] }
        ordered[0].startChar = 0
        return ordered.enumerated().map { index, chapter in
            Section(
                id: chapter.id, title: chapter.title, start: chapter.startChar,
                end: index + 1 < ordered.count ? ordered[index + 1].startChar : count
            )
        }
    }

    /// A section with nothing to summarise joins the next one; a last one joins the one before it. A text that is all
    /// headings stays one section that is not summarisable.
    static func merged(
        _ sections: [Section], characters: [Character], readable isSummarizable: (Int, Int) -> Bool
    ) -> [Section] {
        var result: [Section] = []
        var carry: Section?
        for section in sections {
            var current = section
            if let held = carry {
                current = Section(id: held.id, title: held.title, start: held.start, end: section.end)
                carry = nil
            }
            if isSummarizable(current.start, current.end) { result.append(current) } else { carry = current }
        }
        if let held = carry {
            if var last = result.popLast() {
                last.end = held.end
                result.append(last)
            } else {
                result.append(held)
            }
        }
        return result
    }

    // MARK: splitting

    /// `start..<end` as pieces of at most `maximum` characters, even in size, cut at the best break near each even
    /// share. The share is worked out again after each cut, so the last piece is never a sliver.
    static func cut(_ start: Int, _ end: Int, characters: [Character], maximum: Int) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var from = start
        while end - from > maximum {
            let remaining = end - from
            let count = (remaining + maximum - 1) / maximum
            let share = remaining / count
            let lowest = max(from + 1, from + Int(Double(share) * 0.7))
            let highest = min(from + maximum, end - 1, from + Int(Double(share) * 1.3))
            let at = bestBreak(characters, near: from + share, lowest: lowest, highest: max(lowest, highest))
            pieces.append(from..<at)
            from = at
        }
        pieces.append(from..<end)
        return pieces
    }

    /// The break nearest `target` within `lowest...highest`, from the strongest kind present; the exact character
    /// `target` when the window has no break at all (unbroken text with no spaces).
    static func bestBreak(_ characters: [Character], near target: Int, lowest: Int, highest: Int) -> Int {
        var best: [Int?] = [nil, nil, nil, nil] // blank line, sentence end, line end, space
        func consider(_ kind: Int, _ position: Int) {
            if let current = best[kind], abs(current - target) <= abs(position - target) { return }
            best[kind] = position
        }
        for position in lowest...highest where position > 0 && position < characters.count {
            let before = characters[position - 1]
            if before.isNewline && position >= 2 && characters[position - 2].isNewline { consider(0, position) }
            if isCJKSentenceEnd(before) || (before.isWhitespace && followsSentenceEnd(characters, position - 1)) { consider(1, position) }
            if before.isNewline { consider(2, position) }
            if before.isWhitespace { consider(3, position) }
        }
        return best.compactMap { $0 }.first ?? min(max(target, lowest), highest)
    }

    private static func isCJKSentenceEnd(_ character: Character) -> Bool { "。！？".contains(character) }

    /// True when the last character before the whitespace run ending at `index` is a sentence end (a closing quote or
    /// bracket after it is allowed).
    private static func followsSentenceEnd(_ characters: [Character], _ index: Int) -> Bool {
        var cursor = index
        while cursor >= 0, characters[cursor].isWhitespace { cursor -= 1 }
        while cursor >= 0, "\"'”’)]»".contains(characters[cursor]) { cursor -= 1 }
        guard cursor >= 0 else { return false }
        return ".!?…".contains(characters[cursor]) || isCJKSentenceEnd(characters[cursor])
    }
}

/// Lines that repeat through a PDF's pages and say nothing about the text: running heads, footers and page numbers.
/// The model never reads them, so a summary can't describe "Journal of Applied Things, 2024" as the topic.
struct PageFurniture {
    /// Lines (trimmed, digits folded) that occur at least this often are furniture.
    static let minimumRepeats = 3
    /// A line longer than this is prose, not a running head.
    static let maximumLength = 70

    private let repeated: Set<String>

    init(characters: [Character]) {
        var counts: [String: Int] = [:]
        for line in String(characters).split(whereSeparator: \.isNewline) {
            guard let key = Self.key(String(line)) else { continue }
            counts[key, default: 0] += 1
        }
        repeated = Set(counts.filter { $0.value >= Self.minimumRepeats }.keys)
    }

    /// The text of `start..<end` with furniture lines removed, lines joined by a newline and the ends trimmed.
    func modelText(_ characters: [Character], _ start: Int, _ end: Int) -> String {
        guard start < end else { return "" }
        let slice = String(characters[start..<end])
        return slice.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { line in
                let text = String(line)
                if Self.isPageNumber(text) { return false }
                guard let key = Self.key(text) else { return true }
                return !repeated.contains(key)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil for a blank line, a long line, one that ends like a sentence, or one that is only digits. None is furniture
    /// by repeating: a running head is a title, not a sentence, so "Sentence 4 about the market." repeated with another
    /// number stays text; and digits fold to one key, so three bare page numbers would otherwise make "1990" repeat too.
    /// Bare page numbers go through `isPageNumber` instead.
    private static func key(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength, let last = trimmed.last,
              !".!?…。！？".contains(last), !trimmed.allSatisfy(\.isNumber) else { return nil }
        let folded = trimmed.lowercased().map { $0.isNumber ? "#" : $0 }
        let collapsed = String(folded).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.replacingOccurrences(of: "##+", with: "#", options: .regularExpression)
    }

    /// "12", "Page 3 of 10", "- 4 -": a line that is only a page number, whatever else is on the page. A bare number of
    /// four digits is a year or a figure in the text ("1990"), so only "Page N" and "N of M" go that high.
    private static func isPageNumber(_ line: String) -> Bool {
        let pattern = #"^\s*[-–—]?\s*(\d{1,3}|page\s+\d{1,4}|\d{1,4}\s*(of|/)\s*\d{1,4})(\s*(of|/)\s*\d{1,4})?\s*[-–—]?\s*$"#
        return line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
