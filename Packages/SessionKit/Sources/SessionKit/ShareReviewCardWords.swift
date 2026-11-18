import Foundation

/// The words on the sender's share-review card (#3839): what the friend gets, in the sender's own words. One set, so
/// the card, the listen button and VoiceOver can't drift, and a guard can fail on an engineering phrase coming back.
/// The version names (As recorded, Without ums, Words only) are `ShareCleanupWords`'.
public enum ShareReviewCardWords {
    // MARK: What the friend gets

    public static let friendGets = "Your friend gets"
    public static let captionAsRecorded = "Your friend hears your voice as you recorded it."
    public static let captionWithoutUms = "Your friend hears your voice with filler words and long pauses removed."
    public static let captionWordsOnly = "Your friend gets your words, not your voice."

    // MARK: Listen

    public static let listenAsRecorded = "Listen as recorded"
    public static let listenWithoutUms = "Listen without ums"
    public static let stopListening = "Stop"
    public static let listenError = "Couldn't play this recording."

    // MARK: Your words

    public static let yourWords = "Your words"
    public static let wordsEditorCaption = "Tap a word or a pause to take it out or put it back."
    public static let showAllWords = "Show all your words"
    public static let showLess = "Show less"

    // MARK: Where it lands

    public static let whereItLands = "Where it lands"
    public static let whereItLandsCaption = "These words help your friend's copy find the moment. Most people leave them as they are."
    public static let wordsJustBefore = "Words just before"
    public static let wordsJustAfter = "Words just after"

    // MARK: Private note

    public static let privateNote = "Private note, not sent"

    // MARK: Pinned bar

    /// Past two lines the step in the pinned bar says "More", which opens the full text (AX1 and up).
    public static let more = "More"
    public static let pinnedStepSheetTitle = "Before you share"
}
