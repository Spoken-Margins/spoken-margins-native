import Foundation

/// What the item screen does about opened marks when a friend's Margins arrived by link (#5275, Screen C): whether
/// it shows "When you open these Margins, Ana can see that you did.", and which links its start controls signal.
///
/// It looks at the waiting Margins' layers that came by link (`shareLinkId`). A link counts only when its server
/// offered marks (`X-SM-Link-Opened`), the switch is on, it hasn't been signalled, and it isn't one of the
/// listener's own sent links. Layers from hidden senders never reach here: the loaders drop them.
public struct FriendLinkArrival: Equatable, Sendable {
    /// The links the start controls signal, one request each.
    public let linkIDs: [String]
    /// The name the sender line uses, or nil for "From a friend".
    public let senderName: String?

    public var showsNotice: Bool { !linkIDs.isEmpty }

    public init(linkIDs: [String], senderName: String?) {
        self.linkIDs = linkIDs
        self.senderName = senderName
    }

    public static func make(waiting entries: [SharedMarginReview.Entry], signals: [String: FriendLinkSignal],
                            receiptsOn: Bool, ownLinkIDs: Set<String>) -> FriendLinkArrival {
        let name = FriendMarginsIntro.singleName(entries.map(\.waitingMargin))
        guard receiptsOn else { return FriendLinkArrival(linkIDs: [], senderName: name) }
        var ids: Set<String> = []
        for entry in entries {
            guard let id = entry.layer.shareLinkId, let signal = signals[id], signal.offered, !signal.sent,
                  !ownLinkIDs.contains(id) else { continue }
            ids.insert(id)
        }
        return FriendLinkArrival(linkIDs: ids.sorted(), senderName: name)
    }

    /// "When you open these Margins, Ana can see that you did."
    public var noticeText: String {
        "When you open these Margins, \(senderName ?? "your friend") can see that you did."
    }

    /// "Don't tell Ana", or "Don't tell them" with no name.
    public var dontTellTitle: String {
        "Don't tell \(senderName ?? "them")"
    }

    /// What the notice says for the rest of the screen's life after "Don't tell": the app's one switch also stops the
    /// listener's own "Opened".
    public var toldNotText: String {
        "\(senderName ?? "Your friend") won't be told, and you won't see when your own links are opened. Change this in Settings."
    }
}
