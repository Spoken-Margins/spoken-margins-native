import Foundation

/// How many of a friend's waiting Margins are replies to the listener's own Margins, and how many are new (#3889).
/// The item screen words an arrival from this: a packet of replies is not a first-time friend's packet, so it is not
/// told what a Margin is and says "replies" where a first-time packet says "Margins".
///
/// A Margin counts as a reply to the listener only when its parent is the listener's own Margin
/// (`WaitingMargin.replyToYouParentId`). A reply to another friend's Margin, or one whose parent isn't in this Library,
/// is a new Margin here.
struct FriendReplyMix: Equatable {
    let replies: Int
    let newMargins: Int
    /// How many different Margins of the listener's the replies answer.
    let answeredMargins: Int

    init(_ margins: [ItemListeningChoices.WaitingMargin]) {
        let parents = margins.compactMap(\.replyToYouParentId)
        replies = parents.count
        newMargins = margins.count - parents.count
        answeredMargins = Set(parents).count
    }

    var total: Int { replies + newMargins }
    var hasReplies: Bool { replies > 0 }
    /// Every waiting Margin answers one of the listener's own.
    var isAllReplies: Bool { replies > 0 && newMargins == 0 }

    /// "2 replies to your Margins", "2 replies to your Margin" when both answer one Margin, "1 reply and 1 new Margin".
    /// Only for a mix with replies in it.
    var spokenCount: String {
        let replyWords = "\(replies) repl\(replies == 1 ? "y" : "ies")"
        if isAllReplies { return "\(replyWords) to your Margin\(answeredMargins == 1 ? "" : "s")" }
        return "\(replyWords) and \(newMargins) new Margin\(newMargins == 1 ? "" : "s")"
    }
}
