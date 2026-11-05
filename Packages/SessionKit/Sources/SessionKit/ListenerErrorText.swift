import Foundation

/// #1965: the one line a listener reads when something fails. An error that already carries a plain
/// sentence keeps it. A code ("persistence_failed:…"), a Swift case name or an `NSError` dump is for
/// diagnostics, so it becomes a generic line with a next step instead.
/// #3362: a chapter tap the engine could not place (a chapter it has no position for, or a Margin being recorded).
/// Its own sentence, so the banner says what happened instead of the generic line.
public struct ChapterJumpUnavailable: Error, LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "Couldn't jump to that chapter. Try another one." }
}

public enum ListenerErrorText {
    public static let fallback = "Something went wrong. Try again."

    public static func message(for error: Error) -> String {
        let description = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return looksLikeCodeOrDump(description) ? fallback : description
    }

    /// A failure line that opens with what failed, then the plain reason (or the generic next step): "Couldn't use that
    /// folder: Something went wrong. Try again." Every place that builds a line from a prefix and an error uses this
    /// one, so a Foundation message such as "The operation couldn't be completed. (NSCocoaErrorDomain error 513.)" never
    /// reaches the screen behind a friendly prefix (#3317). The raw text belongs in Diagnostics.
    public static func line(prefix: String, error: Error) -> String {
        "\(prefix) \(message(for: error))"
    }

    /// True for text no listener would write: empty, one unbroken token ("pdfHasNoExtractableText",
    /// "rss_episode_ambiguous"), a lowercase code prefix ("persistence_failed:…"), a case with its
    /// payload ("tooDeep(depth: 4)") or Foundation's "Error Domain=…" and "(Domain error 5.)" dumps.
    public static func looksLikeCodeOrDump(_ rawText: String) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        if !text.contains(where: \.isWhitespace) { return true }
        if text.range(of: #"^[a-z][a-z0-9_]*:"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"^[A-Za-z_][A-Za-z0-9_.]*\(.*\)$"#, options: .regularExpression) != nil { return true }
        if text.contains("Error Domain=") || text.contains("UserInfo=") { return true }
        if text.range(of: #" error -?\d+\.?\)$"#, options: .regularExpression) != nil { return true }
        return false
    }
}
