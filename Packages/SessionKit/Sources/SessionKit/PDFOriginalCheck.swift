import Foundation

/// Whether a PDF the listener chose is the one their item was made from (#4338, PR 6).
///
/// A PDF added before the app kept copies, or synced from another iPhone, has no file here and no recorded hash to compare.
/// So the sheet asks the listener to choose the same file once and accepts it when it has the page count the item's text
/// recorded and at least half the Margins that will be sent land on their sentence in it. An accepted file is kept, so
/// the question is not asked again. PDFKit opens the file and places the Margins (`SessionKitPDF`); the rule is here, so
/// it is host-tested on Linux.
public enum PDFOriginalCheck {
    public enum Refusal: Error, Equatable, Sendable {
        /// The chosen file has `picked` pages and the item's PDF had `expected`.
        case pageCount(picked: Int, expected: Int)
        /// Only `placed` of the `of` Margins with words found their sentence in the chosen file.
        case tooFewPlaced(placed: Int, of: Int)
        /// The chosen file needs a password or takes no comments.
        case locked
        /// The chosen file could not be opened as a PDF, or has no pages.
        case unreadable
        /// The item recorded no page count and no Margin has words yet, so nothing shows the file is the same one. It is
        /// not kept: a wrong file kept here would be used for every later export.
        case nothingToCompare

        /// The card's words.
        public var message: String {
            switch self {
            case .pageCount(let picked, let expected):
                return "That isn't the same PDF: it has \(Self.pages(picked)) and yours had \(expected)."
            case .tooFewPlaced(0, let of):
                return "None of the \(of) Margins found its sentence in that file. Choose the file you added."
            case .tooFewPlaced(let placed, let of):
                return "Only \(placed) of \(of) Margins found \(placed == 1 ? "its" : "their") sentence in that file. Choose the file you added."
            case .locked:
                return "That PDF is locked, so comments can't be added to it. Choose the file you added."
            case .unreadable:
                return "That file couldn't be opened as a PDF. Choose the file you added."
            case .nothingToCompare:
                return "Your Margins here have no words yet, so that file can't be checked. Try again once they're written out."
            }
        }

        private static func pages(_ count: Int) -> String { count == 1 ? "1 page" : "\(count) pages" }
    }

    /// The page-count half of the check, which needs no placement: nil when the counts agree, or when the item recorded
    /// no page count (zero or less) to compare with.
    public static func pageCountRefusal(pickedPageCount: Int, expectedPageCount: Int) -> Refusal? {
        guard expectedPageCount > 0, pickedPageCount != expectedPageCount else { return nil }
        return .pageCount(picked: pickedPageCount, expected: expectedPageCount)
    }

    /// The whole check: nil when the chosen file is accepted.
    /// - Parameters:
    ///   - spots: where each Margin of `plan` landed in the chosen file, by Margin id.
    /// A plan with no Margin that has words is accepted on its page count alone (there is nothing to place), and refused
    /// when the item recorded no page count either.
    public static func evaluate(
        pickedPageCount: Int, expectedPageCount: Int, plan: MarginCommentPlan, spots: [String: PDFCommentExportState.Spot]
    ) -> Refusal? {
        if let refusal = pageCountRefusal(pickedPageCount: pickedPageCount, expectedPageCount: expectedPageCount) {
            return refusal
        }
        let ids = plan.included.map(\.marginId)
        guard !ids.isEmpty else { return expectedPageCount > 0 ? nil : .nothingToCompare }
        let placed = ids.filter {
            if case .sentence? = spots[$0] { return true }
            return false
        }.count
        return placed * 2 >= ids.count ? nil : .tooFewPlaced(placed: placed, of: ids.count)
    }
}
