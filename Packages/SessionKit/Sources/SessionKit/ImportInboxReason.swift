import Foundation

/// The reason line under a failed share in Import Inbox (#1972). The store keeps the error's own description so
/// the raw text can still go in diagnostics; the listener reads it only when it reads as a sentence.
public enum ImportInboxReason {
    public static let fallback = "It couldn't be read."

    /// `raw` when it is a plain sentence, else the fallback. A code name, a domain dump or a single token is not one.
    public static func plain(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.contains(where: \.isWhitespace) else { return fallback }
        if text.hasPrefix("Error Domain=") || text.contains("UserInfo=") { return fallback }
        if text.range(of: #"^[a-z][a-z0-9_]*:"#, options: .regularExpression) != nil { return fallback }
        if text.range(of: #"^\w+\(.*\)$"#, options: .regularExpression) != nil { return fallback }
        if text.range(of: #" error -?\d+\.?\)$"#, options: .regularExpression) != nil { return fallback }
        return text
    }
}
