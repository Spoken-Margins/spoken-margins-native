import Foundation
import SessionKit

/// The two calls the "Word document with your Margins" sheet makes (#4595): find where each Margin's comment goes, then
/// write a copy with the ones the listener kept. It adds nothing to `DocxCommentWriter`; it is the one place that turns
/// a plan into requests and applies the listener's choice, as `PDFCommentExporter` is for a PDF, so the app's model
/// has no package details in it.
public enum WordCommentExporter {
    public struct Preview: Equatable, Sendable {
        /// One per Margin with words, in the plan's order.
        public var placements: [DocxMarginPlacement]
        /// The same, reduced to what the sheet says, by Margin id.
        public var spots: [String: PDFCommentExportState.Spot]
    }

    /// Finds where every Margin of `plan` that has words would land in `source`. Nothing is written.
    /// - Throws: `DocxCommentWriter.Failure.notADocx` or `.unsupportedDocument`.
    public static func preview(source: URL, plan: MarginCommentPlan) throws -> Preview {
        let placements = try DocxCommentWriter.preview(source: source, requests: plan.included.map(DocxCommentWriter.Request.init(entry:)))
        return Preview(placements: placements, spots: Dictionary(placements.map { ($0.marginId, $0.exportSpot) }) { first, _ in first })
    }

    /// Writes a copy of `source` to `destination` with the comments for `includedIds` only. The source's bytes are the
    /// same afterwards. Returns how many comments were written.
    @discardableResult
    public static func export(
        source: URL, plan: MarginCommentPlan, includedIds: [String], author: String, to destination: URL
    ) throws -> Int {
        let chosen = Set(includedIds)
        let requests = plan.included.filter { chosen.contains($0.marginId) }.map(DocxCommentWriter.Request.init(entry:))
        try DocxCommentWriter.write(source: source, requests: requests, author: author, to: destination)
        return requests.count
    }
}

extension DocxMarginPlacement {
    /// What the sheet says about where this comment went.
    public var exportSpot: PDFCommentExportState.Spot {
        switch spot {
        case .sentence(let whole): return .wordSentence(whole: whole)
        case .paragraph: return .wordParagraph
        case .firstParagraph: return .wordFirstParagraph
        }
    }
}
