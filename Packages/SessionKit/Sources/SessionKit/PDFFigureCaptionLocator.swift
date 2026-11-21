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

    /// The regions for one page, in the order of `captions`; a caption that gives no clear region has none.
    /// - Parameters:
    ///   - captions: every "Figure N" caption on the page.
    ///   - textBlocks: every other line of text on the page that can bound a figure: body, headings, footnotes, tables,
    ///     figure text. Running heads and page numbers are left out by the caller, so a figure under the running head
    ///     is not bounded by it.
    ///   - figureRegions: the regions `PDFClipLocator` already made for figure text on this page.
    public static func regions(
        captions: [Caption], textBlocks: [PDFNormalizedRect], figureRegions: [PDFNormalizedRect] = []
    ) -> [Region] {
        let captions = captions.filter { PDFClipLocator.isUsable($0.bounds) }
        let text = textBlocks.filter(PDFClipLocator.isUsable)
        let figures = figureRegions.filter(PDFClipLocator.isUsable)
        let everything = text + captions.map(\.bounds)
        var result: [Region] = []
        for caption in captions {
            guard !hasOwnFigureText(caption.bounds, figures: figures),
                  let region = region(for: caption, text: text, others: captions.filter { $0.id != caption.id }, everything: everything)
            else { continue }
            result.append(Region(captionId: caption.id, bounds: region))
        }
        return result
    }

    private struct Candidate {
        var bounds: PDFNormalizedRect
        var farEndIsCaption: Bool
    }

    private static func region(for caption: Caption, text: [PDFNormalizedRect], others: [Caption], everything: [PDFNormalizedRect]) -> PDFNormalizedRect? {
        let box = caption.bounds
        let (left, right) = span(of: box, everything: everything)
        guard right - left >= PDFClipLocator.minimumWidth else { return nil }

        struct Obstacle { var bounds: PDFNormalizedRect; var isCaption: Bool }
        let obstacles = text.map { Obstacle(bounds: $0, isCaption: false) }
            + others.map { Obstacle(bounds: $0.bounds, isCaption: true) }
        let inColumn = obstacles.filter { overlapsColumn($0.bounds, left: left, right: right) }

        var candidates: [Candidate] = []
        let above = inColumn.filter { $0.bounds.y >= box.y + box.height - touching }
        if let far = above.min(by: { $0.bounds.y < $1.bounds.y }) {
            let bottom = box.y + box.height + edgeInset, top = far.bounds.y - edgeInset
            if let band = band(left: left, right: right, bottom: bottom, top: top) {
                candidates.append(Candidate(bounds: band, farEndIsCaption: far.isCaption))
            }
        }
        let below = inColumn.filter { $0.bounds.y + $0.bounds.height <= box.y + touching }
        if let far = below.max(by: { $0.bounds.y + $0.bounds.height < $1.bounds.y + $1.bounds.height }) {
            let bottom = far.bounds.y + far.bounds.height + edgeInset, top = box.y - edgeInset
            if let band = band(left: left, right: right, bottom: bottom, top: top) {
                candidates.append(Candidate(bounds: band, farEndIsCaption: far.isCaption))
            }
        }
        guard candidates.count == 1, let only = candidates.first, !only.farEndIsCaption else { return nil }
        return only.bounds
    }

    /// The horizontal extent of the caption's figure: the caption's own width for a column caption, the whole text
    /// area for a full-width one.
    private static func span(of box: PDFNormalizedRect, everything: [PDFNormalizedRect]) -> (Double, Double) {
        guard box.width >= fullWidthCaption,
              let minX = everything.map(\.x).min(), let maxX = everything.map({ $0.x + $0.width }).max()
        else { return (max(0, box.x), min(1, box.x + box.width)) }
        return (max(0, min(minX, box.x)), min(1, max(maxX, box.x + box.width)))
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
