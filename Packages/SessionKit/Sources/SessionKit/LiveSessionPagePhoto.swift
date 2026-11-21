import Foundation

/// Finds a page number in the lines of text that were recognised in a photo of a page (#2708, item 4 of the issue).
///
/// The recogniser is Vision, in the app; this type is only the rule for what counts as a page number, so each case is
/// tested on the host with lines written by hand. What it returns is a number and nothing else: the recognised words
/// are a page of someone's book, and the caller throws them away.
///
/// The rule is cautious on purpose, because the result is only an offer ("Read 118 on the page. Keep it as a
/// checkpoint?") and a wrong offer costs the listener a tap and some trust:
/// - A page number is a line of its own near the top or bottom edge: "118", "- 118 -", "[118]", "p. 118", "Page 118",
///   "Page 118 of 320". A number at the start of a line of words is a footnote or a heading, not a page.
/// - Only ASCII digits count. A page numbered in Arabic-Indic, Devanagari or full-width digits is left alone, not
///   converted: nothing is offered.
/// - A bare number is at most 999, and never a year-like four digits; "page 1999" with its word is allowed.
/// - A line with text right beside it on the same row is a footnote marker ("1  See Smith, 2019"), not a page.
/// - Two different numbers (a spread, a footer and a footnote) give nothing: the photo does not say which is the page.
public enum LiveSessionPagePhoto {
    /// One line of recognised text. The box is Vision's: `minX` and `minY` from the bottom-left corner, all four in
    /// 0...1 of the picture's size.
    public struct TextLine: Equatable, Sendable {
        public var text: String
        public var minX: Double
        public var minY: Double
        public var width: Double
        public var height: Double
        public var confidence: Double

        public init(text: String, minX: Double, minY: Double, width: Double, height: Double, confidence: Double = 1) {
            self.text = text
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
            self.confidence = confidence
        }

        var maxX: Double { minX + width }
        var midY: Double { minY + height / 2 }
    }

    /// The share of the picture's height, from each edge, in which a page number is looked for.
    static let edgeBand = 0.12
    /// A page number's box is narrow; a line of words that happens to be only digits-and-spaces is not.
    static let maxWidth = 0.35
    /// A line the recogniser is less sure of than this is ignored.
    static let minConfidence = 0.5
    /// Text starting this close to the right of a number (a share of the width) belongs to it.
    static let adjacentGap = 0.06
    static let maxBareNumber = 999
    static let maxNumberedPage = 9_999

    /// The page number in these lines, or nil when there is none or the photo is ambiguous.
    public static func pageNumber(in lines: [TextLine]) -> Int? {
        var explicit = Set<Int>()
        var bare = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard line.confidence >= minConfidence, line.width <= maxWidth, isInEdgeBand(line),
                  let found = read(line.text), !hasTextBeside(line, among: lines, excluding: index)
            else { continue }
            if found.hasWord { explicit.insert(found.value) } else { bare.insert(found.value) }
        }
        // A number with its word ("p. 118") outranks a bare one: the bare ones may be footnotes.
        let winners = explicit.isEmpty ? bare : explicit
        return winners.count == 1 ? winners.first : nil
    }

    /// The same, as a place in a book, for the Margin's checkpoint.
    public static func place(in lines: [TextLine]) -> LiveSessionPlace? {
        pageNumber(in: lines).flatMap { LiveSessionPlace(unit: .page, value: Double($0)) }
    }

    // MARK: Where

    private static func isInEdgeBand(_ line: TextLine) -> Bool {
        line.midY >= 1 - edgeBand || line.midY <= edgeBand
    }

    /// True when another line sits on the same row and starts just to the right of this one.
    private static func hasTextBeside(_ line: TextLine, among lines: [TextLine], excluding index: Int) -> Bool {
        for (other, candidate) in lines.enumerated() where other != index && !candidate.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let overlap = min(line.minY + line.height, candidate.minY + candidate.height) - max(line.minY, candidate.minY)
            guard overlap >= 0.5 * min(line.height, candidate.height) else { continue }
            let gap = candidate.minX - line.maxX
            if gap > -0.01, gap < adjacentGap { return true }
        }
        return false
    }

    // MARK: What

    /// Characters that may frame a page number: "- 118 -", "[118]", "· 118 ·", "118.".
    private static let framing = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}\u{00B7}\u{2022}.,:;|/\\*[](){}<>~_"))

    /// A page number in the text of one line, and whether it came with the word for it. Nil for anything else.
    static func read(_ text: String) -> (value: Int, hasWord: Bool)? {
        // Digits of any other script are left alone: a page in those digits gets no offer, never a converted one.
        guard !text.contains(where: { $0.isNumber && !($0.isASCII) }), text.count <= 40 else { return nil }
        let core = text.trimmingCharacters(in: framing)
        guard !core.isEmpty else { return nil }
        let lowered = core.lowercased()
        if let value = wholeNumber(lowered) {
            guard value >= 1, value <= maxBareNumber else { return nil }
            return (value, false)
        }
        for word in ["page", "pagina", "seite", "pgs", "pg", "pp", "p"] where lowered.hasPrefix(word) {
            var rest = lowered.dropFirst(word.count)
            if rest.hasPrefix(".") { rest = rest.dropFirst() }
            rest = Substring(rest.trimmingCharacters(in: .whitespacesAndNewlines))
            if rest.hasPrefix("#") { rest = Substring(rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)) }
            // "Page 118 of 320": the total must be a real one for this page.
            let parts = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count == 3, parts[1] == "of", let value = wholeNumber(parts[0]), let total = wholeNumber(parts[2]) {
                return value >= 1 && value <= total && total <= maxNumberedPage ? (value, true) : nil
            }
            guard parts.count == 1, let value = wholeNumber(parts[0]), value >= 1, value <= maxNumberedPage else { return nil }
            return (value, true)
        }
        return nil
    }

    /// A whole number written with ASCII digits and no leading zero ("118", not "0118" or "1,180" or "11.8").
    private static func wholeNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard text == "0" || !text.hasPrefix("0") else { return nil }
        return Int(text)
    }
}
