#if canImport(ImageIO)
import Foundation
import ImageIO

/// Turns a picture from the camera (or any image data) into a photo the store may keep, and makes thumbnails from a
/// kept one (#2708). ImageIO only: no Apple Intelligence, no UIKit, so it runs in a host test on macOS. It does not
/// exist on Linux, where the rules around it (`LiveSessionPhoto`, `LiveSessionPhotoStore`) are tested instead.
///
/// Every call is synchronous and heavy, so callers run it off the main actor (the app's live-session file worker or a
/// detached task), never on it (`scripts/main_thread_reads.py`).
public enum LiveSessionPhotoEncoder {
    public enum EncodeError: Error, Equatable, Sendable {
        /// The data is not an image ImageIO can read (empty, truncated, not a picture).
        case unreadable
        /// No quality or size got it under `LiveSessionPhoto.maxByteCount`.
        case tooLarge
    }

    /// A fitted, encoded photo: JPEG bytes and their size in pixels, ready for `LiveSessionPhotoStore.stage`.
    public struct Encoded: Equatable, Sendable {
        public let data: Data
        public let widthPx: Int
        public let heightPx: Int
        public var fileExtension: String { "jpg" }
    }

    /// JPEG qualities tried in turn; the first result within the byte cap wins. A page of printed text at 2048 px
    /// is well under the cap at the first.
    static let qualities: [Double] = [0.8, 0.65, 0.5, 0.35, 0.2]
    /// How many times the longest side may shrink by a quarter when no quality fits (down to about a third of the
    /// first size). A photo that still doesn't fit is noise, not a picture of a page.
    static let maxShrinkRounds = 4

    /// Fits `imageData` (JPEG, HEIC, PNG…) to `LiveSessionPhoto`'s caps and encodes it as a JPEG.
    ///
    /// - The camera's rotation is applied to the pixels, so the kept file is upright and carries no orientation tag.
    /// - The result carries no metadata at all, so no location or camera details are kept with a picture of a page.
    /// - A picture smaller than the caps is not enlarged.
    public static func encode(_ imageData: Data, maxByteCount: Int = LiveSessionPhoto.maxByteCount) throws -> Encoded {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              let fit = LiveSessionPhoto.fitted(width: rawWidth, height: rawHeight)
        else { throw EncodeError.unreadable }

        var longEdge = max(fit.width, fit.height)
        for _ in 0...maxShrinkRounds {
            guard let image = thumbnail(of: source, maxPixelSize: longEdge) else { throw EncodeError.unreadable }
            for quality in qualities {
                guard let data = jpeg(image, quality: quality) else { throw EncodeError.unreadable }
                if data.count <= maxByteCount {
                    return Encoded(data: data, widthPx: image.width, heightPx: image.height)
                }
            }
            longEdge = max(1, longEdge * 3 / 4)
        }
        throw EncodeError.tooLarge
    }

    /// A small JPEG of a kept photo for a list row, made without decoding the whole picture (ImageIO's thumbnail call).
    /// Nil when the file cannot be read: the row shows a camera glyph instead.
    public static func thumbnail(of fileURL: URL, maxPixelSize: Int = 144, quality: Double = 0.7) -> Data? {
        guard maxPixelSize > 0, let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = thumbnail(of: source, maxPixelSize: maxPixelSize)
        else { return nil }
        return jpeg(image, quality: quality)
    }

    private static func thumbnail(of source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        // No properties other than the quality: nothing from the original (location, device, time) is copied.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
