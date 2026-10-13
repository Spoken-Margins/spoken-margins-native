import Foundation

/// A PDF section heading printed over two or three lines is one heading (#1144: the CASP
/// working paper's "Automating AI R&D could trigger an" / "intelligence explosion" became
/// two chapters). The PDF extractor asks this about consecutive heading lines that have no
/// outline entry to go by; outline headings are joined against their entry instead (#355).
///
/// The evidence is layout, not wording: the next line is set in the same type, directly
/// under the first at the heading's own line spacing, on the same column. A second heading
/// is set apart by space or body text. A line that starts a new section ("2 Methods",
/// "References") or follows the end of a sentence is never a continuation.
public enum PDFWrappedHeading {
    /// One heading line. Coordinates are PDF page space: y grows up the page.
    public struct Line: Equatable, Sendable {
        public var text: String
        public var pageIndex: Int
        public var pointSize: Double
        public var isBold: Bool
        public var minX: Double
        public var maxX: Double
        public var minY: Double
        public var maxY: Double

        public init(text: String, pageIndex: Int, pointSize: Double, isBold: Bool,
                    minX: Double, maxX: Double, minY: Double, maxY: Double) {
            self.text = text
            self.pageIndex = pageIndex
            self.pointSize = pointSize
            self.isBold = isBold
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }
    }

    /// A heading wraps over at most this many lines.
    public static let maximumLines = 3
    /// Longer than this joined, it is not one heading.
    public static let maximumJoinedLength = 160

    /// Whether `next` continues the heading `line` starts or continues.
    public static func continues(_ line: Line, with next: Line) -> Bool {
        let first = collapsed(line.text), second = collapsed(next.text)
        guard !first.isEmpty, !second.isEmpty,
              first.count + 1 + second.count <= maximumJoinedLength,
              line.pageIndex == next.pageIndex,
              line.pointSize > 0, abs(line.pointSize - next.pointSize) < 0.3,
              line.isBold == next.isBold else { return false }
        // Directly below, one line of this type further down: a heading's own leading is
        // about 1.0-1.5 times its size; a second heading sits after a gap or body text.
        let size = line.pointSize
        let pitch = (line.minY + line.maxY) / 2 - (next.minY + next.maxY) / 2
        guard pitch >= size * 0.8, pitch <= size * 1.6 else { return false }
        // The same column: flush left, or centred on the same middle.
        let sameLeft = abs(line.minX - next.minX) <= 4
        let sameCentre = abs((line.minX + line.maxX) / 2 - (next.minX + next.maxX) / 2) <= 4
        guard sameLeft || sameCentre else { return false }
        if first.range(of: #"[.!?]["'”’)]?$"#, options: .regularExpression) != nil { return false }
        return !startsSection(second)
    }

    /// The heading as one line: a line-end hyphen joins without a space ("Large-" +
    /// "scale"), anything else with one space.
    public static func joined(_ texts: [String]) -> String {
        texts.map(collapsed).filter { !$0.isEmpty }.reduce("") { result, text in
            result.isEmpty ? text : result.hasSuffix("-") ? result + text : result + " " + text
        }
    }

    /// "2 Methods", "2.1 Hardware", "IV. Results", "Appendix A", or a standalone section name.
    static func startsSection(_ text: String) -> Bool {
        text.range(of: #"^(?:[0-9]+(?:\.[0-9]+)*\.?\s+\S|[IVX]+\.\s+\S|(?i:chapter|part|section|appendix)\s+[0-9A-Z]\b)"#,
                   options: .regularExpression) != nil
            || text.range(of: #"^(?:abstract|summary|introduction|background|related work|methods?|materials and methods|results|discussion|conclusions?|acknowledge?ments?|references|bibliography|notes|appendix|supplementary materials?)$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
