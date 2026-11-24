import Foundation

/// Whether a run of table-cell-like lines on a PDF page is a table, text printed inside a figure, or neither (#4588).
///
/// The extractor finds the runs; this decides what each one is from where the page's captions sit, so the rule is
/// host-tested. Line indices are in the page's reading order.
///
/// 1. A "Table N" caption within three lines of the run makes it a table (three lines or more).
/// 2. Otherwise a "Fig. N" caption that follows the run within three lines and sits just under it on the page (at
///    most `maximumCaptionGap` body lines below its lowest line) makes it figure text (three lines or more). Figures
///    carry their caption underneath, so labels that run straight into one are that figure's, even when a table
///    caption is elsewhere on the page. The gap keeps a table that sits above a picture-only figure a table: the
///    picture stands between the table and the caption. Before #4588 such a run became a table whenever a table
///    caption sat on the page or near it: arXiv 2608.09666 page 4's pipeline diagram got a "Table" clip and
///    "Table not read.", and its card on Now never met its "Fig. 1." caption.
/// 3. Otherwise a run of five or more near a table caption (on this page, the next, or the three before: long
///    tables run on) is a table.
/// 4. Otherwise a run of three or more near a figure caption is figure text.
public enum PDFCellRunRole {
    public enum Role: Equatable, Sendable {
        case table
        case figure
    }

    /// How many lines from a run a caption may be and still be the run's own.
    public static let captionReach = 3
    /// How far below a run's lowest line, in body-text line heights, its figure's caption may start.
    public static let maximumCaptionGap = 6.0

    /// - Parameter figureCaptionGaps: for each figure caption line, how far its top is below the run's lowest line,
    ///   in points (negative when it is higher). A caption with no entry has no known place and never takes the run
    ///   by rule 2.
    public static func role(
        start: Int,
        end: Int,
        tableCaptions: [Int],
        figureCaptions: [Int],
        figureCaptionGaps: [Int: Double] = [:],
        bodySize: Double = 10,
        nearTableCaption: Bool,
        nearFigureCaption: Bool
    ) -> Role? {
        guard end >= start else { return nil }
        let length = end - start + 1
        let captioned = tableCaptions.contains { $0 >= start - captionReach && $0 <= end + captionReach }
        // A caption the run swallowed (a short "Fig. 2" line can look like a cell) still follows the labels above it.
        let ownFigureCaption = figureCaptions.contains { line in
            guard line > start, line <= end + captionReach, let gap = figureCaptionGaps[line] else { return false }
            return gap >= -bodySize && gap <= maximumCaptionGap * bodySize
        }
        if captioned {
            if length >= 3 { return .table }
        } else if length >= 3, ownFigureCaption {
            return .figure
        } else if nearTableCaption && length >= 5 {
            return .table
        }
        if nearFigureCaption && length >= 3 { return .figure }
        return nil
    }
}
