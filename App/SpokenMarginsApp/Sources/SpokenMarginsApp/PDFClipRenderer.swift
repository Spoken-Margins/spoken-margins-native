import Foundation
import PDFKit
import SessionKit
import UIKit

/// Cuts the pictures of a PDF's tables and figures out of its pages at import (#3895). The PDF is not kept, so this is
/// the only chance. What to cut and how big is `PDFClipGeometry`'s arithmetic; this only draws.
///
/// A page is drawn once (at up to twice its size) for all the clips on it, so a dense page costs one render, and one
/// page picture is held at a time. A clip that can't be drawn is left out and its row stays text.
enum PDFClipRenderer {
    /// JPEG data by float id, for the floats of this PDF's structured document.
    static func clips(for floats: [StructuredDocument.Float], in document: PDFDocument) -> [String: Data] {
        var result: [String: Data] = [:]
        var pageIndex: Int?
        var pageImage: CGImage?
        for float in floats.prefix(PDFClipLocator.maximumFloatsPerDocument) {
            if pageIndex != float.pageIndex {
                pageIndex = float.pageIndex
                pageImage = document.page(at: float.pageIndex).flatMap(pictureOfPage)
            }
            guard let pageImage,
                  let crop = PDFClipGeometry.crop(of: float.bounds, pageWidth: pageImage.width, pageHeight: pageImage.height),
                  let cut = pageImage.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)),
                  let data = jpeg(of: cut, width: crop.outputWidth, height: crop.outputHeight) else { continue }
            result[float.id] = data
        }
        return result
    }

    /// The page's crop box as a picture, the shape the fractions of a region are measured in.
    private static func pictureOfPage(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = PDFClipGeometry.pageScale(width: Double(box.width), height: Double(box.height))
        let size = CGSize(width: max(1, box.width * scale), height: max(1, box.height * scale))
        return page.thumbnail(of: size, for: .cropBox).cgImage
    }

    /// The cut on white, so a page with no background (or a transparent one) is not black in a JPEG.
    private static func jpeg(of image: CGImage, width: Int, height: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return data.isEmpty ? nil : data
    }
}
