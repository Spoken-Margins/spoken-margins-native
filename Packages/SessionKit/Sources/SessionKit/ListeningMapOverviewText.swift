import Foundation

/// What a listener hears before an item's text (#356). A map the app built from the item's
/// own structure says only "<Title>. N chapters.", so the first thing heard is the title.
/// Older builds stored a sentence about how the map was made ("Structured into eight
/// listening chapters from canonical document headings in …"). Those stored maps are not
/// rewritten; the preface replaces the old sentence when it is spoken. A real summary (an AI
/// listening edition) keeps its "Overview." label.
public enum ListeningMapOverviewText {
    /// The overview for a map the app derived from headings, chapters or navigation.
    public static func appGenerated(title: String, chapterCount: Int) -> String {
        let count = countSentence(chapterCount)
        let heading = sentence(title)
        return [heading, count].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The text spoken before the item, including its trailing paragraph break, or "" for none.
    /// `textOpening` is the start of the text spoken after the preface. When it opens with the
    /// title, an app-made preface leaves the title out and says only the chapter count, so the
    /// listener doesn't hear the title twice in the first few seconds (#1144, owner's pick).
    public static func spokenPreface(overview: String, title: String, chapterCount: Int, textOpening: String = "") -> String {
        let trimmed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed == appGenerated(title: title, chapterCount: chapterCount)
            || isLegacyAppGenerated(trimmed, title: title) else {
            return "Overview. \(trimmed)\n\n"
        }
        let preface = textOpens(textOpening, with: title)
            ? countSentence(chapterCount)
            : appGenerated(title: title, chapterCount: chapterCount)
        return preface.isEmpty ? "" : "\(preface)\n\n"
    }

    /// Whether the spoken text starts with the title, ignoring case, accents, punctuation,
    /// symbols such as a Markdown "#", and how the words are spaced or broken across lines.
    /// The title must end on a word boundary, so "Agents" does not match a text opening "Agentsia".
    static func textOpens(_ text: String, with title: String) -> Bool {
        let titleWords = comparableWords(title)
        guard !titleWords.isEmpty else { return false }
        let textWords = comparableWords(String(text.prefix(title.count * 2 + 200)))
        return textWords.starts(with: titleWords)
    }

    private static func countSentence(_ chapterCount: Int) -> String {
        chapterCount > 0 ? "\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")." : ""
    }

    private static func comparableWords(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// Sentences earlier builds stored as the overview of maps they derived themselves. The
    /// whole sentence must match, not just its opening words, so a real summary that happens to
    /// start "Structured into three experiments, …" keeps its text. The two sentences that are
    /// only a phrase plus the title match only with the item's own title.
    static func isLegacyAppGenerated(_ overview: String, title: String) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if overview == "Publisher-provided chapters for \(trimmedTitle)."
            || overview == "Authored navigation from \(trimmedTitle)." {
            return true
        }
        let range = NSRange(overview.startIndex..., in: overview)
        return legacySentencePatterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return false }
            return regex.firstMatch(in: overview, range: range) != nil
        }
    }

    private static let legacySentencePatterns: [String] = [
        // Markdown and canonical headings: "Structured into 8 listening chapters from … in <title>."
        #"^Structured into \S+ listening chapters? from (canonical document headings|the Markdown hierarchy) in .+\.$"#,
        // "Generated Listening Map with N chapters for <title>." / "Generated Listening Map for <title>."
        #"^Generated Listening Map (with \S+ chapters? )?for .+\.$"#,
    ]

    private static func sentence(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
