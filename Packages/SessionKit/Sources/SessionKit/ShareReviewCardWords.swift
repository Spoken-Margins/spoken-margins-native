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

    // MARK: The Share Margins list (#4647)

    public static let yourWordsChanged = "Your words, with changes"
    public static let showWhatChanged = "Show what changed"
    public static let editWords = "Edit words"
    public static let done = "Done"
    public static let moreForThisMargin = "More for this Margin"
    /// Under "Listen without ums" while that voice is being made.
    public static let voicePending = "Getting your voice without ums ready."
    /// Under the change summary when pauses are shortened and the friend gets "Without ums".
    public static let pauseNote = "Pauses are shortened in your voice only. Listen to hear it as your friend will."
    /// Under "Preview what your friend gets" while a voice the share needs is being made.
    public static let previewWaiting = "Ready when your voices without ums are."
    public static let backToYourMargins = "Back to your Margins"
    public static let staleSelection = "Your selection changed. Check it and share again."

    /// A card header for VoiceOver: "Margin 2 of 5, starred, without ums". The position counts the cards shown;
    /// "starred" is said only when starred; the version only for an included Margin.
    public static func headerLabel(position: Int, shown: Int, isStarred: Bool, version: String?) -> String {
        var parts = ["Margin \(position) of \(shown)"]
        if isStarred { parts.append("starred") }
        if let version { parts.append(version.lowercased()) }
        return parts.joined(separator: ", ")
    }

    public static func headerValue(isIncluded: Bool) -> String {
        isIncluded ? "Included" : "Not included"
    }

    public static let headerHint = "Double-tap to include or leave out."
    /// The switch's label on every card; it never changes.
    public static let included = "Included"

    /// The count in the pinned bar, the same value as the top card's.
    public static func barCount(included: Int, total: Int) -> String {
        "\(included) of \(total) selected"
    }

    // MARK: A share waiting for voices (#4647)

    public static func waiting(count: Int) -> String {
        count == 1 ? "Getting 1 Margin ready…" : "Getting \(count) Margins ready…"
    }

    public static let stopSharing = "Stop sharing"

    public static func failureTitle(count: Int) -> String {
        count == 1 ? "Couldn't remove the ums from 1 Margin" : "Couldn't remove the ums from \(count) Margins"
    }

    public static func failureMessage(count: Int) -> String {
        count == 1
            ? "It can go without that change. Its card says how. Your recording on this iPhone stays as it is."
            : "They can go without that change. Their cards say how. Your recording on this iPhone stays as it is."
    }

    public static let shareAnyway = "Share anyway"
    public static let notNow = "Not now"
}
