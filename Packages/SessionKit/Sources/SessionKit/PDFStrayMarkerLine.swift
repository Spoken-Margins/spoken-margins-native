import Foundation

/// A raised footnote or citation number that PDFKit returns as a line of its own (#4256). In one C1 paper the
/// body reads "we assume Gtx = Grx = 1." and the next line holds only the footnote's "1", set small and raised
/// where that line ends. A run at a line's start is never a marker, so the "1" was read aloud, and the page had
/// no marker to link its footnote by. The number belongs to the line it is printed against.
///
/// Only a number after prose is taken, and only one the classifier would call a marker there. On C1 PDFKit
/// splits off 119 short runs this way and most are pieces of an equation ("p" over "p", "C′" then "2"): joined
/// to the piece before, some would read as markers and go silent. This is pure: the caller measures both lines.
public enum PDFStrayMarkerLine {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// In page coordinates, where y grows upward.
        public var bounds: CGRect
        /// The size most of the line is set in.
        public var pointSize: Double

        public init(text: String, bounds: CGRect, pointSize: Double) {
            self.text = text
            self.bounds = bounds
            self.pointSize = pointSize
        }
    }

    /// Smaller than the line by at least this share, as the extractor's small runs are.
    static let smallerBy = 0.8
    /// Starts within this share of the line's type size of where the line ends.
    static let gap = 0.3
    /// Its bottom is above the line's bottom by more than this share of the line's type size. A raised number
    /// sits about half the size up; a small number set level sits about a seventh up, its shorter descender.
    static let raisedBy = 0.25

    /// `candidate` is a raised number printed at the end of `line`, the line before it.
    public static func isMarker(_ candidate: Line, atEndOf line: Line) -> Bool {
        guard candidate.text.range(of: #"^[0-9]{1,3}(?:[,–\-][0-9]{1,3})*$"#, options: .regularExpression) != nil,
              candidate.pointSize > 0, line.pointSize > 0, candidate.pointSize <= line.pointSize * smallerBy,
              abs(candidate.bounds.minX - line.bounds.maxX) <= line.pointSize * gap,
              candidate.bounds.minY - line.bounds.minY > line.pointSize * raisedBy,
              candidate.bounds.minY < line.bounds.maxY else { return false }
        // Prose, not a byline ("16, 17 R. A. Cameron,") or a piece of an equation ("where 0 < ζ ⩽ 1−").
        let words = line.text.split(whereSeparator: \.isWhitespace).filter { token in
            let word = token.drop(while: { "(“\"‘'".contains($0) }).reversed().drop(while: { ".,;:!?)”\"’'".contains($0) })
            return word.count >= 2 && word.allSatisfy { $0.isLetter && $0.isLowercase }
        }
        guard words.count >= 2 else { return false }
        let run = PDFSmallRunClassifier.Run(text: candidate.text, before: line.text, baselineShift: nil)
        return PDFSmallRunClassifier.classify(run) == .footnoteMarker
    }
}
