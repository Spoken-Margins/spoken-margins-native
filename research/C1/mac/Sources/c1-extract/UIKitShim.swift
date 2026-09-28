import AppKit

// PDFStructuredTextExtractor reads fonts as UIFont and checks `.traitBold`.
// On macOS, PDFKit's attributed strings carry NSFont with the same meaning.
typealias UIFont = NSFont

extension NSFontDescriptor.SymbolicTraits {
    static let traitBold = NSFontDescriptor.SymbolicTraits.bold
}

// The extractor asks UIKit's spell checker whether "agree" + "ment" is a word
// (soft hyphens). On macOS the same question goes to NSSpellChecker.
final class UITextChecker {
    static var availableLanguages: [String] { NSSpellChecker.shared.availableLanguages }

    func rangeOfMisspelledWord(in string: String, range: NSRange, startingAt startingOffset: Int, wrap: Bool, language: String) -> NSRange {
        NSSpellChecker.shared.checkSpelling(of: string, startingAt: startingOffset, language: language, wrap: wrap, inSpellDocumentWithTag: 0, wordCount: nil)
    }
}
