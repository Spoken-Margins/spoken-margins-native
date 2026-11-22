import Foundation

/// The one-tap "I got your reply" a sharer can send back through the chat the reply came in (#3902).
///
/// Nothing can see a web reply arrive: the web listener cannot upload and the link server records no fetches, so the
/// sharer confirms with a text they send themselves. This type decides when the app offers that text and what it says.
/// It is display logic only: no packet field, no network call, nothing stored. The offer is worked out from the saved
/// layers and reply links each time it is asked, so it comes back after a relaunch.
public enum ReplyReceipt {
    /// A friend's packet that holds at least one Margin answering one of the listener's own.
    public struct Offer: Equatable, Sendable {
        /// The imported layer (the friend's packet) the replies came in.
        public let layerId: String
        /// The friend's name as the packet labels it; nil for no label. The words come from `buttonTitle(senderLabel:)`,
        /// which also turns a stand-in label such as "Someone" into "your friend".
        public let senderLabel: String?
        /// How many Margins in that packet answer one of the listener's own: at least 1.
        public let replyCount: Int

        public var buttonTitle: String { ReplyReceipt.buttonTitle(senderLabel: senderLabel) }

        public func message(itemTitle: String?) -> String {
            ReplyReceipt.message(itemTitle: itemTitle, replyCount: replyCount)
        }
    }

    /// The offer for one packet, or nil when none of its Margins answers one of the listener's own.
    ///
    /// Only a Margin linked to one of the listener's **own** Margins counts. A reply whose parent is another friend's
    /// Margin, one whose parent has not arrived (`parentMissing`), one naming several parents (`fork`) and a Margin with
    /// no reply link do not: a first share is not an answer waiting on a confirmation. A deleted packet offers nothing.
    public static func offer(
        layer: ImportedCommentaryLayer,
        graph: MarginReplyGraph,
        importedMargins: [ImportedCommentaryInterjection]
    ) -> Offer? {
        guard layer.deletedAt == nil else { return nil }
        let replies = importedMargins.filter { margin in
            guard margin.layerId == layer.id, case .linked(let parent)? = graph.states[.imported(margin.id)],
                  case .local? = parent.parent else { return false }
            return true
        }
        guard !replies.isEmpty else { return nil }
        return Offer(layerId: layer.id, senderLabel: layer.displayLabel, replyCount: replies.count)
    }

    /// The offer from the newest packet that has one, for the item screen's intro. "Newest" is the latest `importedAt`;
    /// among packets imported at the same moment, the later one in `layers`. A newer packet with no reply to the listener
    /// does not hide an older one that has.
    public static func newestOffer(
        layers: [ImportedCommentaryLayer],
        graph: MarginReplyGraph,
        importedMargins: [ImportedCommentaryInterjection]
    ) -> Offer? {
        var newest: (layer: ImportedCommentaryLayer, offer: Offer)?
        for layer in layers {
            guard let offer = offer(layer: layer, graph: graph, importedMargins: importedMargins) else { continue }
            if newest == nil || layer.importedAt >= newest!.layer.importedAt { newest = (layer, offer) }
        }
        return newest?.offer
    }

    /// "Tell Sam you got it", or "Tell your friend you got it" for a sender with no name.
    public static func buttonTitle(senderLabel: String?) -> String {
        "Tell \(MarginReplyWords.senderName(senderLabel) ?? "your friend") you got it"
    }

    /// What the share sheet starts with: "Got your reply on “Episode title” in Spoken Margins." One reply says "reply",
    /// two or more "replies". A title that is blank or only whitespace leaves the title out: "Got your reply in Spoken
    /// Margins." Double quotes inside the title become single ones, so the quotes never nest. The listener can edit the
    /// text in the chat before sending it.
    public static func message(itemTitle: String?, replyCount: Int) -> String {
        let noun = replyCount > 1 ? "replies" : "reply"
        // Invisible format characters (zero-width space, BOM) count as nothing, like whitespace, as in `MarginReplyWords.excerpt`.
        let visible = String(String.UnicodeScalarView((itemTitle ?? "").unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let title = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty else { return "Got your \(noun) in Spoken Margins." }
        return "Got your \(noun) on \u{201C}\(MarginReplyWords.singleQuoted(title))\u{201D} in Spoken Margins."
    }
}
