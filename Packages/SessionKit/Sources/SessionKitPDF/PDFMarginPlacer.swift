import CoreGraphics
import Foundation
import PDFKit
import SessionKit

/// Where one Margin's comment goes on a PDF (#4338).
public struct PDFMarginPlacement: Equatable, Sendable {
    public enum Spot: Equatable, Sendable {
        /// The sentence, or the start of it (`wholeSentence` false), as one rectangle per line it covers, in the
        /// page's own space: the space `PDFAnnotation.bounds` and its quadrilateral points use.
        case highlight(page: Int, lineRects: [CGRect], wholeSentence: Bool)
        /// No exact place: a note at the top of this page.
        case pageNote(page: Int)
    }

    public var marginId: String
    public var spot: Spot

    public init(marginId: String, spot: Spot) {
        self.marginId = marginId
        self.spot = spot
    }

    /// The zero-based page the comment goes on.
    public var pageIndex: Int {
        switch spot {
        case .highlight(let page, _, _), .pageNote(let page): return page
        }
    }
}

/// Turns a `MarginCommentPlan` into places on the pages of a real PDF (#4338, PR 3b).
///
/// The rule that finds a sentence in a page's text is `PDFSentenceLocator` in SessionKit, a pure function with its own
/// host tests. This is the thin PDFKit side around it: the page's text from PDFKit, the located range turned into
/// PDFKit's own text selection, and that selection read back as one rectangle per line. It lives in its own target so
/// `SessionKit` stays free of PDFKit and still builds on Linux. Nothing here changes the document, and nothing calls it
/// from the app yet.
public enum PDFMarginPlacer {
    public enum Failure: Error, Equatable, Sendable {
        /// The file needs a password, or its owner has switched comments off: nothing can be added to it.
        case locked
        /// The file has no pages.
        case noPages
    }

    /// Why comments cannot be added to `document`, or nil when they can. Cheap, so the export sheet can ask before it
    /// builds a plan.
    public static func refusal(for document: PDFDocument) -> Failure? {
        if document.isLocked { return .locked }
        if document.isEncrypted, !document.allowsCommenting { return .locked }
        if document.pageCount == 0 { return .noPages }
        return nil
    }

    /// One placement for each Margin of `plan` that has words to send (`plan.included`), in the plan's order.
    /// - Throws: `Failure` when `refusal(for:)` names one.
    public static func place(plan: MarginCommentPlan, document: PDFDocument) throws -> [PDFMarginPlacement] {
        if let failure = refusal(for: document) { throw failure }
        let pageCount = document.pageCount
        let texts = PageTexts(document: document)
        return plan.included.map { entry in
            let located = PDFSentenceLocator.locate(
                sentence: entry.sentenceText,
                hintedPage: entry.pageIndex,
                preceding: entry.precedingText,
                pageCount: pageCount,
                pageText: { texts.text(of: $0) }
            )
            switch located {
            case .pageNote(let page):
                return PDFMarginPlacement(marginId: entry.marginId, spot: .pageNote(page: page))
            case .highlight(let page, let range, let wholeSentence):
                // The text PDFKit gave for the page is the one the range counts in; a page or a selection PDFKit then
                // cannot produce is a page note, never a highlight with nothing to draw.
                guard let text = texts.text(of: page), let pdfPage = document.page(at: page),
                      let rects = lineRects(of: range, in: text, on: pdfPage), !rects.isEmpty else {
                    return PDFMarginPlacement(marginId: entry.marginId, spot: .pageNote(page: page))
                }
                return PDFMarginPlacement(marginId: entry.marginId, spot: .highlight(page: page, lineRects: rects, wholeSentence: wholeSentence))
            }
        }
    }

    /// The rectangles, one per line, that PDFKit gives for the characters `range` (offsets in `Character`s of `text`).
    private static func lineRects(of range: Range<Int>, in text: String, on page: PDFPage) -> [CGRect]? {
        guard let start = text.index(text.startIndex, offsetBy: range.lowerBound, limitedBy: text.endIndex),
              let end = text.index(start, offsetBy: range.count, limitedBy: text.endIndex),
              start < end,
              let selection = page.selection(for: NSRange(start..<end, in: text)) else { return nil }
        return selection.selectionsByLine()
            .map { $0.bounds(for: page) }
            .filter { !$0.isNull && !$0.isInfinite && !$0.isEmpty }
    }

    /// Each page's text, asked of PDFKit once however many Margins look at that page.
    private final class PageTexts {
        private let document: PDFDocument
        private var loaded: [Int: String?] = [:]

        init(document: PDFDocument) { self.document = document }

        func text(of index: Int) -> String? {
            if let known = loaded[index] { return known }
            let text = document.page(at: index)?.string
            loaded[index] = .some(text)
            return text
        }
    }
}
