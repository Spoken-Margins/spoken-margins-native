import Foundation
import PDFKit
import SessionKit

/// The two calls the "PDF with your Margins" sheet makes (#4338, PR 5): find where each Margin's comment goes, then
/// write a copy with the ones the listener kept. It adds nothing to `PDFMarginPlacer` and `PDFCommentWriter`; it is the
/// one place that opens the file by address, turns a refusal into the writer's `Failure`, and applies the listener's
/// choice, so the app's model has no PDFKit in it.
public enum PDFCommentExporter {
    public struct Preview: Equatable, Sendable {
        /// One per Margin with words, as `PDFMarginPlacer.place` returned them.
        public var placements: [PDFMarginPlacement]
        /// The same, reduced to what the sheet says, by Margin id.
        public var spots: [String: PDFCommentExportState.Spot]

        public init(placements: [PDFMarginPlacement], spots: [String: PDFCommentExportState.Spot]) {
            self.placements = placements
            self.spots = spots
        }
    }

    /// Opens `source` and places every Margin of `plan` that has words. Nothing is written.
    /// - Throws: `PDFCommentWriter.Failure.unreadable` when PDFKit can't open it, `.refused(.locked)` or `.refused(.noPages)`
    ///   when it takes no comments.
    public static func preview(source: URL, plan: MarginCommentPlan) throws -> Preview {
        guard let document = PDFDocument(url: source) else { throw PDFCommentWriter.Failure.unreadable }
        do {
            let placements = try PDFMarginPlacer.place(plan: plan, document: document)
            var spots: [String: PDFCommentExportState.Spot] = [:]
            for placement in placements { spots[placement.marginId] = placement.exportSpot }
            return Preview(placements: placements, spots: spots)
        } catch let failure as PDFMarginPlacer.Failure {
            throw PDFCommentWriter.Failure.refused(failure)
        }
    }

    /// What `check(chosen:plan:expectedPageCount:)` decided about a file the listener chose.
    public enum ChosenFile: Equatable, Sendable {
        /// The same PDF: its placements, ready for the sheet and the export.
        case accepted(Preview)
        case refused(PDFOriginalCheck.Refusal)
    }

    /// Opens a PDF the listener chose for an item this iPhone has no copy of (#4338, PR 6), places the plan's Margins on it
    /// and applies `PDFOriginalCheck`. Nothing is written and nothing is kept: the caller keeps an accepted file.
    /// - Parameter expectedPageCount: the page count the item's text recorded (`Extraction.pageCount`).
    public static func check(chosen: URL, plan: MarginCommentPlan, expectedPageCount: Int) -> ChosenFile {
        guard let document = PDFDocument(url: chosen) else { return .refused(.unreadable) }
        switch PDFMarginPlacer.refusal(for: document) {
        case .locked?: return .refused(.locked)
        case .noPages?: return .refused(.unreadable)
        case nil: break
        }
        // The page count first: a different document is refused without placing anything.
        if let refusal = PDFOriginalCheck.pageCountRefusal(pickedPageCount: document.pageCount, expectedPageCount: expectedPageCount) {
            return .refused(refusal)
        }
        guard let placements = try? PDFMarginPlacer.place(plan: plan, document: document) else { return .refused(.unreadable) }
        var spots: [String: PDFCommentExportState.Spot] = [:]
        for placement in placements { spots[placement.marginId] = placement.exportSpot }
        if let refusal = PDFOriginalCheck.evaluate(
            pickedPageCount: document.pageCount, expectedPageCount: expectedPageCount, plan: plan, spots: spots
        ) {
            return .refused(refusal)
        }
        return .accepted(Preview(placements: placements, spots: spots))
    }

    /// Writes a copy of `source` to `destination` with the comments for `includedIds` only. The source's bytes are the
    /// same afterwards (`PDFCommentWriter`).
    @discardableResult
    public static func export(
        source: URL,
        plan: MarginCommentPlan,
        placements: [PDFMarginPlacement],
        includedIds: [String],
        author: String,
        to destination: URL
    ) throws -> PDFCommentWriter.Summary {
        let chosen = Set(includedIds)
        let kept = placements.filter { chosen.contains($0.marginId) }
        return try PDFCommentWriter.write(source: source, plan: plan, placements: kept, author: author, to: destination)
    }
}

extension PDFMarginPlacement {
    /// What the sheet says about where this comment went.
    public var exportSpot: PDFCommentExportState.Spot {
        switch spot {
        case .highlight(let page, _, _): return .sentence(page: page)
        case .pageNote(let page): return .pageNote(page: page)
        }
    }
}
