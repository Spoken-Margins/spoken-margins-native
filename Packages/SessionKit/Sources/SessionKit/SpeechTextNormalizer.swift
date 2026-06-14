import Foundation

public enum SpeechTextNormalizer {
    public static func normalize(_ source: String) -> String {
        var rendered = source

        let markdownPattern = #"\[([^\]]+)\]\((https?://[^)\s]+|www\.[^)\s]+|[^)\s]+\.[^)\s]+)\)"#
        rendered = replace(pattern: markdownPattern, in: rendered) { match, text in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return "" }
            return String(text[range])
        }

        let rawURLPattern = #"(?i)\b(?:https?://|www\.)[^\s<>()]+"#
        rendered = replace(pattern: rawURLPattern, in: rendered) { _, _ in "" }

        let bareDomainPattern = #"(?i)(?<!@)\b[a-z0-9][a-z0-9-]*(?:\.[a-z0-9][a-z0-9-]*)+(?:/[^\s<>()]*)?\b"#
        rendered = replace(pattern: bareDomainPattern, in: rendered) { _, _ in "" }

        return rendered
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" \."#, with: ".", options: .regularExpression)
            .replacingOccurrences(of: #" ,"#, with: ",", options: .regularExpression)
            .replacingOccurrences(of: #" \?"#, with: "?", options: .regularExpression)
            .replacingOccurrences(of: #" !"#, with: "!", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(
        pattern: String,
        in text: String,
        replacement: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range).reversed()
        var result = text
        for match in matches {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(swiftRange, with: replacement(match, result))
        }
        return result
    }
}
