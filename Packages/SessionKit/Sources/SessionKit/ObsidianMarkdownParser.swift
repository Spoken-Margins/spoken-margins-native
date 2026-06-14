import Foundation

public struct ParsedObsidianMarkdown: Equatable, Sendable {
    public let title: String
    public let text: String
    public let source: String?
    public let metadata: [String: String]
}

public enum ObsidianMarkdownParser {
    public static func parse(fileName: String, contents: String) throws -> ParsedObsidianMarkdown {
        let parsed = splitFrontmatter(contents)
        let title = firstNonEmpty([
            parsed.metadata["title"],
            firstMarkdownHeading(in: parsed.body),
            (fileName as NSString).deletingPathExtension
        ]) ?? "Imported Markdown"
        let cleaned = cleanBody(parsed.body)
        guard !cleaned.isEmpty else {
            throw SessionKitError.persistenceFailed("obsidian_import_empty_text")
        }
        return ParsedObsidianMarkdown(
            title: unquote(title),
            text: cleaned,
            source: parsed.metadata["source"].map(unquote),
            metadata: parsed.metadata
        )
    }

    private static func splitFrontmatter(_ contents: String) -> (metadata: [String: String], body: String) {
        guard contents.hasPrefix("---") else {
            return ([:], contents)
        }
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else {
            return ([:], contents)
        }
        var metadata: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let line = lines[index]
            if line == "---" {
                let body = lines.dropFirst(index + 1).joined(separator: "\n")
                return (metadata, body)
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !value.isEmpty {
                    metadata[key] = unquote(value)
                }
            }
            index += 1
        }
        return (metadata, contents)
    }

    private static func cleanBody(_ body: String) -> String {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var output: [String] = []
        var skippingTimestampBlock = false

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if output.last?.isEmpty == false {
                    output.append("")
                }
                skippingTimestampBlock = false
                continue
            }
            if line.localizedCaseInsensitiveContains("timestamps"),
               line.replacingOccurrences(of: #"[^\p{L}]"#, with: "", options: .regularExpression).localizedCaseInsensitiveContains("timestamps") {
                skippingTimestampBlock = true
                continue
            }
            if skippingTimestampBlock, isTimestampIndexLine(line) {
                continue
            }
            if line.range(of: #"^!\[[^\]]*\]\([^)]+\)$"#, options: .regularExpression) != nil {
                continue
            }

            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*[-*+]\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^\s*>\s?"#, with: "", options: .regularExpression)
            line = stripTranscriptTimestampPrefix(line)
            line = line.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"(?<!\*)\*([^*]+)\*(?!\*)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            line = SpeechTextNormalizer.normalize(line)
            if !line.isEmpty {
                output.append(line)
            }
        }

        return output
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTimestampIndexLine(_ line: String) -> Bool {
        line.range(of: #"^\d{1,2}:\d{2}(?::\d{2})?\s+[-–—]\s+.+"#, options: .regularExpression) != nil
    }

    private static func stripTranscriptTimestampPrefix(_ line: String) -> String {
        let patterns = [
            #"^\*\*\d{1,2}:\d{2}(?::\d{2})?\*\*\s*[·\-–—]\s*"#,
            #"^\d{1,2}:\d{2}(?::\d{2})?\s*[·\-–—]\s*"#
        ]
        return patterns.reduce(line) { current, pattern in
            current.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private static func firstMarkdownHeading(in body: String) -> String? {
        body.components(separatedBy: .newlines).first { line in
            line.range(of: #"^#\s+\S"#, options: .regularExpression) != nil
        }?.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
