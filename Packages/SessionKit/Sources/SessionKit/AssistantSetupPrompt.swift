import Foundation

/// The prompt a listener copies into their own AI (Claude, ChatGPT or another) so it writes a daily brief and
/// suggests shows in the link list format the app reads (#4683, Design section 2c).
///
/// The text is built here, with the date, locale, time zone, the listener's notes and the Quick Folder's name passed
/// in, so a host test can feed the example block in it to `LinkListText.find` and prove the prompt never teaches a
/// format the app refuses. The Your AI screen in Settings copies and shares it (PR 4 of #4683).
public enum AssistantSetupPrompt {
    /// Where the Your AI screen keeps what the listener's brief is for. It stays on the phone and goes into the prompt only
    /// when they copy or share it.
    public static let notesDefaultsKey = "aiBriefNotesV1"
    /// The most characters of the listener's notes that go into the prompt.
    public static let maxNotesCharacters = 500
    /// How many things the prompt asks a daily brief to hold. A prompt constant, not a `LinkListFile` limit.
    public static let briefItemCount = 8

    /// The prompt's opening sentence. Paste & go recognises the prompt by it, so the prompt's own example list (two
    /// example.com links) is never added as a brief when a listener taps Paste after copying the prompt.
    static let firstSentence = "I use Spoken Margins, an iPhone app that reads articles aloud and plays podcasts."

    /// Whether `text` is this prompt (or holds it, as a chat app's copy can with a line around it).
    public static func isPrompt(_ text: String) -> Bool {
        text.contains(firstSentence)
    }

    /// - Parameters:
    ///   - date: the day the prompt is copied; it names the example title ("Morning brief, November 23").
    ///   - locale: the phone's locale, which writes the month and day.
    ///   - timeZone: the phone's time zone, which decides what day it is.
    ///   - notes: what the listener's brief is for, or nil. Left out when it is empty after cleaning.
    ///   - quickFolderName: the chosen Quick Folder's name, or nil when none is chosen.
    public static func make(
        date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        notes: String? = nil,
        quickFolderName: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("\(firstSentence) Please help me with two things.")
        lines.append("")
        lines.append("1. A daily brief. When I ask, or on a schedule I set up with you, pick up to \(briefItemCount) things worth my time today: articles, newsletter posts, podcast episodes or PDFs. Use each one's own page; for a podcast episode, an Apple Podcasts episode link if you can. Open each link if you can browse, and leave out any that don't load.")
        if let notes = cleanedNotes(notes) {
            lines.append("What my brief is for: \(notes)")
        }
        lines.append("")
        lines.append("2. Shows and newsletters to follow. When you find one I'd like, add its RSS feed link with \"follow\": true. Use the feed itself (for many newsletters, the address ending in /feed), never a podcasts.apple.com link. Spoken Margins asks me before following anything, so suggest freely, at most \(LinkListFile.maxFollows) at a time.")
        lines.append("")
        lines.append("Always answer with one JSON code block in exactly this format:")
        lines.append("")
        lines.append("```json")
        lines.append("{")
        lines.append("  \"schemaVersion\": \"\(LinkListFile.schemaVersion)\",")
        lines.append("  \"title\": \"Morning brief, \(dayName(date, locale: locale, timeZone: timeZone))\",")
        lines.append("  \"entries\": [")
        lines.append("    { \"url\": \"https://example.com/article\" },")
        lines.append("    { \"url\": \"https://example.com/episode\" },")
        lines.append("    { \"url\": \"https://example.com/feed\", \"follow\": true }")
        lines.append("  ]")
        lines.append("}")
        lines.append("```")
        lines.append("")
        lines.append("Rules: every link starts with https://. At most \(LinkListFile.maxEntries) entries. Put today's date in the title. Entries play in the order you list them.")
        lines.append("")
        lines.append("How it gets to my phone: I copy your reply and paste it into Spoken Margins.")
        if let folder = cleanedFolderName(quickFolderName) {
            lines.append("If you can save files, save the block as a .json file with today's date in its name, in my folder named \"\(folder)\", instead.")
        }
        lines.append("")
        lines.append("If I share \"Spoken Margins listening signals.jsonl\", it lists what I finished, shared and left Margins on, for shows I follow, as counts and titles. Use it to learn what I like. If I share an AI Handoff Markdown file, it holds my Margins' words; use them only to help me.")
        lines.append("")
        lines.append("You can't change my settings, but you can tell me where they are: voices and speaking rate are in Settings > Voice; your Quick Folder is in Settings > Import & Export > Your AI; Quiet and Unfollow this show are on a show's screen in Following.")
        return lines.joined(separator: "\n")
    }

    /// The notes as they go into the prompt: each newline becomes a space, each backtick becomes `'` (so the notes
    /// can't open a code fence in the listener's AI), the ends are trimmed, and the text is cut to
    /// `maxNotesCharacters`. Nil when nothing is left.
    static func cleanedNotes(_ notes: String?) -> String? {
        guard let notes else { return nil }
        // Trimmed before the cut, so leading spaces don't use up the limit, and after it, so the cut can't end on one.
        let trimmed = flatten(notes, backticks: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(maxNotesCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? nil : cut
    }

    /// The folder's name as it goes between double quotes: a `"` becomes `'`, newlines become spaces, and the name is
    /// otherwise left as it is, so the AI is told the name the listener chose. Nil when empty.
    static func cleanedFolderName(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = flatten(name, backticks: false).replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func flatten(_ text: String, backticks: Bool) -> String {
        var result = ""
        for character in text {
            switch character {
            case "`" where backticks: result.append("'")
            // `Character` treats "\r\n" as one character, so a Windows line ending becomes one space.
            case _ where character.isNewline: result.append(" ")
            default: result.append(character)
            }
        }
        return result
    }

    private static func dayName(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
            .month(.wide)
            .day()
        return date.formatted(style)
    }
}
