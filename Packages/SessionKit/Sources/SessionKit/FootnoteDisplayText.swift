import Foundation

/// The item's text as a reader on screen shows it, with Markdown footnote markers written as a listener reads them
/// (#5109): "The tide turns.[^1]" shows "The tide turns.¹", and the note's "[^1]: Smith, 2020." shows
/// "Footnote 1: Smith, 2020.", as the Timeline's row names it.
///
/// Display only. The stored text, every offset into it (Margins, chapters, the playhead, sentence ranges) and the
/// spoken text are unchanged: a caller renders a slice of the stored text it already cut, at that slice's own offset.
/// The rules for which markers change are `FootnoteAnchors.displayEdits`.
public struct FootnoteDisplayText: Sendable, Equatable {
    /// One marker: the characters of the stored text it covers, and what is shown instead.
    public struct Edit: Sendable, Equatable {
        public let range: Range<Int>
        public let replacement: String

        public init(range: Range<Int>, replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    /// Sorted by offset, never overlapping.
    public let edits: [Edit]

    /// A text with no footnote markers: every slice shows as stored.
    public static let none = FootnoteDisplayText(edits: [])

    /// Scans the item's whole stored text once. A text without `[^` costs one substring search.
    public init(text: String) {
        edits = FootnoteAnchors.displayEdits(in: text)
    }

    init(edits: [Edit]) {
        self.edits = edits
    }

    public var isEmpty: Bool { edits.isEmpty }

    /// `slice` as shown, where `slice` is the stored text from Character offset `start`. A marker cut by either end
    /// of the slice is left as stored: half a marker can't be read as one.
    public func render(_ slice: String, from start: Int) -> String {
        render(slice, from: start, keeping: nil).text
    }

    /// `render`, and `range` (Character offsets into `slice`) moved to the same characters in the shown text. An end
    /// inside a marker moves to that marker's edge, so a range that covers a marker covers its replacement.
    public func render(_ slice: String, from start: Int, keeping range: Range<Int>?) -> (text: String, range: Range<Int>?) {
        guard !edits.isEmpty else { return (slice, range) }
        let characters = Array(slice)
        let end = start + characters.count
        var index = firstEdit(atOrAfter: start)
        var applied: [Edit] = []
        while index < edits.count, edits[index].range.upperBound <= end {
            applied.append(edits[index])
            index += 1
        }
        guard !applied.isEmpty else { return (slice, range) }

        var shown = ""
        shown.reserveCapacity(slice.utf8.count)
        var cursor = start
        for edit in applied {
            shown += String(characters[(cursor - start)..<(edit.range.lowerBound - start)])
            shown += edit.replacement
            cursor = edit.range.upperBound
        }
        shown += String(characters[(cursor - start)...])

        guard let range else { return (shown, nil) }
        // Where a stored offset (relative to the slice) lands in the shown text. Inside a marker, a start goes to the
        // marker's start and an end to its end, so a range that covers part of a marker covers its replacement.
        func shownOffset(_ offset: Int, isEnd: Bool) -> Int {
            let absolute = start + offset
            var shift = 0
            for edit in applied {
                if absolute <= edit.range.lowerBound { break }
                let editStart = edit.range.lowerBound - start + shift
                if absolute < edit.range.upperBound { return isEnd ? editStart + edit.replacement.count : editStart }
                shift += edit.replacement.count - edit.range.count
            }
            return offset + shift
        }
        let lower = shownOffset(range.lowerBound, isEnd: false)
        let upper = shownOffset(range.upperBound, isEnd: true)
        return (shown, lower..<max(lower, upper))
    }

    private func firstEdit(atOrAfter offset: Int) -> Int {
        var lower = 0
        var upper = edits.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if edits[middle].range.lowerBound < offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"
    ]

    /// What a citation shows: its number raised ("¹²"), or a word label in brackets ("[a]", "[note-1]").
    static func citationMark(_ label: String) -> String {
        if !label.isEmpty, label.allSatisfy({ superscripts[$0] != nil }) {
            return String(label.compactMap { superscripts[$0] })
        }
        return "[\(label)]"
    }
}
