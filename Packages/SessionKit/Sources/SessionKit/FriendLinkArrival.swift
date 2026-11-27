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
        make(layers: entries.map(\.layer), signals: signals, receiptsOn: receiptsOn, ownLinkIDs: ownLinkIDs)
    }

    /// The same, from everything the friend sent that the listener hasn't heard, whether or not each Margin can play
    /// yet. Opening the item is what the mark says, so a written Margin whose reading isn't ready, or a voice Margin that
    /// couldn't be placed, still counts (#5351, Test Desk look of 9ad5f26). The listener's own echoed Margins don't.
    public static func make(layers: [ImportedCommentaryLayer], records: [String: [ImportedCommentaryInterjection]],
                            ownMargins: [Interjection] = [], signals: [String: FriendLinkSignal],
                            receiptsOn: Bool, ownLinkIDs: Set<String>) -> FriendLinkArrival {
        let own = OwnMarginEchoes.identities(of: ownMargins)
        let arrived = layers.filter { layer in
            OwnMarginEchoes.withoutEchoes(records[layer.id] ?? [], in: layer, ownIdentities: own).contains(where: \.isNewToListener)
        }
        return make(layers: arrived, signals: signals, receiptsOn: receiptsOn, ownLinkIDs: ownLinkIDs)
    }

    private static func make(layers: [ImportedCommentaryLayer], signals: [String: FriendLinkSignal],
                             receiptsOn: Bool, ownLinkIDs: Set<String>) -> FriendLinkArrival {
        let names = Set(layers.map { FriendName.usable($0.displayLabel ?? "") ?? "" })
        let name = names.count == 1 ? names.first.flatMap { $0.isEmpty ? nil : $0 } : nil
        guard receiptsOn else { return FriendLinkArrival(linkIDs: [], senderName: name) }
        var ids: Set<String> = []
        for layer in layers {
            guard let id = layer.shareLinkId, let signal = signals[id], signal.offered, !signal.sent,
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
