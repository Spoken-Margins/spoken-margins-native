import Foundation

/// What the Item screen shows from the feed about an episode or post: its publication date and the opening
/// of its description (#1322). Both come from the feed entry the item was added from, and both are nil when
/// the feed gave nothing usable. Nothing is invented.
public enum ItemMetadata {
    /// The longest description kept on an item, in characters.
    public static let descriptionLimit = 2_000

    // MARK: Date

    /// A readable date for `Item.publishedAt`, or nil for empty, unparseable or implausible text.
    /// Reads ISO 8601 (with and without fractional seconds), RFC 822 and a bare `yyyy-MM-dd`. A date more
    /// than two days after `now`, or before 1970, is treated as garbage rather than shown.
    public static func publishedDateText(_ raw: String?, now: Date = Date(),
                                         locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let parsed = plausiblePublished(raw, now: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        // A date with no time of day names a calendar day: show that day, not the one a time zone shifts it to.
        formatter.timeZone = parsed.hasTime ? timeZone : TimeZone(secondsFromGMT: 0)
        return formatter.string(from: parsed.date)
    }

    /// The moment `Item.publishedAt` names, for ordering the Library by it. Nil for the same text
    /// `publishedDateText` refuses, so an item with no usable date sorts as undated (#1867).
    public static func publishedDate(_ raw: String?, now: Date = Date()) -> Date? {
        plausiblePublished(raw, now: now)?.date
    }

    private static func plausiblePublished(_ raw: String?, now: Date) -> (date: Date, hasTime: Bool)? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let parsed = parse(trimmed) else { return nil }
        guard parsed.date.timeIntervalSince1970 >= 0, parsed.date <= now.addingTimeInterval(2 * 86_400) else { return nil }
        return parsed
    }

    private static func parse(_ text: String) -> (date: Date, hasTime: Bool)? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return (date, true) }
        }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: text) { return (date, false) }
        let posix = DateFormatter()
        posix.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z",
                       "EEE, d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
                       "EEE, dd MMM yyyy HH:mm zzz", "EEE, d MMM yyyy HH:mm zzz", "EEE, dd MMM yyyy HH:mm Z"] {
            posix.dateFormat = format
            if let date = posix.date(from: text) { return (date, true) }
        }
        return nil
    }

    // MARK: Description

    /// A feed summary as plain text for the Item screen: HTML reduced to text, entities decoded, blank runs
    /// collapsed and the result cut at `descriptionLimit` on a word boundary. Nil when nothing readable is left.
    public static func plainDescription(from summary: String?) -> String? {
        guard let summary, !summary.isEmpty else { return nil }
        // Inline tags vanish without a space, so "<em>S</em>tart" stays "Start"; block tags still break lines.
        let inline = summary.replacingOccurrences(
            of: #"</?(a|b|i|u|em|strong|span|code|small|sup|sub|font|mark)(\s[^>]*)?>"#, with: "",
            options: [.regularExpression, .caseInsensitive])
        let stripped = HTMLTextStripping.stripHTML(inline)
        let decoded = decodeEntities(stripped)
        var lines: [String] = []
        for rawLine in decoded.components(separatedBy: .newlines) {
            let line = rawLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
            } else {
                lines.append(line)
            }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        guard text.count > descriptionLimit else { return text }
        let head = String(text.prefix(descriptionLimit))
        let cut = head.lastIndex(where: { $0.isWhitespace }).map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Whether the three-line preview might hide anything, so the screen knows to offer More. It assumes the
    /// narrowest line (about 15 characters, the largest accessibility text size on a small phone), so it errs
    /// toward offering More and never toward hiding text with no way to read it.
    public static func needsExpansion(_ description: String, previewLines: Int = 3, charactersPerLine: Int = 15) -> Bool {
        let lines = description.components(separatedBy: "\n")
        if lines.count > previewLines { return true }
        return lines.reduce(0) { $0 + max(1, ($1.count + charactersPerLine - 1) / charactersPerLine) } > previewLines
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©",
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let body = String(text[text.index(after: index)..<semicolon])
                if let replacement = entity(body) {
                    result += replacement
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func entity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            // A NUL or other control character is not text; leave the entity as written.
            return value.flatMap(Unicode.Scalar.init).flatMap { $0.properties.generalCategory == .control && $0.value != 9 && $0.value != 10 ? nil : String(Character($0)) }
        }
        return named[body.lowercased()]
    }
}
