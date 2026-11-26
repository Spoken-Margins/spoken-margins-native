import Foundation

/// The words a Library row shows for its length and its Margins (#4062, #4698).
///
/// Pure and host-tested: the row's view reads these strings and draws them, and no line is worked out per row
/// from the database (everything comes from the one Library read that built the `LibraryItemRow`).
///
/// The length is the first part of the row's one info line, short on screen and in full words for VoiceOver:
/// - in progress: the time left, "24 min" ("about 24 minutes left" spoken). The ring on the play button shows the
///   fraction, so the screen drops "left"; a text estimate drops "about" on screen and keeps it spoken;
/// - in progress with no length to count against: "43%";
/// - not started, or finished: the whole length, "41 min", or nothing when the length is unknown. A finished row says
///   "Completed" only to VoiceOver; the screen marks it with a check where the list shows finished items on purpose;
/// - a finished spoken note saved to the export folder adds "Exported".
///
/// The Margins are one count for the tag on the row's artwork: every Margin on the item, the listener's own and
/// friends', capped at "99+", and whether any of a friend's are unheard (the unread dot). Heard Margins carry no colour.
public struct LibraryRowLines: Equatable, Sendable {
    /// First part of the info line; nil when there is nothing to say.
    public let progress: String?
    /// What VoiceOver says for `progress`: "43 percent listened, about 24 minutes left", "Completed, 41 minutes".
    public let progressSpoken: String?
    /// The fraction listened for the ring around the play button, 0...1: only for an item in progress, never for one
    /// not started or finished. The spoken words say the same, so the ring never carries meaning alone.
    public let ringFraction: Double?
    /// The count on the artwork's tag: "14", "99+"; nil when the item has no Margins.
    public let marginTag: String?
    /// True when a friend left Margins the listener hasn't heard, so the artwork shows the unread dot. Never true
    /// without a tag.
    public let hasNewMargins: Bool
    /// What VoiceOver says for the tag and the dot: "14 Margins, 3 new from Cole", "2 Margins".
    public let marginsSpoken: String?

    /// The most the tag spells out; above it the tag says "99+".
    public static let tagLimit = 99

    /// - Parameters:
    ///   - playbackSpeed: the listener's speed, for a text item's estimate.
    ///   - isExported: a finished spoken note saved to the export folder says so.
    public init(row: LibraryItemRow, playbackSpeed: Double = 1, isExported: Bool = false) {
        let words = Self.progressWords(row: row, playbackSpeed: playbackSpeed, isExported: isExported)
        progress = words?.visible.isEmpty == false ? words?.visible : nil
        progressSpoken = words?.spoken
        ringFraction = Self.inProgress(row) ? Double(min(max(row.continuationProgressPercent ?? 0, 0), 100)) / 100 : nil

        let shared = row.sharedMargins
        let total = max(0, row.marginCount) + max(0, shared.total)
        marginTag = total == 0 ? nil : (total > Self.tagLimit ? "\(Self.tagLimit)+" : "\(total)")
        hasNewMargins = total > 0 && shared.new > 0
        marginsSpoken = total == 0 ? nil : Self.marginsWords(total: total, shared: shared)
    }

    // MARK: Margins

    /// "14 Margins, 3 new from Cole": the whole count, then who the unheard ones are from. The tally keeps names only
    /// when they account for all its Margins, so one named sender is the sender of the new ones too.
    private static func marginsWords(total: Int, shared: SharedMarginTally) -> String {
        let count = total == 1 ? "1 Margin" : "\(total) Margins"
        guard shared.new > 0 else { return count }
        let from: String
        switch shared.senders.count {
        case 1:
            // A browser friend who typed no name arrives with an empty one (#4675): never "new from " with nothing after it.
            let name = shared.senders[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
            from = name.isEmpty ? "from a friend" : "from \(name)"
        case 0: from = "from a friend"
        default: from = "from friends"
        }
        return "\(count), \(shared.new) new \(from)"
    }

    // MARK: Progress

    /// "In progress" is the Library's own filter rule: some listening, and not finished.
    static func inProgress(_ row: LibraryItemRow) -> Bool {
        !row.isCompleted && (row.continuationProgressPercent ?? 0) > 0
    }

    private static func progressWords(row: LibraryItemRow, playbackSpeed: Double, isExported: Bool) -> (visible: String, spoken: String)? {
        if row.isCompleted {
            let length = length(row: row, playbackSpeed: playbackSpeed)
            let visible = [length?.visible, isExported ? "Exported" : nil].compactMap { $0 }.joined(separator: " · ")
            let spoken = ["Completed", isExported ? "exported" : nil, length?.spoken].compactMap { $0 }.joined(separator: ", ")
            return (visible, spoken)
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
            return (shortTime(estimate.remainingSeconds), estimate.remainingSpokenText)
        }
        guard let duration = row.mediaDurationMs, let place = row.continuationMediaTimeMs else { return nil }
        let seconds = Double(max(0, duration - max(0, place))) / 1000
        guard seconds >= 60 else { return (shortTime(seconds), "less than a minute left") }
        return (shortTime(seconds), "\(ItemLengthWords.spokenDuration(seconds)) left")
    }

    /// The whole length: "41 min" on screen for text and audio alike, "about 41 minutes" spoken for a text estimate.
    private static func length(row: LibraryItemRow, playbackSpeed: Double) -> (visible: String, spoken: String)? {
        guard let words = ItemLengthWords.total(
            textCharacterCount: row.textCharacterCount, mediaDurationMs: row.mediaDurationMs, playbackSpeed: playbackSpeed)
        else { return nil }
        guard let characters = row.textCharacterCount,
              let estimate = ListeningTimeEstimator.estimate(totalCharacters: characters, charactersHeard: 0, playbackSpeed: playbackSpeed)
        else { return words }
        return (shortTime(estimate.totalSeconds), words.spoken)
    }

    /// "24 min", "1 h 8 min", "under 1 min": no "about" and no "left", which the ring and VoiceOver carry.
    static func shortTime(_ seconds: Double) -> String {
        seconds < 60 ? "under 1 min" : ListeningTimeEstimate.shortDuration(seconds)
    }
}
