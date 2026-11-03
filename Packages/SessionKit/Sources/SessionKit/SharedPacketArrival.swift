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
    /// their copy already has.
    public static func route(isListeningMap: Bool, requiresRecipientItem: Bool) -> Route {
        isListeningMap || requiresRecipientItem ? .review : .openItem
    }

    /// Shown while the file's item is placed (a podcast episode may need fetching first).
    public static func openingMessage(senderName: String?) -> String {
        "Opening \(possessive(senderName)) Margins…"
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

    static func name(_ senderName: String?) -> String? {
        guard let trimmed = senderName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func possessive(_ senderName: String?) -> String {
        name(senderName).map { "\($0)'s" } ?? "your friend's"
    }
}
