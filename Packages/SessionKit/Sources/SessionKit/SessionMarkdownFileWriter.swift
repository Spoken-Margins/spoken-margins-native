import Foundation

/// Writes one session export as a named `.md` file. Moved to SessionKit so the batch share files are
/// built and tested on the host (#1528).
public struct SessionMarkdownFileWriter {
    private let fileManager: FileManager
    private let calendar: Calendar
    private let locale: Locale

    public init(
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) {
        self.fileManager = fileManager
        self.calendar = calendar
        self.locale = locale
    }

    public func write(
        markdown: String,
        itemTitle: String,
        sessionDate: Date?,
        sessionId: String,
        to directory: URL
    ) throws -> URL {
        let destination = availableDestinationURL(
            itemTitle: itemTitle,
            sessionDate: sessionDate,
            sessionId: sessionId,
            directory: directory
        )
        try Data(markdown.utf8).write(to: destination, options: [.atomic])
        return destination
    }

    public func availableDestinationURL(
        itemTitle: String,
        sessionDate: Date?,
        sessionId: String,
        directory: URL
    ) -> URL {
        let baseName = fileBaseName(itemTitle: itemTitle, sessionDate: sessionDate, sessionId: sessionId)
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("md")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName) (\(suffix))")
                .appendingPathExtension("md")
            suffix += 1
        }
        return candidate
    }

    public func fileBaseName(itemTitle: String, sessionDate: Date?, sessionId: String) -> String {
        let cleanTitle = Self.sanitizedFileNameComponent(itemTitle)
        let sessionLabel: String
        if let sessionDate {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd HHmm"
            sessionLabel = formatter.string(from: sessionDate)
        } else {
            let fallback = Self.sanitizedFileNameComponent(String(sessionId.prefix(8)))
            sessionLabel = fallback.isEmpty ? "Undated Session" : "Session \(fallback)"
        }
        return "\(cleanTitle.isEmpty ? "Untitled" : cleanTitle) — \(sessionLabel)"
    }

    public static func sanitizedFileNameComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:")
            .union(.controlCharacters)
            .union(.newlines)
        let pieces = value.components(separatedBy: invalid)
        let collapsed = pieces
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(collapsed.prefix(120))
    }
}
