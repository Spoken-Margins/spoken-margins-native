import Foundation

/// When a Margin's row says "Go to this moment" instead of "Play this moment", and the words it uses (#4934).
///
/// A friend's Margin that is never read aloud (`!SharedMarginAudio.canOffer`: the sender or the listener turned reading
/// off, no voice on this phone can read it, or it has no readable words) is still somewhere to go. The row's button
/// moves the source to the Margin's place and plays on, with nothing spoken, so it must not look like Play. The screens
/// only ask this type, so the Margins tab, the Now tab's Nearby Margins, the Library and the details sheet cannot drift apart.
public enum SilentMarginWords {
    /// The details sheet's bottom button and the Library's context-menu entry: the words your own Margin's details use.
    public static let goToTitle = "Go to this moment in the source"
    /// The row button's VoiceOver label, before ": <the Margin's words>".
    public static let goToLabel = "Go to this moment"
    /// The row's detail line ends with this for a friend's Margin that is not read aloud.
    public static let notReadAloudSuffix = " · Not read aloud"

    /// A friend's Margin whose row button goes to it with no voice: never spoken, and with a place the listener can go to.
    public static func friendGoesTo(_ margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> Bool {
        !SharedMarginAudio.canOffer(margin) && SharedMarginListPlay.canGo(margin, in: layer)
    }

    /// The listener's own written Margin with a place. Its tap path is unchanged (it moves the source to the place); only its
    /// button's words were wrong, because "Plays the source lead-in and this Margin" is not what happens for a written one.
    public static func ownWrittenGoesTo(_ margin: Interjection) -> Bool {
        margin.status == "active" && margin.captureKind == .written && margin.targetType == .item
            && MarginPlacePresentation.offersGoToMoment(margin)
    }

    /// The row's detail line with the "not read aloud" ending when its button goes to the Margin.
    public static func detail(_ line: String, goesTo: Bool) -> String {
        goesTo ? line + notReadAloudSuffix : line
    }

    /// The row button's VoiceOver hint: where it goes and that nothing is read ("the episode", "the article", "the PDF").
    public static func hint(noun: SourceNoun) -> String {
        "Moves the \(noun.inSentence) here and plays on. Nothing is read aloud."
    }
}
