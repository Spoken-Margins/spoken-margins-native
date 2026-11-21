import Foundation

/// The pixel arithmetic of cutting a PDF table or figure out of its page (#3895). The app draws the page and the
/// picture; what to cut and how big to make it is here, so it is tested on the host and the drawing code has no
/// arithmetic of its own to get wrong (a flipped or shifted cut is the likely failure).
public enum PDFClipGeometry {
    /// The longest side of a saved clip, in pixels: sharp when zoomed on a phone, and a JPEG of a few hundred KB.
    public static let maximumClipPixels = 1_400.0
    /// A page is drawn at up to twice its size in points, and never past this many pixels on its longest side.
    public static let maximumPageScale = 2.0
    public static let maximumPagePixels = 2_000.0

    /// How many pixels a page `width` by `height` points wide is drawn at, per point.
    public static func pageScale(width: Double, height: Double) -> Double {
        let longest = max(width, height)
        guard longest.isFinite, longest > 0 else { return 1 }
        return min(maximumPageScale, maximumPagePixels / longest)
    }

    /// Where to cut in a page picture, and how big the clip comes out.
    public struct Crop: Equatable, Sendable {
        /// In pixels of the page picture, with the origin at its top left.
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        /// The clip's own size: the cut, scaled down only when its longest side is past `maximumClipPixels`.
        public var outputWidth: Int
        public var outputHeight: Int
    }

    /// The cut for a region of a page picture `pageWidth` by `pageHeight` pixels. The region is fractions of the page
    /// with the origin at the bottom left, as everywhere else; the picture's origin is at the top left, so the
    /// vertical position flips. The cut takes whole pixels outward, so no edge of the region is lost. Nil when the
    /// picture or the region has no area.
    public static func crop(of region: PDFNormalizedRect, pageWidth: Int, pageHeight: Int) -> Crop? {
        guard pageWidth > 0, pageHeight > 0,
              [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite) else { return nil }
        let width = Double(pageWidth), height = Double(pageHeight)
        let left = max(0, (region.x * width).rounded(.down))
        let right = min(width, ((region.x + region.width) * width).rounded(.up))
        let top = max(0, ((1 - (region.y + region.height)) * height).rounded(.down))
        let bottom = min(height, ((1 - region.y) * height).rounded(.up))
        guard right > left, bottom > top else { return nil }
        let cutWidth = right - left, cutHeight = bottom - top
        let factor = min(1, maximumClipPixels / max(cutWidth, cutHeight))
        return Crop(
            x: Int(left), y: Int(top), width: Int(cutWidth), height: Int(cutHeight),
            outputWidth: max(1, Int((cutWidth * factor).rounded())),
            outputHeight: max(1, Int((cutHeight * factor).rounded()))
        )
    }
}
