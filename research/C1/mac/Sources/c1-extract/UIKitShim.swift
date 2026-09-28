import AppKit

// PDFStructuredTextExtractor reads fonts as UIFont and checks `.traitBold`.
// On macOS, PDFKit's attributed strings carry NSFont with the same meaning.
typealias UIFont = NSFont

extension NSFontDescriptor.SymbolicTraits {
    static let traitBold = NSFontDescriptor.SymbolicTraits.bold
}
