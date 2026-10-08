import Foundation

/// I13 rule 1d: an item moves to a new extraction only if every text-anchored
/// Margin lands on exactly the same words in the new text. Pure, so it can be
/// checked on any pair of texts.
public enum StructuredDocumentMigration {
    /// A range of the old text to place in the new one, with the context stored
    /// when it was made (a Margin's anchorBefore/anchorAfter).
    public struct TextAnchor: Equatable, Sendable {
        public var id: String
        public var start: Int
        public var end: Int
        public var before: String
        public var after: String

        public init(id: String, start: Int, end: Int, before: String = "", after: String = "") {
            self.id = id
            self.start = start
            self.end = end
            self.before = before
            self.after = after
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// Every anchor found: its new range, by id.
        case moved([String: Range<Int>])
        /// At least one anchor's words aren't in the new text exactly once.
        case stays(unplaced: [String])
    }

    public static func place(_ anchors: [TextAnchor], from oldText: String, into newText: String) -> Outcome {
        let old = Array(oldText)
        let new = Array(newText)
        var placed: [String: Range<Int>] = [:]
        var unplaced: [String] = []
        for anchor in anchors {
            if let range = place(anchor, old: old, new: new) {
                placed[anchor.id] = range
            } else {
                unplaced.append(anchor.id)
            }
        }
        return unplaced.isEmpty ? .moved(placed) : .stays(unplaced: unplaced)
    }

    /// Where a listening position (a single offset) lands: the text that followed
    /// it, found once in the new text. The start and the end map to themselves.
    public static func placePosition(_ offset: Int, from oldText: String, into newText: String) -> Int? {
        let old = Array(oldText)
        if offset <= 0 { return 0 }
        if offset >= old.count { return newText.count }
        let anchor = TextAnchor(id: "position", start: offset, end: min(old.count, offset + 60))
        return place(anchor, old: old, new: Array(newText))?.lowerBound
    }

    static func place(_ anchor: TextAnchor, old: [Character], new: [Character]) -> Range<Int>? {
        guard anchor.start >= 0, anchor.start < anchor.end, anchor.end <= old.count else { return nil }
        let words = Array(old[anchor.start..<anchor.end])
        guard words.contains(where: { !$0.isWhitespace }) else { return nil }
        let candidates = occurrences(of: words, in: new)
        guard !candidates.isEmpty else { return nil }
        // The stored context decides, else the old text's own surroundings.
        let before = anchor.before.isEmpty ? Array(old[max(0, anchor.start - 40)..<anchor.start]) : Array(anchor.before)
        let after = anchor.after.isEmpty ? Array(old[anchor.end..<min(old.count, anchor.end + 40)]) : Array(anchor.after)
        func score(_ start: Int) -> Int {
            commonSuffixLength(before, new[..<start]) + commonPrefixLength(after, new[(start + words.count)...])
        }
        let chosen: Int
        if candidates.count == 1 {
            chosen = candidates[0]
        } else {
            // The same words more than once: a tie leaves the item where it is.
            let scored = candidates.map { ($0, score($0)) }
            guard let best = scored.map(\.1).max(), best > 0 else { return nil }
            let winners = scored.filter { $0.1 == best }
            guard winners.count == 1 else { return nil }
            chosen = winners[0].0
        }
        // The words were also somewhere else in the old text (a running head, a repeated line), so
        // the copy found may be another copy than the Margin's own. It counts only if it looks more
        // like the Margin's own copy than like any other old copy; otherwise the item stays (#1054).
        // Every old copy is read the same way, from the old text around it: the context a Margin
        // stores is cut at the Margin's start and runs through its own words, so it can't be lined
        // up against the words after another copy.
        func oldContextScore(at start: Int) -> Int {
            let end = start + words.count
            return commonSuffixLength(Array(old[max(0, start - 40)..<start]), new[..<chosen])
                + commonPrefixLength(Array(old[end..<min(old.count, end + 40)]), new[(chosen + words.count)...])
        }
        let ownScore = oldContextScore(at: anchor.start)
        for other in occurrences(of: words, in: old) where other != anchor.start && oldContextScore(at: other) >= ownScore {
            return nil
        }
        return chosen..<(chosen + words.count)
    }

    static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [Int] = []
        let first = needle[0]
        for start in 0...(haystack.count - needle.count) where haystack[start] == first {
            var matches = true
            for offset in 1..<needle.count where haystack[start + offset] != needle[offset] {
                matches = false
                break
            }
            if matches { result.append(start) }
        }
        return result
    }

    private static func commonSuffixLength(_ a: [Character], _ b: ArraySlice<Character>) -> Int {
        var count = 0
        var i = a.count - 1
        var j = b.endIndex - 1
        while i >= 0, j >= b.startIndex, a[i] == b[j] {
            count += 1
            i -= 1
            j -= 1
        }
        return count
    }

    private static func commonPrefixLength(_ a: [Character], _ b: ArraySlice<Character>) -> Int {
        var count = 0
        var j = b.startIndex
        while count < a.count, j < b.endIndex, a[count] == b[j] {
            count += 1
            j += 1
        }
        return count
    }
}
