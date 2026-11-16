import Foundation

public enum TimelineTextPresentation {
    public static let marginCharacterLimit = 180
    public static let supportingCharacterLimit = 280

    public static func excerpt(_ text: String, characterLimit: Int) -> String {
        let normalized = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > characterLimit else { return normalized }

        let boundary = normalized.index(normalized.startIndex, offsetBy: characterLimit)
        let prefix = normalized[..<boundary]
        // The limit lands exactly after a word: it fits whole, so keep it.
        if normalized[boundary] == " " { return String(prefix) + "…" }
        if let wordBoundary = prefix.lastIndex(of: " ") {
            return String(prefix[..<wordBoundary]) + "…"
        }
        return String(prefix) + "…"
    }
}
