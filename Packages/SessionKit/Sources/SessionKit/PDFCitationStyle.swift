import Foundation

/// How a PDF cites, counted over the whole document (#4254). One small run can't say whether "B12" is vitamin
/// B twelve with a citation or the variable B with an index; the document can. A paper that cites with raised
/// numbers sets dozens of them after prose ("aptitude,¹", "effects¹²,¹⁴"). A paper that cites in brackets or
/// by author and year sets a few at most, for footnotes and affiliations, and its other raised numbers are
/// exponents and indices.
///
/// On the C1 corpus the nine papers that cite with raised numbers have 12 to 111 of them after prose in body
/// text and at most 4 numbers in square brackets. The other 55 have 7 at most. When the count is wrong the
/// cost is small either way: a paper wrongly read as raised keeps today's silence, and one wrongly read as
/// not raised speaks a citation only where it follows a lone letter that isn't a byline initial.
public struct PDFCitationStyle: Equatable, Sendable {
    /// Raised numbers the classifier calls markers, set after prose: after a lower-case word, after a full
    /// stop or a comma, or after a closing bracket or quote. Not after a capitalised word: that is where a
    /// byline's affiliation numbers sit ("Jane Doe¹, John Roe²").
    public private(set) var raisedAfterProse = 0
    /// Numbers in square brackets inside a line: "[12]", "[3, 5–7]". Not at a line's start, where a
    /// reference list numbers its entries. Round ones aren't counted: "(1)" is an equation's number or a
    /// list item as often as a citation.
    public private(set) var bracketed = 0

    /// Fewer raised numbers than this are footnotes and affiliations, whatever else the paper does.
    static let minimumRaised = 10

    public init() {}

    public init(raisedAfterProse: Int, bracketed: Int) {
        self.raisedAfterProse = raisedAfterProse
        self.bracketed = bracketed
    }

    /// The document cites with raised numbers, so a number after a lone letter may be a citation.
    public var citesWithRaisedNumbers: Bool {
        raisedAfterProse >= Self.minimumRaised && raisedAfterProse > bracketed
    }

    /// Counts one line of body text: its text, and its small runs as the classifier is given them. The caller
    /// leaves out lines set larger or smaller than the body (bylines, tables, captions, the reference list),
    /// whose raised numbers are affiliations and table notes.
    public mutating func count(line: String, runs: [PDFSmallRunClassifier.Run]) {
        bracketed += Self.bracketedNumbers(in: line)
        raisedAfterProse += runs.filter(Self.isRaisedNumberAfterProse).count
    }

    private static let bracketedNumber = try! NSRegularExpression(pattern: #"\[\d{1,3}(?:\s?[,;–-]\s?\d{1,3})*\]"#)

    static func bracketedNumbers(in line: String) -> Int {
        bracketedNumber.matches(in: line, range: NSRange(line.startIndex..., in: line)).filter { $0.range.location > 0 }.count
    }

    static func isRaisedNumberAfterProse(_ run: PDFSmallRunClassifier.Run) -> Bool {
        guard run.text.range(of: #"^[0-9,–\-]*[0-9][0-9,–\-]*$"#, options: .regularExpression) != nil,
              let previous = run.before.last else { return false }
        var cautious = run
        cautious.raisedNumbersCite = true
        guard PDFSmallRunClassifier.classify(cautious) == .footnoteMarker else { return false }
        if previous.isLetter {
            // After a word, not a lone letter ("x2"), capitals ("GL2", "NASA3") or a name ("Doe1").
            let word = run.before.reversed().prefix { $0.isLetter }
            return word.count >= 2 && word.allSatisfy(\.isLowercase)
        }
        return ".,;:!?”\"'’)]".contains(previous)
    }
}
