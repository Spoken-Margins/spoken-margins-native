import Foundation

/// The arithmetic behind writing a Margin's comment into a PDF (#4338, PR 4), with no PDFKit in it so it host-tests on
/// Linux. Every rectangle and point here is in a page's own space, the one `PDFAnnotation.bounds` uses: origin at the
/// bottom left of the unrotated page, y up, with the page's `/Rotate` turning the picture on top of that space.
public enum PDFCommentGeometry {
    /// The side of a page note's icon, and the gap to the page's edge and between two notes.
    public static let noteSize: CGFloat = 24
    public static let noteInset: CGFloat = 18
    public static let noteGap: CGFloat = 6

    /// Where the `slot`th page note of a page goes: a square in the corner a reader sees at the top left, stacked
    /// downwards for more than one, so two notes on a page never sit on each other. The corner is the top left of the
    /// page as drawn, so a page turned with `/Rotate` still shows its notes at the top left.
    ///
    /// - Parameters:
    ///   - pageBounds: the page's bounds in its own space (`PDFPage.bounds(for:)`).
    ///   - rotation: the page's `/Rotate` in degrees clockwise: any multiple of 90, negatives and 360 or more included.
    ///   - slot: 0 for the first note on the page.
    public static func pageNoteBounds(pageBounds: CGRect, rotation: Int, slot: Int) -> CGRect {
        let turns = (((rotation / 90) % 4) + 4) % 4
        let step = noteSize + noteGap
        // A page only holds so many notes down its drawn height; more share the last place rather than leave the page.
        let drawnHeight = turns % 2 == 0 ? pageBounds.height : pageBounds.width
        let lastSlot = max(0, Int(((drawnHeight - 2 * noteInset - noteSize) / step).rounded(.down)))
        let offset = noteInset + CGFloat(min(max(slot, 0), lastSlot)) * step
        let inset = noteInset
        let side = noteSize
        switch turns {
        case 0: // drawn upright: the top left is the page's own top left, and "down" is -y
            return CGRect(x: pageBounds.minX + inset, y: pageBounds.maxY - offset - side, width: side, height: side)
        case 1: // turned 90 clockwise: the page's own bottom left is at the top left, and "down" is +x
            return CGRect(x: pageBounds.minX + offset, y: pageBounds.minY + inset, width: side, height: side)
        case 2: // upside down: the own bottom right is at the top left, and "down" is +y
            return CGRect(x: pageBounds.maxX - inset - side, y: pageBounds.minY + offset, width: side, height: side)
        default: // 270: the own top right is at the top left, and "down" is -x
            return CGRect(x: pageBounds.maxX - offset - side, y: pageBounds.maxY - inset - side, width: side, height: side)
        }
    }

    /// The smallest rectangle holding every line rectangle: the highlight's bounds. Nil for no rectangles.
    public static func union(of lineRects: [CGRect]) -> CGRect? {
        lineRects.reduce(nil) { (result: CGRect?, rect) in result.map { $0.union(rect) } ?? rect }
    }

    /// A highlight's quadrilateral points: four for each line, in the order PDF readers expect (top left, top right,
    /// bottom left, bottom right), each relative to the annotation's own `bounds` origin, which is how PDFKit's
    /// `quadrilateralPoints` take them.
    public static func quadrilateralPoints(lineRects: [CGRect], relativeTo bounds: CGRect) -> [CGPoint] {
        lineRects.flatMap { rect -> [CGPoint] in
            let left = rect.minX - bounds.minX
            let right = rect.maxX - bounds.minX
            let bottom = rect.minY - bounds.minY
            let top = rect.maxY - bounds.minY
            return [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
        }
    }
}
