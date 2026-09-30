import Foundation
import SessionKit

enum PodcastChapterTimeParser {
    static func milliseconds(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              let seconds = Double(parts.last ?? ""),
              seconds.isFinite,
              seconds >= 0 else { return nil }
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) : 0
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let minutes, let hours, minutes >= 0, hours >= 0,
              (parts.count == 1 || seconds < 60),
              (parts.count < 3 || minutes < 60) else { return nil }
        let total = (hours * 3_600) + (minutes * 60) + seconds
        guard total <= Double(Int.max) / 1_000 else { return nil }
        return Int((total * 1_000).rounded())
    }
}

enum Podcasting2ChapterJSONParser {
    static let maximumDocumentBytes = 1_000_000
    static let maximumChapterCount = 500

    static func parse(_ data: Data) -> PublisherChapterCollection? {
        guard !data.isEmpty, data.count <= maximumDocumentBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] is String,
              let rawChapters = object["chapters"] as? [[String: Any]],
              !rawChapters.isEmpty,
              rawChapters.count <= maximumChapterCount else { return nil }

        let chapters = rawChapters.enumerated().compactMap { index, raw -> PublisherChapter? in
            if let visible = raw["toc"] as? Bool, !visible { return nil }
            guard let start = (raw["startTime"] as? NSNumber)?.doubleValue,
                  start.isFinite,
                  start >= 0,
                  start <= Double(Int.max) / 1_000 else { return nil }
            let endValue = (raw["endTime"] as? NSNumber)?.doubleValue
            let end = endValue.flatMap { value -> Int? in
                guard value.isFinite, value >= start, value <= Double(Int.max) / 1_000 else { return nil }
                return Int((value * 1_000).rounded())
            }
            let suppliedTitle = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = suppliedTitle?.isEmpty == false ? suppliedTitle! : "Chapter \(index + 1)"
            return PublisherChapter(
                title: String(title.prefix(240)),
                startMs: Int((start * 1_000).rounded()),
                endMs: end
            )
        }
        guard !chapters.isEmpty else { return nil }
        return PublisherChapterCollection(source: .podcasting20JSON, chapters: chapters)
    }
}

public enum TimestampedDescriptionChapterParser {
    // Recognize a timestamp token at a line boundary, then validate its numeric
    // components separately. Links contribute their visible text, not arbitrary
    // numbers in their destination URLs.
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s*)?(?:\(((?:\d{1,3}:)?\d{1,3}:\d{2}(?:\.\d{1,3})?)\)|\[((?:\d{1,3}:)?\d{1,3}:\d{2}(?:\.\d{1,3})?)\]|((?:\d{1,3}:)?\d{1,3}:\d{2}(?:\.\d{1,3})?))(?=\s|[-–—:|])\s*(?:[-–—:|]\s*)?(.+?)\s*$"#
    )

    public static func parse(_ description: String) -> PublisherChapterCollection? {
        guard description.utf8.count <= Podcasting2ChapterJSONParser.maximumDocumentBytes else { return nil }
        let lines = plainTextLines(from: description)
        var chapters: [PublisherChapter] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = timestampRegex.firstMatch(in: line, range: range),
                  let timeRange = (1...3).compactMap({ Range(match.range(at: $0), in: line) }).first,
                  let titleRange = Range(match.range(at: 4), in: line),
                  let startMs = PodcastChapterTimeParser.milliseconds(String(line[timeRange])) else { continue }
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.contains(where: { $0.isLetter }),
                  !title.lowercased().hasPrefix("https://"),
                  !title.lowercased().hasPrefix("http://") else { continue }
            chapters.append(PublisherChapter(title: String(title.prefix(240)), startMs: startMs))
            guard chapters.count <= Podcasting2ChapterJSONParser.maximumChapterCount else { return nil }
        }
        let normalized = deduplicatedAndSorted(chapters)
        guard normalized.count >= 2 else { return nil }
        return PublisherChapterCollection(source: .timestampedDescription, chapters: normalized)
    }

    private static func plainTextLines(from html: String) -> [String] {
        var text = html
        text = text.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
        for pattern in [#"(?i)<br\b[^>]*>"#, #"(?i)</?(?:p|li|div|h[1-6])\b[^>]*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Markdown descriptions also commonly link the timestamp itself.
        text = text.replacingOccurrences(of: #"\[([^\]\n]+)\]\(https?://[^\s)]+\)"#, with: "$1", options: .regularExpression)
        if let numeric = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#, options: .caseInsensitive) {
            for match in numeric.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: text),
                      let entityRange = Range(match.range, in: text) else { continue }
                let digits = String(text[digitsRange])
                let value = digits.lowercased().hasPrefix("x")
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, let scalar = UnicodeScalar(value) {
                    text.replaceSubrange(entityRange, with: String(scalar))
                }
            }
        }
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—", "&colon;": ":"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        return text.components(separatedBy: .newlines)
    }

    private static func deduplicatedAndSorted(_ chapters: [PublisherChapter]) -> [PublisherChapter] {
        let sorted = chapters.sorted { lhs, rhs in
            lhs.startMs == rhs.startMs ? lhs.title < rhs.title : lhs.startMs < rhs.startMs
        }
        var seen: Set<Int> = []
        return sorted.filter { seen.insert($0.startMs).inserted }
    }
}
