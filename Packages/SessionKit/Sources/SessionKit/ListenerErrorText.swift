import Foundation

/// #1965: the one line a listener reads when something fails. An error that already carries a plain
/// sentence keeps it. A code ("persistence_failed:…"), a Swift case name or an `NSError` dump is for
/// diagnostics, so it becomes a generic line with a next step instead.
public enum ListenerErrorText {
    public static let fallback = "Something went wrong. Try again."

    public static func message(for error: Error) -> String {
        let description = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return looksLikeCodeOrDump(description) ? fallback : description
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
