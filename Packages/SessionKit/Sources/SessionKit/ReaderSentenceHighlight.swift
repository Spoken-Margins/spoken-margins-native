import Foundation

/// How the Source Text reader marks the sentence being read (#3736). The mark is a highlighter fill and a thick
/// underline. The fill alone measured 1.09:1 against the page in light mode, so the underline carries the meaning: it
/// is a shape, not a hue, and its colour is 6:1 and more on the reader's surface. Foundation only, so the audit in
/// `ExperienceColorContrast.swift` and the host tests read the same numbers the view draws.
public enum ReaderSentenceHighlight {
    /// The highlighter fill: the app's ochre, so the audit can see it (system yellow is outside the tokens).
    public static let fill = AppSemanticColorRGB.ochre
    public static let fillAlpha = 0.22
    /// The underline's colour: ochre for marks that are read, not the fill's own value.
    public static let underline = AppSemanticColorRGB.ochreText

    public struct Span: Equatable, Sendable {
        public let range: NSRange
        public let fill: AppDynamicRGB
        public let fillAlpha: Double
        public let underline: AppDynamicRGB
        public let underlineIsThick: Bool
    }

    /// What to mark for `sentence` in a text of `textLength` UTF-16 units. Nil for no sentence, an empty one, or one
    /// that starts at or past the end; a sentence running past the end is cut to the text.
    public static func span(textLength: Int, sentence: NSRange?) -> Span? {
        guard textLength > 0, let sentence, sentence.location != NSNotFound,
              sentence.location >= 0, sentence.length > 0, sentence.location < textLength else { return nil }
        let length = min(sentence.length, textLength - sentence.location)
        return Span(
            range: NSRange(location: sentence.location, length: length),
            fill: fill,
            fillAlpha: fillAlpha,
            underline: underline,
            underlineIsThick: true
        )
    }
}
