import Foundation

/// The words the sender's share review uses for cleanup (#3853): what it removes, what it left alone, and what a
/// failure means. One table, so the switch, the alert, the Choose rows and the Review cards say the same thing, and a
/// listener who hears the label read aloud learns what will change.
///
/// What cleanup does: removes um, uh, er and the like and an isolated "you know", and shortens long pauses. It trims quiet
/// runs in a new audio file; the private recording is untouched. It never touches false starts, repeats or noise.
public enum ShareCleanupWords {
    // MARK: Switch and alert

    public static let switchLabel = "Remove ums and long pauses"

    public static func switchCaption(isOn: Bool) -> String {
        isOn
            ? "On for this share and later ones. Removes filler words like um and uh, and shortens long pauses, in the Margins you pick. Turn it off to put them all back."
            : "Off. Your Margins go as you recorded them. You can still do this for one Margin below."
    }

    public static let alertTitle = "Remove ums and long pauses?"
    public static let alertMessage = "Spoken Margins can remove filler words like um and uh, and shorten long pauses, in the Margins you share. Your recording on this iPhone stays as it is. You can hear and undo every change. To stop this later, turn off Remove ums and long pauses at the top of this screen."
    public static let alertAccept = "Remove them"
    public static let alertDecline = "Not now"

    // MARK: Choose Margins: progress and result

    public static func running(completed: Int, total: Int) -> String {
        "Removing ums and pauses: \(completed) of \(total)"
    }

    /// The line after a bulk run. `completed` counts every Margin the run finished, failures included.
    public static func bulkResult(completed: Int, failed: Int) -> String {
        let changed = max(completed - failed, 0)
        if changed == 0, failed > 0 {
            return failed == 1
                ? "Couldn't remove ums and pauses from this Margin. It goes as it is."
                : "Couldn't remove ums and pauses from any of the \(failed) Margins. They go as they are."
        }
        let done = "Removed ums and pauses from \(changed) \(changed == 1 ? "Margin" : "Margins")"
        guard failed > 0 else { return done }
        let rest = failed == 1 ? "1 couldn't be changed and goes as it is." : "\(failed) couldn't be changed and go as they are."
        return "\(done). \(rest)"
    }

    // MARK: Versions

    public static let asRecorded = "As recorded"
    public static let withoutUms = "Without ums"
    public static let wordsOnly = "Words only"

    // MARK: Review card

    public static let cleanButton = "Remove ums and pauses"
    public static let cleanButtonHint = "Removes filler words like um and uh and shortens long pauses. You can put any of it back."
    public static let cleaning = "Removing ums and pauses…"
    public static let cleaned = "Ums and long pauses removed. Tap a word or pause below to put it back."

    /// What a Review card says about cleanup. A Margin with no word-level timing says nothing: the sender can do nothing
    /// about it, and the old line read as a fault (#3839).
    public enum CardState: Equatable, Sendable {
        case canClean, cleaning, cleaned, cannotClean
    }

    public static func cardLine(_ state: CardState) -> String? {
        switch state {
        case .canClean, .cannotClean: nil // the button, or nothing
        case .cleaning: cleaning
        case .cleaned: cleaned
        }
    }

    /// "3 words removed, 2 pauses shortened". Only the parts that aren't zero; nil when both are.
    public static func changeSummary(wordsRemoved: Int, pausesShortened: Int) -> String? {
        var parts: [String] = []
        if wordsRemoved > 0 { parts.append("\(wordsRemoved) \(wordsRemoved == 1 ? "word" : "words") removed") }
        if pausesShortened > 0 { parts.append("\(pausesShortened) \(pausesShortened == 1 ? "pause" : "pauses") shortened") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Failures

    /// A failure, in words the sender can act on. The technical reason goes to diagnostics, never to the screen.
    public enum Failure: Equatable, Sendable {
        case pauseAnalysisUnavailable
        case voiceNotPrepared
        case recordingMissing
        case previewNotPrepared
        case regenerationFailed

        public var message: String {
            switch self {
            case .pauseAnalysisUnavailable:
                "Couldn't find the long pauses in this one. You can still remove ums and edit the words."
            case .voiceNotPrepared:
                "Couldn't remove the ums from this recording. It can still go as recorded, or as words only."
            case .recordingMissing:
                "This Margin's recording is missing, so only its words can go."
            case .previewNotPrepared:
                "Couldn't play the version without ums. It can still go as recorded, or as words only."
            case .regenerationFailed:
                "Couldn't redo the version without ums after your edit. It can still go as recorded, or as words only."
            }
        }
    }
}
