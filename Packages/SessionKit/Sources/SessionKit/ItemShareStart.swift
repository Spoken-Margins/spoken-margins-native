import Foundation

/// What the item screen's Share does (#4229): open the friend sheet, or say why there is nothing to share. The item
/// screen opens the same Share Margins sheet the player opens, started on this item, so "can this item be shared?" is
/// answered with the sheet's own filter (`ItemShareSessionSelection.isShareable`) and the two can't disagree.
public enum ItemShareStart: Equatable, Sendable {
    case share
    case nothingYet(Explanation)

    public struct Explanation: Equatable, Sendable, Identifiable {
        public let title: String
        public let message: String
        public var id: String { message }
        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    public static let nothingYetTitle = "Nothing to share yet"
    /// The listener's Margins here are all on a summary or an answer, which the sheet can't send.
    public static let onlyResponseMarginsMessage =
        "Margins made during a summary or a reply can't be sent to a friend yet. Add a Margin while you listen to the piece itself, then share it from here."
    /// A friend's Margins are on the item and none of the listener's own.
    public static let onlyFriendMarginsMessage =
        "Share sends your own Margins, not the ones a friend sent you. Add a Margin of your own while you listen, then share it from here."
    public static let noMarginsMessage =
        "Share sends the Margins you make here to a friend who has Spoken Margins. Add a Margin while you listen, then share it from here."

    /// - Parameters:
    ///   - ownMargins: the listener's Margins on this item, in any state.
    ///   - hasFriendMargins: a friend's layer is on this item.
    public static func start(ownMargins: [Interjection], hasFriendMargins: Bool) -> ItemShareStart {
        if ownMargins.contains(where: ItemShareSessionSelection.isShareable) { return .share }
        let message: String
        if ownMargins.contains(where: { $0.status == "active" }) {
            message = onlyResponseMarginsMessage
        } else if hasFriendMargins {
            message = onlyFriendMarginsMessage
        } else {
            message = noMarginsMessage
        }
        return .nothingYet(Explanation(title: nothingYetTitle, message: message))
    }
}
