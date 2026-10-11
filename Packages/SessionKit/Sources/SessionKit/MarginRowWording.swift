import Foundation

/// What a row in the Margins tab says about a Margin and where it sits (#777). Computed from what is stored, so
/// nothing here touches the database.
public enum MarginRowWording {
    /// A Margin made within this many days shows its weekday ("Tue"); an older one shows the date too.
    public static let recentDays = 7

    /// "Ch. 3 · 21:03 · Tue": where in the source it was made, then the day.
    /// - `placeName`: the chapter or listening-map scene, when there is one.
    /// - Position: the clock time for media, "paragraph N" for text, else the rough percent.
    public static func placeLine(
        placeName: String? = nil,
        mediaTimeMs: Int?,
        paragraph: Int? = nil,
        roughPercent: Int,
        createdAt: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var parts: [String] = []
        if let name = placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { parts.append(name) }
        if let mediaTimeMs {
            parts.append(MarginDeepLink.clockPosition(ms: mediaTimeMs))
        } else if let paragraph, paragraph > 0 {
            parts.append("paragraph \(paragraph)")
        } else {
            parts.append("\(roughPercent)%")
        }
        parts.append(day(of: createdAt, now: now, calendar: calendar, locale: locale))
        return parts.joined(separator: " · ")
    }

    /// "Tue" within the last week, "Tue 30 Sep" before that.
    public static func day(of date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let age = now.timeIntervalSince(date)
        formatter.dateFormat = age < Double(recentDays) * 86_400 ? "EEE" : "EEE d MMM"
        return formatter.string(from: date)
    }
}

/// An item's Margins in the order they were heard: by position in the source across all of its sessions, earliest
/// first (#777). Media Margins sort by their clock time and everything else by character offset, so mixing the two
/// never breaks the ordering.
public enum MarginSourceOrder {
    public static func isOrderedBefore(_ lhs: Interjection, _ rhs: Interjection) -> Bool {
        let left = key(lhs), right = key(rhs)
        if left.rank != right.rank { return left.rank < right.rank }
        if left.position != right.position { return left.position < right.position }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id < right.id
    }

    private static func key(_ margin: Interjection) -> (rank: Int, position: Int, createdAt: Date, id: String) {
        // Responses and summaries aren't positions in the source, so they follow the Margins that are.
        guard margin.targetType == .item else { return (2, 0, margin.createdAt, margin.id) }
        if let ms = margin.anchor.mediaTimeMs { return (0, ms, margin.createdAt, margin.id) }
        return (1, margin.anchor.startChar, margin.createdAt, margin.id)
    }
}

/// One short line saying what a Margin is about (#777): the Margin's own words when they are short, else its first
/// meaningful sentence once spoken warm-up ("So I think what's interesting here is") is taken off the front.
public enum MarginGist {
    public static let maximumWords = 12
    private static let minimumSentenceWords = 3

    /// Leading phrases that carry no meaning, longest first. Matched whole-word and case-insensitively.
    private static let fillerPhrases: [[String]] = [
        ["i", "think", "what's", "interesting", "here", "is", "that"],
        ["i", "think", "what's", "interesting", "here", "is"],
        ["i", "think", "what's", "interesting", "is", "that"],
        ["i", "think", "what's", "interesting", "is"],
        ["what's", "interesting", "here", "is", "that"],
        ["what's", "interesting", "here", "is"],
        ["what's", "interesting", "is", "that"],
        ["what's", "interesting", "is"],
        ["i", "think", "that"],
        ["the", "thing", "is"],
        ["i", "think"], ["i", "guess"], ["i", "mean"], ["i", "feel", "like"], ["you", "know"],
        ["so", "yeah"], ["okay", "so"], ["ok", "so"],
        ["so"], ["um"], ["uh"], ["well"], ["okay"], ["ok"], ["like"], ["basically"], ["actually"],
        ["and"], ["but"],
    ]

    /// nil when there are no words to show.
    public static func gist(from text: String) -> String? {
        let words = tokens(text)
        guard !words.isEmpty else { return nil }
        if words.count <= maximumWords { return words.joined(separator: " ") }

        var firstNonEmpty: [String]?
        for sentence in sentences(text) {
            let stripped = stripLeadingFiller(sentence)
            guard !stripped.isEmpty else { continue }
            if firstNonEmpty == nil { firstNonEmpty = stripped }
            if stripped.count >= minimumSentenceWords { return present(stripped) }
        }
        return present(firstNonEmpty ?? words)
    }

    private static func tokens(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    /// Sentences end at . ! or ? followed by whitespace or the end of the text.
    private static func sentences(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for word in tokens(text) {
            current.append(word)
            if let last = word.last, ".!?".contains(last) {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func stripLeadingFiller(_ sentence: [String]) -> [String] {
        var words = sentence
        var removed = true
        while removed {
            removed = false
            for phrase in fillerPhrases where words.count > phrase.count {
                let head = words.prefix(phrase.count).map(normalized)
                if head == phrase {
                    words.removeFirst(phrase.count)
                    removed = true
                    break
                }
            }
        }
        return words
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"…-"))
    }

    private static func present(_ words: [String]) -> String {
        var shown = Array(words.prefix(maximumWords))
        let wasCut = words.count > maximumWords
        if let first = shown.first, let initial = first.first {
            shown[0] = initial.uppercased() + String(first.dropFirst())
        }
        var line = shown.joined(separator: " ")
        if wasCut {
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-.")) + "…"
        }
        return line
    }
}
