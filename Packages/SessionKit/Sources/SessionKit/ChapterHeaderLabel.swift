import Foundation

/// The playback header's chapter label. Many sources already number their chapter
/// titles ("7 Conclusion", "Chapter 3"), so always adding "Ch. N:" made the label
/// say its number twice, on screen and in VoiceOver (#309).
public enum ChapterHeaderLabel {
    /// `index` is zero-based.
    public static func title(_ chapterTitle: String, index: Int) -> String {
        let trimmed = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isNumbered(trimmed) else { return trimmed }
        return "Ch. \(index + 1): \(trimmed)"
    }

    /// True when the title carries its own number: it starts with a digit
    /// ("7 Conclusion", "12. Epilogue") or names itself a chapter ("Chapter 3",
    /// "CHAPTER IV", "Chapter One", "Ch. 5").
    public static func isNumbered(_ title: String) -> Bool {
        guard let first = title.first else { return false }
        if first.isNumber { return true }
        let lower = title.lowercased()
        for word in ["chapter", "ch."] where lower.hasPrefix(word) {
            // "Chapters of My Life" is a title, not a chapter number.
            guard let next = lower.dropFirst(word.count).first else { return true }
            if next.isWhitespace || next.isNumber || next == ":" { return true }
        }
        return false
    }
}
