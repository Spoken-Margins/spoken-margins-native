import CoreGraphics
import Foundation
import PDFKit
import SessionKit

/// Writes a copy of a PDF with each Margin as a real comment (#4338, PR 4).
///
/// One highlight on the sentence for each Margin `PDFMarginPlacer` could place, with the Margin's words as the comment's
/// text and the listener's name as its author; one text note at the top left of the page for each Margin that could only
/// be given a page. The copy is a new file. The original is opened and read, never written: its bytes are the same
/// afterwards, and writing to the original's own address is refused. Audio is not embedded. Nothing calls this from the
/// app yet.
public enum PDFCommentWriter {
    public struct Summary: Equatable, Sendable {
        public var highlights: Int
        public var pageNotes: Int
        /// Placements left out: no words for that Margin in the plan, or a page the file doesn't have.
        public var skipped: Int

        public init(highlights: Int, pageNotes: Int, skipped: Int) {
            self.highlights = highlights
            self.pageNotes = pageNotes
            self.skipped = skipped
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// PDFKit could not open the source.
        case unreadable
        /// The file takes no comments (`PDFMarginPlacer.refusal(for:)`).
        case refused(PDFMarginPlacer.Failure)
        /// The destination is the source itself.
        case destinationIsTheSource
        /// PDFKit could not write the copy.
        case couldNotWrite
    }

    /// - Parameters:
    ///   - plan: where the words come from (`plan.included`, by Margin id).
    ///   - placements: from `PDFMarginPlacer.place(plan:document:)` on this same file.
    ///   - author: the name each comment carries (`PDFAnnotation.userName`).
    ///   - destination: where the copy goes. An existing file there is replaced.
    @discardableResult
    public static func write(
        source: URL,
        plan: MarginCommentPlan,
        placements: [PDFMarginPlacement],
        author: String,
        date: Date = Date(),
        to destination: URL
    ) throws -> Summary {
        guard !isSameFile(source, destination) else { throw Failure.destinationIsTheSource }
        guard let document = PDFDocument(url: source) else { throw Failure.unreadable }
        if let refusal = PDFMarginPlacer.refusal(for: document) { throw Failure.refused(refusal) }

        let words = Dictionary(
            plan.included.map { ($0.marginId, $0.commentText.trimmingCharacters(in: .whitespacesAndNewlines)) },
            uniquingKeysWith: { first, _ in first }
        )
        var summary = Summary(highlights: 0, pageNotes: 0, skipped: 0)
        var notesOnPage: [Int: Int] = [:]
        for placement in placements {
            guard let text = words[placement.marginId], !text.isEmpty, placement.pageIndex >= 0,
                  let page = document.page(at: placement.pageIndex) else {
                summary.skipped += 1
                continue
            }
            switch placement.spot {
            case .highlight(_, let lineRects, _):
                if let annotation = highlight(lineRects: lineRects, text: text, author: author, date: date) {
                    page.addAnnotation(annotation)
                    summary.highlights += 1
                    continue
                }
                // A highlight with no rectangle has nothing to draw: it goes on the page as a note instead.
                fallthrough
            case .pageNote:
                let slot = notesOnPage[placement.pageIndex, default: 0]
                notesOnPage[placement.pageIndex] = slot + 1
                page.addAnnotation(pageNote(on: page, slot: slot, text: text, author: author, date: date))
                summary.pageNotes += 1
            }
        }
        guard document.write(to: destination) else { throw Failure.couldNotWrite }
        return summary
    }

    private static func highlight(lineRects: [CGRect], text: String, author: String, date: Date) -> PDFAnnotation? {
        guard let bounds = PDFCommentGeometry.union(of: lineRects) else { return nil }
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.quadrilateralPoints = PDFCommentGeometry.quadrilateralPoints(lineRects: lineRects, relativeTo: bounds).map(value)
        describe(annotation, text: text, author: author, date: date)
        return annotation
    }

    private static func pageNote(on page: PDFPage, slot: Int, text: String, author: String, date: Date) -> PDFAnnotation {
        let space = noteSpace(of: page)
        let bounds = PDFCommentGeometry.pageNoteBounds(pageBounds: space.bounds, rotation: space.rotation, slot: slot)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        describe(annotation, text: text, author: author, date: date)
        return annotation
    }

    /// The bounds and rotation `pageNoteBounds` should be given for a page. A PDF's own `/Rect` is in the page's default
    /// space, before `/Rotate`. If PDFKit hands back the page's bounds as drawn (width and height swapped on a
    /// quarter-turned page, which only a page that is not square can show), its annotation space is the drawn page and
    /// its top left is simply `(minX, maxY)`: then no rotation is applied. Otherwise the page's `/Rotate` is.
    private static func noteSpace(of page: PDFPage) -> (bounds: CGRect, rotation: Int) {
        let kit = page.bounds(for: .cropBox)
        let rotation = page.rotation
        let quarterTurn = (((rotation / 90) % 4) + 4) % 4 % 2 == 1
        if quarterTurn, let raw = page.pageRef?.getBoxRect(.cropBox), abs(raw.width - raw.height) > 1,
           abs(kit.width - raw.height) < 1, abs(kit.height - raw.width) < 1 {
            return (kit, 0)
        }
        return (kit, rotation)
    }

    /// Whether two addresses are one file: the same path once links are resolved, or, for a file that exists, the same
    /// file on disk (a different spelling on a case-insensitive volume, a hard link).
    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL { return true }
        guard let first = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    private static func describe(_ annotation: PDFAnnotation, text: String, author: String, date: Date) {
        annotation.contents = text
        annotation.userName = author
        annotation.modificationDate = date
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
    }

    private static func value(_ point: CGPoint) -> NSValue {
        #if canImport(UIKit)
        return NSValue(cgPoint: point)
        #else
        return NSValue(point: point)
        #endif
    }
}
