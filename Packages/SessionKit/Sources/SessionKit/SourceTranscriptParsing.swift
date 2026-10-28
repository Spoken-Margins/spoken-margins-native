import Foundation

public enum SourceTranscriptParsing {
    public static func prioritizedTranscriptLinks(_ links: [SourceTranscriptLink]) -> [SourceTranscriptLink] {
        links.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = transcriptLinkRank(lhs.element)
                let rhsRank = transcriptLinkRank(rhs.element)
                if lhsRank == rhsRank {
                    return lhs.offset < rhs.offset
                }
                return lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func transcriptLinkRank(_ link: SourceTranscriptLink) -> Int {
        let value = "\(link.type) \(link.url) \(link.rel ?? "")".lowercased()
        if value.contains("vtt") || value.contains("webvtt") { return 0 }
        if value.contains("srt") || value.contains("subrip") { return 1 }
        if value.contains("json") { return 2 }
        if value.contains("plain") || value.contains(".txt") { return 3 }
        if value.contains("html") || value.contains(".htm") { return 4 }
        return 5
    }

    public static func transcriptTimeline(from data: Data, link: SourceTranscriptLink, itemId: String, durationMs: Int?) throws -> TranscriptTimeline? {
        let type = "\(link.type) \(link.url)".lowercased()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        if type.contains("vtt") || type.contains("srt") {
            return cueTranscriptTimeline(from: text, itemId: itemId, durationMs: durationMs)
        }
        if type.contains("json") {
            return jsonTranscriptTimeline(from: data, itemId: itemId, durationMs: durationMs)
        }
        let cleaned = type.contains("html") ? HTMLTextStripping.stripHTML(text) : text
        let normalized = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let endMs = max(1, durationMs ?? 1)
        return TranscriptTimeline(
            segments: [
                MediaTimelineSegment(
                    id: "transcript-\(itemId)-plain-0001",
                    startMs: 0,
                    endMs: endMs,
                    text: normalized
                )
            ],
            chapters: [],
            durationMs: durationMs ?? endMs
        )
    }

    private static func cueTranscriptTimeline(from text: String, itemId: String, durationMs: Int?) -> TranscriptTimeline {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var segments: [MediaTimelineSegment] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count >= 2,
                  let startMs = parseCueTime(parts[0]),
                  let endMs = parseCueTime(parts[1]) else {
                continue
            }
            let body = lines[(timingIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-cue-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: body
            ))
        }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func jsonTranscriptTimeline(from data: Data, itemId: String, durationMs: Int?) -> TranscriptTimeline? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            entries = array
        } else if let dictionary = object as? [String: Any],
                  let nested = (dictionary["segments"] ?? dictionary["transcripts"] ?? dictionary["captions"]) as? [[String: Any]] {
            entries = nested
        } else if let dictionary = object as? [String: Any],
                  let text = dictionary["text"] as? String {
            let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let endMs = max(1, durationMs ?? 1)
            return TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "transcript-\(itemId)-json-0001", startMs: 0, endMs: endMs, text: normalized)],
                chapters: [],
                durationMs: durationMs ?? endMs
            )
        } else {
            return nil
        }
        var segments: [MediaTimelineSegment] = []
        for entry in entries {
            let body = (entry["text"] ?? entry["body"] ?? entry["caption"]) as? String ?? ""
            let text = body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startMs = jsonTimeMs(in: entry, keys: [("start", .ambiguous), ("startTime", .seconds), ("start_ms", .milliseconds), ("offset", .ambiguous)]) ?? 0
            let explicitEndMs = jsonTimeMs(in: entry, keys: [("end", .ambiguous), ("endTime", .seconds), ("end_ms", .milliseconds)])
            let duration = jsonTimeMs(in: entry, keys: [("duration", .ambiguous), ("durationMs", .milliseconds), ("duration_ms", .milliseconds)])
            let endMs = explicitEndMs ?? duration.map { startMs + $0 } ?? max(startMs + 1, durationMs ?? startMs + 1)
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-json-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: text
            ))
        }
        guard !segments.isEmpty else { return nil }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func parseCueTime(_ raw: String) -> Int? {
        let value = raw
            .split(separator: " ")
            .first?
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        let secondsPart = parts.last ?? "0"
        let seconds = Double(secondsPart) ?? 0
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return Int(((hours * 3600) + (minutes * 60) + seconds) * 1000)
    }

    /// The unit a JSON key promises. `startTime` and `endTime` are seconds in the Podcasting 2.0
    /// transcript spec and `*_ms`/`*Ms` are milliseconds, whatever the number looks like; only the
    /// bare keys fall back to guessing from the value.
    private enum JSONTimeUnit {
        case seconds, milliseconds, ambiguous
    }

    private static func jsonTimeMs(in entry: [String: Any], keys: [(String, JSONTimeUnit)]) -> Int? {
        for (key, unit) in keys {
            if let value = entry[key] { return jsonTimeMs(value, unit: unit) }
        }
        return nil
    }

    private static func jsonTimeMs(_ value: Any?, unit: JSONTimeUnit) -> Int? {
        func scaled(_ number: Double) -> Int {
            switch unit {
            case .seconds: return Int((number * 1000).rounded())
            case .milliseconds: return Int(number.rounded())
            case .ambiguous: return number < 10_000 ? Int((number * 1000).rounded()) : Int(number.rounded())
            }
        }
        switch value {
        case let int as Int:
            return unit == .seconds ? int.multipliedReportingOverflow(by: 1000).partialValue : int
        case let double as Double:
            return scaled(double)
        case let string as String:
            if string.contains(":") {
                return parseCueTime(string)
            }
            guard let double = Double(string) else { return nil }
            return scaled(double)
        default:
            return nil
        }
    }
}
