import Foundation

/// How a friend's `.spokenmargins` file arrives (#3291, slice 2 of #3247): straight onto its item's screen, with no
/// Import sheet in between, unless the listener has a choice to make first.
///
/// The owner's 2026-10-17 call: "A friend's shared link lands in the Library as a card, with no Import step." A file
/// that fails its check never reaches the Library; the coordinator rejects it before any review exists.
public enum SharedPacketArrival {
    public enum Route: Equatable, Sendable {
        /// Import now and open the item's screen.
        case openItem
        /// Show the sheet: the listener picks their own copy of the source, or decides about a Listening Map.
        case review
    }

    /// A file opens straight onto its item unless only the listener can finish it: a source they must supply (an
    /// audiobook or PDF of their own), or a Listening Map, which carries no friend's Margins and can replace the map
    /// their copy already has. A file an earlier launch already showed keeps the sheet too: opening fetches the item,
    /// and on this launch the listener did nothing (the 2026-10-21 rule; the audit on PR #3298).
    public static func route(
        isListeningMap: Bool, requiresRecipientItem: Bool, shownOnAnEarlierLaunch: Bool = false
    ) -> Route {
        isListeningMap || requiresRecipientItem || shownOnAnEarlierLaunch ? .review : .openItem
    }

    /// Whether the sheet is up for a review. It is for a file with a choice to make, or one whose direct open failed
    /// (`opensDirectly` off), and never while a Margin is being recorded or written: the sheet can't be swiped away,
    /// so it would cover the capture, and the listener could only reach Save by answering it first (the audit on
    /// PR #3298). The review waits, and the sheet comes up when that Margin is saved or cancelled.
    public static func showsSheet(opensDirectly: Bool, navigationLocked: Bool) -> Bool {
        !opensDirectly && !navigationLocked
    }

    /// Shown while the file's item is placed (a podcast episode may need fetching first).
    public static func openingMessage(senderName: String?) -> String {
        "Opening \(possessive(senderName)) Margins…"
    }

    /// Said when the file is in the Library but a Margin is being recorded or written, which holds the listener where
    /// they are; the item opens once that Margin is saved or cancelled.
    public static func waitingToOpenMessage(senderName: String?) -> String {
        let owner = name(senderName).map { "\($0)'s" } ?? "Your friend's"
        return "\(owner) Margins are in your Library. They open when you finish this Margin."
    }

    /// Said once the item's screen is open. Nil on a first arrival, where the item screen already says who sent how
    /// many, and when the file held nothing new; "2 new Margins from Cole" when it added to Margins already there.
    public static func announcement(newMarginCount: Int, senderName: String?, itemHadFriendMargins: Bool) -> String? {
        guard newMarginCount > 0, itemHadFriendMargins else { return nil }
        let who = name(senderName) ?? "your friend"
        return "\(newMarginCount) new Margin\(newMarginCount == 1 ? "" : "s") from \(who)"
    }

    /// The honest parts of the old Import sheet, one tap away on the item's screen.
    public static let aboutTitle = "About this file"
    public static let aboutIntegrity = "Unchanged since it was sent. The name on it comes from the sender's app and isn't proven."

    /// The labels the app puts where a file names nobody. They are stand-ins for a missing name, never a name: no screen
    /// on a friend's path may say "From Unsigned sender" or "Shared by Imported collection" (#3247).
    public static let unsignedSenderLabel = "Unsigned sender"
    public static let importedCollectionLabel = "Imported collection"

    /// The label a screen's snapshot carries for a file's sender: the sender's own label, or the stand-in when it is
    /// empty. Every snapshot builder goes through here so `senderName` can tell the stand-in from a name.
    public static func snapshotSenderLabel(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return unsignedSenderLabel }
        return label
    }

    /// The sender's name as a friend should read it: trimmed, or nil when the file names nobody. Empty or blank
    /// labels and the stand-ins above (any case, spacing or accents) are nil, so callers fall back to "a friend" or
    /// "your friend". Use this, never the raw label, wherever a name is shown or read aloud.
    public static func senderName(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let folded = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let standIns = [unsignedSenderLabel, importedCollectionLabel]
        if standIns.contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded }) {
            return nil
        }
        return trimmed
    }

    static func name(_ senderName: String?) -> String? { Self.senderName(senderName) }

    static func possessive(_ senderName: String?) -> String {
        name(senderName).map { "\($0)'s" } ?? "your friend's"
    }
}
