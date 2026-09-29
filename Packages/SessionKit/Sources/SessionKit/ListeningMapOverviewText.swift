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
        let count = chapterCount > 0 ? "\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")." : ""
        let heading = sentence(title)
        return [heading, count].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The text spoken before the item, including its trailing paragraph break, or "" for none.
    public static func spokenPreface(overview: String, title: String, chapterCount: Int) -> String {
        let trimmed = overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == appGenerated(title: title, chapterCount: chapterCount) {
            return "\(trimmed)\n\n"
        }
        if isLegacyAppGenerated(trimmed) {
            let replacement = appGenerated(title: title, chapterCount: chapterCount)
            return replacement.isEmpty ? "" : "\(replacement)\n\n"
        }
        return "Overview. \(trimmed)\n\n"
    }

    /// Sentences earlier builds stored as the overview of maps they derived themselves.
    static func isLegacyAppGenerated(_ overview: String) -> Bool {
        legacyPrefixes.contains { overview.hasPrefix($0) }
    }

    private static let legacyPrefixes = [
        "Structured into ",              // Markdown and canonical headings
        "Generated Listening Map ",      // "…with N chapters for <title>." / "…for <title>."
        "Publisher-provided chapters for ",
        "Authored navigation from ",
    ]

    private static func sentence(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
