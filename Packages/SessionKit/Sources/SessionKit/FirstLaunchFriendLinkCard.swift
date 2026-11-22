import Foundation

/// The card at the top of the first-launch "Follow a few favourites" sheet for a friend who installed from a link
/// (#3782). It says what the friend can do, and judges what the system Paste button pastes.
///
/// The words are the Design's (#3782, D3). The card has no state of its own: whether it shows follows from the
/// drawer's opening and from what the Library holds, and a paste is judged by one function, so the rules are
/// testable on the host. A link in the paste goes through ``PastedShareLink``, the same rule every other paste route
/// uses, so a link inside the whole message a friend sent is found, and one cut short is still a share link (opening it
/// says it is cut off, #3801).
public enum FirstLaunchFriendLinkCard {
    public static let headline = "Got a link from a friend?"
    public static let line = "Tap it again in your message. It opens here now. Or copy it and paste it here."
    /// Under the Paste button when what was pasted holds no share link, including the join page and an article.
    public static let notAFriendLinkLine = "This isn't a link to a friend's Margins. Copy the whole link from the message and try again."

    /// The card shows only on the first-launch sheet, and only while the Library holds no friend's packet. It never shows
    /// on a later visit to the drawer, and it stays hidden once any packet has been imported, after a relaunch too.
    public static func isShown(isFirstRunOpening: Bool, libraryHoldsFriendPacket: Bool) -> Bool {
        isFirstRunOpening && !libraryHoldsFriendPacket
    }

    /// A friend's packet is in the Library: any layer that is not deleted, enabled or not, whoever sent it.
    public static func libraryHoldsFriendPacket(layers: [ImportedCommentaryLayer]) -> Bool {
        layers.contains { $0.deletedAt == nil }
    }

    public enum PasteResult: Equatable, Sendable {
        /// A link to a friend's Margins, on `https`, to open as a tapped link is opened.
        case open(URL)
        /// Nothing is opened or imported; the line goes under the Paste button.
        case notAFriendLink(String)
    }

    public static func pasteResult(for content: String?) -> PasteResult {
        if let link = PastedShareLink.first(in: content) { return .open(link) }
        return .notAFriendLink(notAFriendLinkLine)
    }
}
