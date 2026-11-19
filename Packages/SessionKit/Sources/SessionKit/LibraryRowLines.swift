import Foundation

/// The words a Library row shows for how far the listener is and whose Margins are on it (#4062).
///
/// Pure and host-tested: the row's view reads these strings and draws them, and no line is worked out per row
/// from the database (everything comes from the one Library read that built the `LibraryItemRow`).
///
/// The progress words are the first part of the detail line:
/// - text in progress: "about 24 min left" (an estimate at the listener's speed, so always "about");
/// - a podcast or other recorded audio in progress, whose length and saved place are known: "24 min left" (the file's
///   own length, so no "about");
/// - in progress with no length to count against: "43%";
/// - not started: "about 41 min" for text, "41 min" for audio of known length, nothing otherwise;
/// - finished: "Completed", or "Completed · Exported".
public struct LibraryRowLines: Equatable, Sendable {
    /// First part of the detail line; nil when there is nothing to say.
    public let progress: String?
    /// What VoiceOver says for `progress`: "43 percent listened, about 24 minutes left", "Completed".
    public let progressSpoken: String?
    /// The fraction listened for the ring around the play button, 0...1: only for an item in progress, never for one
    /// not started or finished. The words say the same, so the ring never carries meaning alone.
    public let ringFraction: Double?
    /// The listener's own Margins, as the Margins line shows them: "2 yours" beside a friend's part, "2 Margins" alone.
    public let ownMargins: String?
    /// The friend's part: the row's `SharedMarginTally.senderLine` ("2 new Margins from Cole"), or the words a caller passes in.
    public let friendMargins: String?
    /// True when any of the friend's Margins is unheard, so the line shows its New badge. Never true without a count.
    public let friendMarginsAreNew: Bool
    /// What VoiceOver says for the whole Margins line: "2 of your Margins. 3 Margins from Cole, 1 new to you".
    public let marginsSpoken: String?

    /// Whether the row has a Margins line at all.
    public var hasMarginsLine: Bool { ownMargins != nil || friendMargins != nil }

    /// - Parameters:
    ///   - playbackSpeed: the listener's speed, for a text item's estimate.
    ///   - isExported: a finished spoken note saved to the export folder says so.
    ///   - friendLine: the friend's part; defaults to the tally's sender line.
    ///   - friendSpokenLine: its VoiceOver words; defaults to the tally's own when the line is the tally's, else to the line itself.
    public init(
        row: LibraryItemRow,
        playbackSpeed: Double = 1,
        isExported: Bool = false,
        friendLine: String? = nil,
        friendSpokenLine: String? = nil
    ) {
        let words = Self.progressWords(row: row, playbackSpeed: playbackSpeed, isExported: isExported)
        progress = words?.visible
        progressSpoken = words?.spoken
        ringFraction = Self.inProgress(row) ? Double(min(max(row.continuationProgressPercent ?? 0, 0), 100)) / 100 : nil

        let friend = friendLine ?? row.sharedMargins.senderLine
        // Words a caller passes are spoken as passed unless it says otherwise: the tally's own spoken words describe its own line.
        let friendSpoken = friendSpokenLine ?? (friendLine == nil ? row.sharedMargins.senderAccessibilityLine : friendLine)
        let ownCount = max(0, row.marginCount)
        friendMargins = friend
        friendMarginsAreNew = friend != nil && row.sharedMargins.new > 0
        if ownCount > 0 {
            ownMargins = friend == nil ? LibraryRowWording.marginCountLine(ownCount) : "\(ownCount) yours"
        } else {
            ownMargins = nil
        }
        var spoken: [String] = []
        if ownCount > 0 { spoken.append(ownCount == 1 ? "1 Margin of yours" : "\(ownCount) of your Margins") }
        if let friend { spoken.append(friendSpoken ?? friend) }
        marginsSpoken = spoken.isEmpty ? nil : spoken.joined(separator: ". ")
    }

    // MARK: Progress

    /// "In progress" is the Library's own filter rule: some listening, and not finished.
    static func inProgress(_ row: LibraryItemRow) -> Bool {
        !row.isCompleted && (row.continuationProgressPercent ?? 0) > 0
    }

    private static func progressWords(row: LibraryItemRow, playbackSpeed: Double, isExported: Bool) -> (visible: String, spoken: String)? {
        if row.isCompleted {
            return isExported ? ("Completed · Exported", "Completed, exported") : ("Completed", "Completed")
        }
        if inProgress(row) {
            let percent = min(max(row.continuationProgressPercent ?? 0, 0), 100)
            let listened = "\(percent) percent listened"
            if let left = timeLeft(row: row, percent: percent, playbackSpeed: playbackSpeed) {
                return (left.visible, "\(listened), \(left.spoken)")
            }
            return ("\(percent)%", listened)
        }
        return length(row: row, playbackSpeed: playbackSpeed)
    }

    /// Text: characters left over the rate the Library's total uses. Audio: the file's length minus the saved place.
    private static func timeLeft(row: LibraryItemRow, percent: Int, playbackSpeed: Double) -> (visible: String, spoken: String)? {
        if let characters = row.textCharacterCount {
            guard let estimate = ListeningTimeEstimator.estimate(
                totalCharacters: characters,
                charactersHeard: Int((Double(characters) * Double(percent) / 100).rounded(.down)),
                playbackSpeed: playbackSpeed) else { return nil }
            return (estimate.remainingText, estimate.remainingSpokenText)
        }
        guard let duration = row.mediaDurationMs, let place = row.continuationMediaTimeMs else { return nil }
        let seconds = Double(max(0, duration - max(0, place))) / 1000
        guard seconds >= 60 else { return ("under 1 min left", "less than a minute left") }
        return ("\(ListeningTimeEstimate.shortDuration(seconds)) left", "\(ItemLengthWords.spokenDuration(seconds)) left")
    }

    /// Not started: "about 41 min" for text at the listener's speed, "41 min" for audio of known length.
    private static func length(row: LibraryItemRow, playbackSpeed: Double) -> (visible: String, spoken: String)? {
        ItemLengthWords.total(textCharacterCount: row.textCharacterCount, mediaDurationMs: row.mediaDurationMs, playbackSpeed: playbackSpeed)
    }
}
