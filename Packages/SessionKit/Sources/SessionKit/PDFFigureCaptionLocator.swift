import Foundation

/// What a printed "Figure N" caption looks like, shared by the PDF extractor and the figure locator (#4587).
public enum PDFFigureCaption {
    /// A line that opens a figure caption: "Figure 3.", "Fig. 2:", "FIGURE 4 Results", "Figure S2 (left)". A body
    /// sentence that only mentions a figure ("Figure 3 shows the…", "as in Figure 3.") is not one: the number must be
    /// followed by punctuation, the line's end, a capital letter or a bracket, and the line must start with the word.
    public static func isCaptionStart(_ text: String) -> Bool {
        text.range(of: #"^(?:Fig(?:ure)?\.?|FIG(?:URE)?\.?)\s*[0-9S]+[0-9.]*(?:[.:|]|\s*$|\s+\p{Lu}|\s*\()"#, options: .regularExpression) != nil
    }

    /// "Figure 3" for a caption that starts "Fig. 3: …", or nil when the line is not a caption.
    public static func label(of text: String) -> String? {
        guard isCaptionStart(text),
              let range = text.range(of: #"^(?:Fig(?:ure)?\.?|FIG(?:URE)?\.?)\s*[0-9S]+[0-9.]*"#, options: .regularExpression)
        else { return nil }
        let number = text[range].drop { !($0.isNumber || $0 == "S") }
        let trimmed = number.reversed().drop { $0 == "." }.reversed()
        return trimmed.isEmpty ? nil : "Figure " + String(trimmed)
    }
}

/// Finds the picture of a figure that has no printed text inside it, from its "Figure N" caption and the text
/// around it (#4587, amending point 8 of the #3895 Design).
///
/// `PDFClipLocator` can only clip a figure whose own text PDFKit reports. A photo, a micrograph or a chart without
/// labels has none, but its caption is printed next to it, so the figure is the empty band between the caption and the
/// nearest text above it or below it, in the caption's column. Like `PDFClipLocator` this is a pure function of
/// rectangles (fractions of the crop box, origin at the bottom left), so which layouts give a clip is tested on the
/// host. It gives a region only when the band is clear; with any doubt it gives none and the page stays as it is:
/// - text bounds the band on only one side (a caption with no text above or below it cannot say where the figure
///   starts);
/// - the band is under `PDFClipLocator.minimumWidth` or `minimumHeight` (about 40 pt), or over
///   `PDFClipLocator.maximumArea` of the page;
/// - a band qualifies on both sides (text above and below at similar distance), or its far end is another caption
///   (two captions sharing one gap), because there is no telling which caption owns it;
/// - the caption already has figure text of its own next to it, which `PDFClipLocator` clips.
///
/// The region is the band itself, kept clear of the text that bounds it. It does not include the caption: the row
/// keeps the caption's words.
public enum PDFFigureCaptionLocator {
    /// A caption block: all the lines of one "Figure N" caption, as one rectangle.
    public struct Caption: Equatable, Sendable {
        public var id: String
        public var bounds: PDFNormalizedRect

        public init(id: String, bounds: PDFNormalizedRect) {
            self.id = id
            self.bounds = bounds
        }
    }

    /// The clip region found for one caption.
    public struct Region: Equatable, Sendable {
        public var captionId: String
        public var bounds: PDFNormalizedRect

        public init(captionId: String, bounds: PDFNormalizedRect) {
            self.captionId = captionId
            self.bounds = bounds
        }
    }

    /// A caption at least this wide (a fraction of the page) is full width: its figure spans the text area, not a column.
    static let fullWidthCaption = 0.6
    /// A block counts as beside the figure's column when it overlaps the column by at least this share of the smaller
    /// of the two widths.
    static let columnOverlap = 0.3
    /// How far a band is kept off the text that bounds it, so no sliver of a line is cut in.
    static let edgeInset = 0.004
    /// Rectangles that touch or sit within this vertical distance count as vertically adjacent.
    static let touching = 0.002
    /// Figure text this close to a caption is the caption's own figure (it already has a clip).
    static let ownFigureDistance = 0.04

    /// The text area of a document: the top and bottom the body text reaches on a typical page (#4587).
    public struct TextArea: Equatable, Sendable {
        public var top: Double
        public var bottom: Double

        public init(top: Double, bottom: Double) {
            self.top = top
            self.bottom = bottom
        }
    }

    /// A page needs this many bounded lines to say where the text area is.
    static let minimumLinesForTextArea = 5
    /// A document needs this many such pages to have a text area at all.
    static let minimumPagesForTextArea = 3

    /// Where the body text of this document starts and ends on its pages, from the lines of each page (running heads
    /// and page numbers left out by the caller, caption lines kept). A figure at the very top or bottom of a page has
    /// no text beside it to measure from, so the locator measures from this instead.
    ///
    /// `top` is the 75th percentile of the pages' tops and `bottom` the 25th percentile of their bottoms, nearest rank
    /// (sort ascending, take index `ceil(p * N) - 1`): a median would be pulled in by pages that are mostly figures, and
    /// a maximum would be moved by one stray line. Pages with fewer than `minimumLinesForTextArea` lines are skipped,
    /// and with fewer than `minimumPagesForTextArea` pages left there is no text area.
    public static func textArea(pages: [[PDFNormalizedRect]]) -> TextArea? {
        var tops: [Double] = []
        var bottoms: [Double] = []
        for lines in pages {
            let usable = lines.filter(PDFClipLocator.isUsable)
            guard usable.count >= minimumLinesForTextArea,
                  let top = usable.map({ $0.y + $0.height }).max(), let bottom = usable.map(\.y).min() else { continue }
            tops.append(top)
            bottoms.append(bottom)
        }
        guard tops.count >= minimumPagesForTextArea else { return nil }
        func nearestRank(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[max(0, min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
        }
        return TextArea(top: nearestRank(tops, 0.75), bottom: nearestRank(bottoms, 0.25))
    }

    /// The regions for one page, in the order of `captions`; a caption that gives no clear region has none.
    /// - Parameters:
    ///   - captions: every "Figure N" caption on the page.
    ///   - textBlocks: every other line of text on the page that can bound a figure: body, headings, footnotes, tables.
    ///     Running heads, page numbers and text inside figures are left out by the caller, so a figure under the running
    ///     head is not bounded by it.
    ///   - figureRegions: the regions `PDFClipLocator` already made for figure text on this page. A band that meets one
    ///     gives no region, so one figure never shows twice.
    ///   - furniture: the running heads and page numbers of this page. They never bound a band, but a band is kept
    ///     clear of them.
    ///   - textArea: where the document's text starts and ends on a page. With it, a caption with nothing above (or
    ///     below) it in its column measures its band to the text area's top (or bottom). Without it such a caption has
    ///     no band on that side.
    public static func regions(
        captions: [Caption], textBlocks: [PDFNormalizedRect], figureRegions: [PDFNormalizedRect] = [],
        furniture: [PDFNormalizedRect] = [], textArea: TextArea? = nil
    ) -> [Region] {
        let captions = captions.filter { PDFClipLocator.isUsable($0.bounds) }
        let text = textBlocks.filter(PDFClipLocator.isUsable)
        let figures = figureRegions.filter(PDFClipLocator.isUsable)
        let furniture = furniture.filter(PDFClipLocator.isUsable)
        let everything = text + captions.map(\.bounds)
        var result: [Region] = []
        for caption in captions {
            guard !hasOwnFigureText(caption.bounds, figures: figures),
                  let region = region(
                    for: caption, text: text, others: captions.filter { $0.id != caption.id }, everything: everything,
                    figures: figures, furniture: furniture, textArea: textArea)
            else { continue }
            result.append(Region(captionId: caption.id, bounds: region))
        }
        return result
    }

    private struct Candidate {
        var bounds: PDFNormalizedRect
        var farEndIsCaption: Bool
    }

    private static func region(
        for caption: Caption, text: [PDFNormalizedRect], others: [Caption], everything: [PDFNormalizedRect],
        figures: [PDFNormalizedRect], furniture: [PDFNormalizedRect], textArea: TextArea?
    ) -> PDFNormalizedRect? {
        let box = caption.bounds
        let (left, right) = span(of: box, text: text, everything: everything)
        guard right - left >= PDFClipLocator.minimumWidth else { return nil }

        struct Obstacle { var bounds: PDFNormalizedRect; var isCaption: Bool }
        let obstacles = text.map { Obstacle(bounds: $0, isCaption: false) }
            + others.map { Obstacle(bounds: $0.bounds, isCaption: true) }
        let inColumn = obstacles.filter { overlapsColumn($0.bounds, left: left, right: right) }

        func clipped(bottom: Double, top: Double) -> PDFNormalizedRect? {
            var bottom = bottom, top = top
            // Running heads and page numbers never bound a band, but the band stops short of them: a head is in the
            // top half of the page and a page number in the bottom half.
            for rect in furniture where min(rect.x + rect.width, right) - max(rect.x, left) > 0 {
                guard bottom < rect.y + rect.height, rect.y < top else { continue }
                if rect.y + rect.height / 2 >= 0.5 { top = min(top, rect.y - edgeInset) } else { bottom = max(bottom, rect.y + rect.height + edgeInset) }
            }
            return band(left: left, right: right, bottom: bottom, top: top)
        }

        var candidates: [Candidate] = []
        let above = inColumn.filter { $0.bounds.y >= box.y + box.height - touching }
        let aboveBottom = box.y + box.height + edgeInset
        if let far = above.min(by: { $0.bounds.y < $1.bounds.y }) {
            if let band = clipped(bottom: aboveBottom, top: far.bounds.y - edgeInset) {
                candidates.append(Candidate(bounds: band, farEndIsCaption: far.isCaption))
            }
        } else if let textArea, let band = clipped(bottom: aboveBottom, top: textArea.top) {
            candidates.append(Candidate(bounds: band, farEndIsCaption: false))
        }
        let below = inColumn.filter { $0.bounds.y + $0.bounds.height <= box.y + touching }
        let belowTop = box.y - edgeInset
        if let far = below.max(by: { $0.bounds.y + $0.bounds.height < $1.bounds.y + $1.bounds.height }) {
            if let band = clipped(bottom: far.bounds.y + far.bounds.height + edgeInset, top: belowTop) {
                candidates.append(Candidate(bounds: band, farEndIsCaption: far.isCaption))
            }
        } else if let textArea, let band = clipped(bottom: textArea.bottom, top: belowTop) {
            candidates.append(Candidate(bounds: band, farEndIsCaption: false))
        }
        // The box must be clear of every piece of text, whatever the column or side tests above decided: a line that
        // straddles the caption's edge or only partly overlaps the column is no neighbour to measure from, but it
        // must never end up inside a clip. A band with any text in it is not trusted, and neither is its caption.
        // Running heads and page numbers count as text here, and a band that meets a figure that already has a clip
        // (made from its printed text) is that figure's, not this caption's.
        let clearOf = obstacles.map(\.bounds) + furniture
        guard !candidates.contains(where: { band in clearOf.contains { intersects($0, band.bounds) } }) else { return nil }
        guard !candidates.contains(where: { band in figures.contains { intersects($0, band.bounds) } }) else { return nil }
        guard candidates.count == 1, let only = candidates.first, !only.farEndIsCaption else { return nil }
        return only.bounds
    }

    /// True when the rectangles share any area (touching edges do not).
    private static func intersects(_ a: PDFNormalizedRect, _ b: PDFNormalizedRect) -> Bool {
        min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > 1e-9
            && min(a.y + a.height, b.y + b.height) - max(a.y, b.y) > 1e-9
    }

    /// The horizontal extent of the caption's figure: the whole text area for a full-width caption, else the caption's
    /// own width widened to the column's text. A short centred caption under a wide figure then still spans the figure's
    /// column. Only blocks narrower than a full-width caption widen it (a title, an abstract or a full-width caption
    /// never does), and only when they overlap the caption's column.
    private static func span(of box: PDFNormalizedRect, text: [PDFNormalizedRect], everything: [PDFNormalizedRect]) -> (Double, Double) {
        if box.width >= fullWidthCaption {
            guard let minX = everything.map(\.x).min(), let maxX = everything.map({ $0.x + $0.width }).max()
            else { return (max(0, box.x), min(1, box.x + box.width)) }
            return (max(0, min(minX, box.x)), min(1, max(maxX, box.x + box.width)))
        }
        var left = box.x, right = box.x + box.width
        for block in text where block.width < fullWidthCaption && overlapsColumn(block, left: box.x, right: box.x + box.width) {
            left = min(left, block.x)
            right = max(right, block.x + block.width)
        }
        return (max(0, left), min(1, right))
    }

    private static func overlapsColumn(_ rect: PDFNormalizedRect, left: Double, right: Double) -> Bool {
        let overlap = min(rect.x + rect.width, right) - max(rect.x, left)
        return overlap > 0 && overlap >= columnOverlap * min(rect.width, right - left)
    }

    /// The band as a region, or nil when it is too small or too much of the page to be a figure.
    private static func band(left: Double, right: Double, bottom: Double, top: Double) -> PDFNormalizedRect? {
        let bottom = max(0, bottom), top = min(1, top)
        let width = right - left, height = top - bottom
        guard width >= PDFClipLocator.minimumWidth, height >= PDFClipLocator.minimumHeight,
              width * height <= PDFClipLocator.maximumArea else { return nil }
        return PDFNormalizedRect(x: left, y: bottom, width: width, height: height)
    }

    /// Figure text that sits against the caption in the caption's own column is this figure's printed text.
    private static func hasOwnFigureText(_ caption: PDFNormalizedRect, figures: [PDFNormalizedRect]) -> Bool {
        figures.contains { figure in
            let horizontal = min(figure.x + figure.width, caption.x + caption.width) - max(figure.x, caption.x)
            let vertical = max(figure.y, caption.y) - min(figure.y + figure.height, caption.y + caption.height)
            return horizontal > 0 && vertical <= ownFigureDistance
        }
    }
}
