import Foundation

/// Finds the "Figure N" captions of a PDF in the lines the extractor read and turns the ones with a clear empty band
/// into floats for a picture that has no printed text inside it (#4587). It is the document builder's step after
/// `PDFClipLocator.floats`, kept in its own type so `StructuredDocument.swift` does not grow.
///
/// Nothing here changes text, segments, roles or markers: the lines' rectangles only feed the clip code. A float it
/// makes names its caption's segment and label and has no `textSegmentId`, so no segment links to it.
enum PDFCaptionFloatBuilder {
    /// One kept line: where the builder put it and where the extractor found it on its page.
    struct Line: Equatable {
        var segmentId: String
        /// The cleaned text, the text `PDFClipAnchors` reads, so a caption is found by the same words in both.
        var text: String
        var role: StructuredDocument.Role
        var pageIndex: Int
        var bounds: PDFNormalizedRect
    }

    /// A caption joins at most this many lines: a legend of several sentences, not a paragraph that follows it.
    static let maximumCaptionLines = 25
    /// How far a line may sit below the one before it and still be the caption's next line, in the opening line's heights.
    static let largestLineGap = 1.0
    /// PDFKit's line boxes often overlap a little; an overlap up to this much of the opening line's height still joins.
    static let largestLineOverlap = 0.3

    /// The key `labelCounts` is counted under.
    static func openingLabelKey(segmentId: String, label: String) -> String { "\(segmentId)|\(label)" }

    /// The label of the caption a line opens, or nil. A cheap prefix test comes first, so the regular expressions run
    /// only on lines that could be captions.
    static func openingLabel(role: StructuredDocument.Role, text: String) -> String? {
        guard canHoldCaption(role), text.hasPrefix("Fig") || text.hasPrefix("FIG") else { return nil }
        return PDFFigureCaption.label(of: text)
    }

    /// Roles whose lines can open or continue a caption: extractors read a caption as body text, and sometimes as a
    /// heading.
    private static func canHoldCaption(_ role: StructuredDocument.Role) -> Bool {
        role == .body || role == .heading || role == .caption
    }

    /// The caption floats, text floats excluded, in page order and then top-down, at most
    /// `PDFClipLocator.maximumFloatsPerDocument - textFloats.count` of them.
    /// - Parameters:
    ///   - lines: every kept line that has a rectangle and a page, in the order the extractor read them.
    ///   - unplacedPages: pages with a line that has no rectangle (other than a title or page furniture). Never guess
    ///     past text we can't place: such a page gets no caption float.
    ///   - textFloats: the floats `PDFClipLocator` made from printed table and figure text. They come first under the
    ///     cap, and a band that meets one of them is dropped.
    ///   - useTextArea: whether a figure at the top or bottom of a page is measured to the document's text area.
    ///   - labelCounts: how many lines of the whole document open a caption with each label, by segment and label
    ///     (`openingLabelKey`), counted over every line, placed or not, on every page. `PDFClipAnchors` finds a
    ///     caption by its label in its segment, and a segment usually holds every page's body lines, so a label that
    ///     opens two lines of one segment gives no float to either.
    static func floats(
        from lines: [Line], unplacedPages: Set<Int>, textFloats: [StructuredDocument.Float], useTextArea: Bool = true,
        labelCounts: [String: Int]
    ) -> [StructuredDocument.Float] {
        let room = PDFClipLocator.maximumFloatsPerDocument - textFloats.count
        guard room > 0, !lines.isEmpty else { return [] }
        var pages: [Int: [Line]] = [:]
        for line in lines { pages[line.pageIndex, default: []].append(line) }
        let order = pages.keys.sorted()

        let furnitureRoles: Set<StructuredDocument.Role> = [.pageHeader, .pageFooter]
        let textArea: PDFFigureCaptionLocator.TextArea? = useTextArea
            ? PDFFigureCaptionLocator.textArea(pages: order.filter { !unplacedPages.contains($0) }.map { pages[$0, default: []].filter { !furnitureRoles.contains($0.role) }.map(\.bounds) })
            : nil

        var result: [StructuredDocument.Float] = []
        for page in order where !unplacedPages.contains(page) {
            let pageLines = pages[page, default: []]
            let (blocks, consumed) = captionBlocks(in: pageLines)
            guard !blocks.isEmpty else { continue }

            // Two captions with one label in one segment, on this page or another: `PDFClipAnchors` could not tell
            // them apart. They still bound each other's bands.
            let ambiguous = Set(blocks.filter { labelCounts[openingLabelKey(segmentId: $0.segmentId, label: $0.label), default: 0] > 1 }.map(\.id))

            let textBlocks = pageLines.indices.filter { !consumed.contains($0) }.map { pageLines[$0] }
                .filter { $0.role != .pageHeader && $0.role != .pageFooter && $0.role != .figureText }.map(\.bounds)
            let furniture = pageLines.filter { furnitureRoles.contains($0.role) }.map(\.bounds)
            let figureRegions = textFloats.filter { $0.pageIndex == page }.map(\.bounds)
            let regions = PDFFigureCaptionLocator.regions(
                captions: blocks.map { .init(id: $0.id, bounds: $0.bounds) }, textBlocks: textBlocks,
                figureRegions: figureRegions, furniture: furniture, textArea: textArea)

            let found = regions.filter { !ambiguous.contains($0.captionId) }.compactMap { region in
                blocks.first { $0.id == region.captionId }.map { (block: $0, region: region) }
            }.sorted { $0.region.bounds.y + $0.region.bounds.height > $1.region.bounds.y + $1.region.bounds.height }
            for (index, item) in found.enumerated() {
                result.append(StructuredDocument.Float(
                    id: "float-p\(page + 1)-c\(index + 1)",
                    kind: .figure,
                    label: item.block.label,
                    pageIndex: page,
                    bounds: item.region.bounds,
                    captionSegmentId: item.block.segmentId,
                    textSegmentId: nil
                ))
                if result.count >= room { return result }
            }
        }
        return result
    }

    private struct Block {
        var id: String
        var segmentId: String
        var label: String
        var bounds: PDFNormalizedRect
    }

    /// The caption blocks of one page, and the indices of the lines they took.
    ///
    /// A line opens a block when its role can hold a caption, its text starts a caption and gives a label. The lines
    /// after it, in reading order and whatever their segment, join while they are body, heading or caption text, sit no
    /// more than a line below the last one (a little overlap is fine), overlap the block horizontally by at least half
    /// their own width, and do not open a caption of their own, up to `maximumCaptionLines`. A heading-role caption's
    /// continuation lines are body lines in the next segment, so the block crosses segments.
    private static func captionBlocks(in lines: [Line]) -> (blocks: [Block], consumed: Set<Int>) {
        var blocks: [Block] = []
        var consumed: Set<Int> = []
        var index = 0
        while index < lines.count {
            let opening = lines[index]
            guard let label = openingLabel(role: opening.role, text: opening.text) else { index += 1; continue }
            var union = opening.bounds
            var last = opening.bounds
            var end = index + 1
            while end < lines.count, end - index < maximumCaptionLines {
                let next = lines[end]
                guard canHoldCaption(next.role), openingLabel(role: next.role, text: next.text) == nil,
                      !PDFFigureCaption.isCaptionStart(next.text) else { break }
                let gap = last.y - (next.bounds.y + next.bounds.height)
                let overlap = min(next.bounds.x + next.bounds.width, union.x + union.width) - max(next.bounds.x, union.x)
                guard gap >= -largestLineOverlap * opening.bounds.height, gap <= largestLineGap * opening.bounds.height,
                      overlap >= next.bounds.width / 2 else { break }
                union = unite(union, next.bounds)
                last = next.bounds
                end += 1
            }
            for taken in index..<end { consumed.insert(taken) }
            blocks.append(Block(id: "b\(blocks.count)", segmentId: opening.segmentId, label: label, bounds: union))
            index = end
        }
        return (blocks, consumed)
    }

    private static func unite(_ a: PDFNormalizedRect, _ b: PDFNormalizedRect) -> PDFNormalizedRect {
        let left = min(a.x, b.x), bottom = min(a.y, b.y)
        let right = max(a.x + a.width, b.x + b.width), top = max(a.y + a.height, b.y + b.height)
        return PDFNormalizedRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
