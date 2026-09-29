import Foundation

/// Predicts, before playback, whether an imported PDF will sound bad for
/// reasons of its *content*: no text layer to read, or so much math that it
/// comes out as a stream of letters. It is cheap: one pass over the
/// extracted text plus the page count, with no rendering or Vision.
///
/// The rule and its thresholds come from stream C1 M2 (#191), fitted on the
/// 66-PDF corpus in `research/C1/` against the costs a PDF carries whatever
/// the extractor does. Leave-one-out it catches 11 of the 13 hardest papers
/// with 3 false alarms among 53 easy ones. Reference lists, tables and other
/// clutter the extractor leaves in are deliberately not signals here: those
/// are extraction bugs to fix (C1 M3), not reasons to warn the listener.
///
/// `research/C1/tools/precheck.py` is the reference implementation. The two
/// must agree token for token (`PDFListeningPrecheckTests` pins the cases);
/// change both, and refit on the corpus, if either changes.
public struct PDFListeningPrecheck: Equatable, Sendable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// Fewer than `maximumWordsPerPageWithoutTextLayer` words per page:
        /// a scan or image-only PDF. Without OCR the listener hears nothing.
        case noTextLayer = "no_text_layer"
        /// Single-letter words make up at least `mathHeavySingleLetterShare`
        /// of the text: variables and symbols read one letter at a time.
        case mathHeavy = "math_heavy"
    }

    /// Bump when the rule, a threshold or the tokenization changes, so a
    /// stored verdict can be told apart from one the current rule would give.
    public static let ruleVersion = 1
    public static let maximumWordsPerPageWithoutTextLayer = 20.0
    public static let mathHeavySingleLetterShare = 0.0655

    public var reasons: [Reason]
    /// Words per page, rounded to one decimal place as the reference rounds it.
    public var wordsPerPage: Double
    /// Share of words that are a single letter other than "a", "A" and "I",
    /// rounded to four decimal places as the reference rounds it.
    public var singleLetterShare: Double

    public var isHard: Bool { !reasons.isEmpty }

    public init(reasons: [Reason], wordsPerPage: Double, singleLetterShare: Double) {
        self.reasons = reasons
        self.wordsPerPage = wordsPerPage
        self.singleLetterShare = singleLetterShare
    }

    /// - Parameters:
    ///   - extractedText: the text the app stored for the PDF (`Item.text`),
    ///     or nil when extraction found no text at all.
    ///   - pageCount: the PDF's page count.
    public static func evaluate(extractedText: String?, pageCount: Int) -> PDFListeningPrecheck {
        var words = 0
        var singleLetters = 0
        var tokenLength = 0
        var tokenIsSingleLetter = false

        func endToken() {
            guard tokenLength > 0 else { return }
            words += 1
            if tokenLength == 1 && tokenIsSingleLetter {
                singleLetters += 1
            }
            tokenLength = 0
        }

        // Python's `\w+` on str: a token is a run of letters, numbers and
        // underscores, counted in Unicode scalars (so a combining accent
        // ends a token, as it does in the reference).
        for scalar in (extractedText ?? "").unicodeScalars {
            if isWordScalar(scalar) {
                if tokenLength == 0 {
                    tokenIsSingleLetter = isLetter(scalar) && !ordinarySingleLetterWords.contains(scalar)
                }
                tokenLength += 1
            } else {
                endToken()
            }
        }
        endToken()

        let wordsPerPage = rounded(Double(words) / Double(max(1, pageCount)), places: 1)
        let singleLetterShare = words == 0 ? 0 : rounded(Double(singleLetters) / Double(words), places: 4)
        var reasons: [Reason] = []
        if wordsPerPage <= maximumWordsPerPageWithoutTextLayer {
            reasons.append(.noTextLayer)
        }
        if singleLetterShare >= mathHeavySingleLetterShare {
            reasons.append(.mathHeavy)
        }
        return PDFListeningPrecheck(reasons: reasons, wordsPerPage: wordsPerPage, singleLetterShare: singleLetterShare)
    }

    /// English one-letter words, not variables.
    private static let ordinarySingleLetterWords: Set<Unicode.Scalar> = ["a", "A", "I"]

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || isLetter(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded(.toNearestOrEven) / scale
    }
}
