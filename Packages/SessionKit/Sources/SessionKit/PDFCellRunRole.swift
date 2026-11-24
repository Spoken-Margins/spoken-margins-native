import Foundation

/// Whether a run of table-cell-like lines on a PDF page is a table, text printed inside a figure, or neither (#4588).
///
/// The extractor finds the runs; this decides what each one is from where the page's captions sit, so the rule is
/// host-tested. Line indices are in the page's reading order.
///
/// 1. A "Table N" caption within three lines of the run makes it a table (three lines or more).
/// 2. Otherwise a run with its own figure caption (`ownFigureCaption`) is figure text (three lines or more).
///    Figures carry their caption underneath, so labels that run into one are that figure's, even when a table
///    caption is elsewhere on the page. Before #4588 such a run became a table whenever a table caption sat on the
///    page or near it: arXiv 2608.09666 page 4's pipeline diagram got a "Table" clip and "Table not read.", its last
///    labels were read aloud as sentences, and its card on Now never met its "Fig. 1." caption.
/// 3. Otherwise a run of five or more near a table caption (on this page, the next, or the three before: long
///    tables run on) is a table.
/// 4. Otherwise a run of three or more near a figure caption is figure text.
public enum PDFCellRunRole {
    public enum Role: Equatable, Sendable {
        case table
        case figure
    }

    /// How many lines from a run a table caption may be and still be the run's own.
    public static let captionReach = 3
    /// How many label lines that don't look like cells may stand between a figure's cells and its caption.
    public static let maximumLabelsBeforeCaption = 4
    /// How far below the figure's lowest line, in body-text line heights, its caption may start.
    public static let maximumCaptionGap = 6.0

    /// A figure caption that belongs to the run, and the lines between them that belong to the figure too.
    public struct FigureCaption: Equatable, Sendable {
        public let line: Int
        /// Label lines between the run and the caption ("Base Model EA-3B", "(b) Supervised Finetuning").
        public let labels: [Int]
    }

    /// The run's own figure caption: one the run swallowed (a short "Fig. 2" line can look like a cell), or the
    /// first caption after the run when only label lines stand between them, at most `maximumLabelsBeforeCaption`.
    /// A table caption or any other line on the way means the caption isn't the run's.
    /// - Parameter isLabel: whether a line between the run and the caption can be text printed in a figure:
    ///   short, not a sentence, not a caption.
    public static func ownFigureCaption(
        start: Int,
        end: Int,
        tableCaptions: [Int],
        figureCaptions: [Int],
        lineCount: Int,
        isLabel: (Int) -> Bool
    ) -> FigureCaption? {
        guard end >= start else { return nil }
        if let swallowed = figureCaptions.filter({ $0 > start && $0 <= end }).min() {
            return FigureCaption(line: swallowed, labels: [])
        }
        var labels: [Int] = []
        var index = end + 1
        while index < lineCount, labels.count <= maximumLabelsBeforeCaption {
            if figureCaptions.contains(index) { return FigureCaption(line: index, labels: labels) }
            if tableCaptions.contains(index) || !isLabel(index) { return nil }
            labels.append(index)
            index += 1
        }
        return nil
    }

    /// Whether a caption whose top is `gap` points below the figure's lowest line sits just under it. A picture
    /// between a table and a figure's caption leaves a wide gap, so that table stays a table.
    public static func isJustBelow(gap: Double, bodySize: Double) -> Bool {
        gap >= -bodySize && gap <= maximumCaptionGap * bodySize
    }

    public static func role(
        start: Int,
        end: Int,
        tableCaptions: [Int],
        hasOwnFigureCaption: Bool,
        nearTableCaption: Bool,
        nearFigureCaption: Bool
    ) -> Role? {
        guard end >= start else { return nil }
        let length = end - start + 1
        let captioned = tableCaptions.contains { $0 >= start - captionReach && $0 <= end + captionReach }
        if captioned {
            if length >= 3 { return .table }
        } else if length >= 3, hasOwnFigureCaption {
            return .figure
        } else if nearTableCaption && length >= 5 {
            return .table
        }
        if nearFigureCaption && length >= 3 { return .figure }
        return nil
    }
}
