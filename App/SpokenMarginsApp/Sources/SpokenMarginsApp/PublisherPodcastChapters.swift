import Foundation
import SessionKit

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

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

enum TimestampedDescriptionChapterParser {
    private static let timestampPattern = #"^\s*(?:[-*•]\s*)?\[?((?:\d{1,2}:)?\d{1,2}:\d{2}(?:\.\d{1,3})?)\]?\s*(?:[-–—:|]\s*)?(.+?)\s*$"#

    static func parse(_ description: String) -> PublisherChapterCollection? {
        let lines = plainTextLines(from: description)
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else { return nil }
        var chapters: [PublisherChapter] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let timeRange = Range(match.range(at: 1), in: line),
                  let titleRange = Range(match.range(at: 2), in: line),
                  let startMs = PodcastChapterTimeParser.milliseconds(String(line[timeRange])) else { continue }
            let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, URL(string: title)?.scheme == nil else { continue }
            chapters.append(PublisherChapter(title: String(title.prefix(240)), startMs: startMs))
        }
        let normalized = deduplicatedAndSorted(chapters)
        guard normalized.count >= 2 else { return nil }
        return PublisherChapterCollection(source: .timestampedDescription, chapters: normalized)
    }

    private static func plainTextLines(from html: String) -> [String] {
        var text = html
        for pattern in [#"(?i)<br\s*/?>"#, #"(?i)</p\s*>"#, #"(?i)</li\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
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

enum EmbeddedPublisherChapterLoader {
    static func load(from url: URL) async -> PublisherChapterCollection? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let groups = try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages
        ), !groups.isEmpty else { return nil }
        var chapters: [PublisherChapter] = []
        for (index, group) in groups.enumerated() {
            let seconds = CMTimeGetSeconds(group.timeRange.start)
            guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max) / 1_000 else { continue }
            let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle })
            let descriptionItem = group.items.first(where: { $0.commonKey == .commonKeyDescription })
            let title = try? await titleItem?.load(.stringValue)
            let description = try? await descriptionItem?.load(.stringValue)
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(PublisherChapter(
                title: trimmedTitle?.isEmpty == false ? String(trimmedTitle!.prefix(240)) : "Chapter \(index + 1)",
                description: trimmedDescription?.isEmpty == false ? String(trimmedDescription!.prefix(500)) : nil,
                startMs: Int((seconds * 1_000).rounded())
            ))
        }
        guard !chapters.isEmpty else { return nil }
        return PublisherChapterCollection(source: .embeddedMedia, chapters: chapters)
        #else
        return nil
        #endif
    }
}
