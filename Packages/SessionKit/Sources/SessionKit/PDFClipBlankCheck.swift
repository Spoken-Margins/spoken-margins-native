import Foundation

/// Whether a crop of a page holds no picture at all (#4587).
///
/// A caption's band is found from the text around it, not from the picture, so a band can come out empty: a figure
/// that floated to the next page, a side caption, a gap the layout left. The renderer cuts the band at a small size in
/// grayscale and asks this before it saves a clip. It finds no images: it only refuses a crop that is one flat, light
/// tone, which is what blank paper is. A flat dark or grey crop is a picture (a black-field micrograph, a filled
/// panel), so it passes.
public enum PDFClipBlankCheck {
    /// How far from the median a pixel may be and still count as the page's tone.
    static let tolerance = 12
    /// The share of pixels that must be the page's tone for a crop to count as flat.
    static let flatShare = 0.998
    /// A flat crop is blank only when its tone is at least this light (of 255): paper, white or cream.
    static let lightestTone = 232

    /// True when at least 99.8% of the values are within 12 of their median (at 64 x 64, at most 8 pixels differ) and
    /// that median is light, and for no values. The bar is set close to all-white on purpose: a sparse line chart with
    /// no labels must still pass. An all-black crop is not blank, which is why the renderer fills white before it draws
    /// the page: an unfilled transparent page reads as black and would otherwise pass for a picture.
    public static func isBlank(luminance: [UInt8]) -> Bool {
        guard !luminance.isEmpty else { return true }
        let median = Int(luminance.sorted()[luminance.count / 2])
        guard median >= lightestTone else { return false }
        let within = luminance.reduce(0) { $0 + (abs(Int($1) - median) <= tolerance ? 1 : 0) }
        return Double(within) >= flatShare * Double(luminance.count)
    }
}
