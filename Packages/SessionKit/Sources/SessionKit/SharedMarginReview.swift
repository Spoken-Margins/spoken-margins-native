import Foundation

/// "Review new Margins" (#474): which of an item's shared Margins the listener hasn't heard, in the order they
/// play, and how the app words the offer to hear them.
///
/// A Margin is new until its voice first plays (#469, `SharedMarginHearing`). Only Margins the automatic
/// prompts would play are offered: an enabled layer that isn't the wrong source, and a Margin that is placed
/// at a time in this copy of the episode and has something to play: a recording, or the words of a written Margin,
/// which the iPhone's voice reads (#3365). `MarginMomentSequence(reviewing:)` plays them.
public enum SharedMarginReview {
    /// One new shared Margin, with what the app needs to play it and mark it heard.
    public struct Entry: Sendable, Equatable {
        public let layer: ImportedCommentaryLayer
        public let interjection: ImportedCommentaryInterjection
        public let mediaTimeMs: Int
        /// Placed by a clock time or a map rather than a match, so the position is a best guess.
        public let isApproximate: Bool
        /// What this Margin answers when it is a reply (#3221); nil for any other Margin.
        public var replyContext: ReplyContext?
        /// No usable time in this copy (#3789): it plays after the others, and `mediaTimeMs` is where the others end.
        public var playsAfterOthers: Bool

        public init(
            layer: ImportedCommentaryLayer, interjection: ImportedCommentaryInterjection, mediaTimeMs: Int,
            isApproximate: Bool, replyContext: ReplyContext? = nil, playsAfterOthers: Bool = false
        ) {
            self.layer = layer
            self.interjection = interjection
            self.mediaTimeMs = mediaTimeMs
            self.isApproximate = isApproximate
            self.replyContext = replyContext
            self.playsAfterOthers = playsAfterOthers
        }

        /// The identity the playback screen, the conductor and the Timeline all use for this Margin.
        public var marginId: String { SharedMarginReview.marginId(layerId: layer.id, interjectionId: interjection.id) }
        public var senderLabel: String { SharedMarginReview.senderLabel(of: layer) }
        public var anchor: MarginMomentAnchor {
            MarginMomentAnchor(
                marginId: marginId, mediaTimeMs: mediaTimeMs, label: senderLabel, isApproximate: isApproximate,
                caption: replyContext?.caption, isReadAloud: interjection.isWritten
            )
        }
    }

    /// The same text `SharedMarginRow.id` builds, so the playback screen can find the row for a Margin.
    public static func marginId(layerId: String, interjectionId: String) -> String {
        "shared::\(layerId)::\(interjectionId)"
    }

    /// The layer's sender label as an internal key: it orders Margins, tells senders apart and rides on the Margin's
    /// anchor. It is not for display: a file that names nobody carries the stand-in here, so every screen goes
    /// through `SharedPacketArrival.senderName` (the offer, the pinned card and a reply's caption all do).
    public static func senderLabel(of layer: ImportedCommentaryLayer) -> String {
        let label = layer.displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SharedPacketArrival.snapshotSenderLabel(label)
    }

    /// The item's new shared Margins in playing order: by place in the episode, then, where two share a place,
    /// by sender label and then by when it was made, so the same Margins always play the same way round.
    ///
    /// `ownMargins` are the listener's own Margins on the item. A friend's reply to one of them says so (#3221).
    public static func entries(
        layers: [ImportedCommentaryLayer],
        records: [String: [ImportedCommentaryInterjection]],
        ownMargins: [Interjection] = [],
        durationMs: Int? = nil
    ) -> [Entry] {
        let contexts = replyContexts(layers: layers, records: records, ownMargins: ownMargins)
        return layers.flatMap { layer -> [Entry] in
            let layerRecords = records[layer.id] ?? []
            guard SharedMarginPrompts.isLayerPlaybackEligible(layer, records: layerRecords) else { return [] }
            return layerRecords.compactMap { record -> Entry? in
                // The same test and the same time the automatic prompts use. A Margin plays where it was placed, else
                // at the sender's time, before the placement pass has run (#3059, #4097) and after it couldn't place
                // it (#3789); one with no usable time plays after the others.
                guard record.isNewToListener, SharedMarginPrompts.isPlayable(record, in: layer) else { return nil }
                return entry(for: record, in: layer, durationMs: durationMs, replyContext: contexts[record.id])
            }
        }.placingAfterOthersLast(durationMs: durationMs).sorted(by: playsBefore)
    }

    /// One Margin's entry from its plan (#3789). A Margin with no usable time gets a placeholder time, set by
    /// `placingAfterOthersLast` once the others are known.
    static func entry(
        for record: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, durationMs: Int?, replyContext: ReplyContext?
    ) -> Entry? {
        switch SharedMarginPrompts.plan(record, in: layer, durationMs: durationMs) {
        case .placed(let ms?):
            return ms >= 0 ? Entry(layer: layer, interjection: record, mediaTimeMs: ms, isApproximate: false, replyContext: replyContext) : nil
        case .roughly(let ms?):
            return ms >= 0 ? Entry(layer: layer, interjection: record, mediaTimeMs: ms, isApproximate: true, replyContext: replyContext) : nil
        case .afterOthers:
            return Entry(layer: layer, interjection: record, mediaTimeMs: 0, isApproximate: true,
                         replyContext: replyContext, playsAfterOthers: true)
        case .placed(nil), .roughly(nil), .notPlayable:
            return nil
        }
    }

    /// The same, read from the repository for an item that isn't open.
    public static func entries(
        itemId: String, in repository: some ListeningSessionRepository, ownMargins: [Interjection] = [],
        hiddenSenders: HiddenSenders = HiddenSenders()
    ) throws -> [Entry] {
        let layers = hiddenSenders.visible(try repository.loadImportedCommentaryLayers(itemId: itemId))
        var records: [String: [ImportedCommentaryInterjection]] = [:]
        for layer in layers { records[layer.id] = hiddenSenders.visible(try repository.loadImportedCommentaryInterjections(layerId: layer.id)) }
        return entries(layers: layers, records: records, ownMargins: ownMargins)
    }

    /// The listener's own Margins on an item, for the review's "Reply to your Margin" (#3353). The open item holds
    /// only one session's Margins (its newest, or the one playing), but a Margin shared from an earlier session is
    /// the parent of a friend's reply all the same; the Margins list holds every session's. Both are read, so a
    /// Margin made just now and one shared long ago are found. A Margin in both lists is one Margin (the open item's copy is the fresher), and keeps every
    /// packet identity either list knows it by (a list read before a share doesn't have the new identity yet).
    public static func ownMargins(itemId: String, openItem: [Interjection], rows: some Sequence<Interjection>) -> [Interjection] {
        var merged: [Interjection] = []
        var index: [String: Int] = [:]
        for margin in openItem + rows where margin.itemId == itemId {
            if let at = index[margin.id] {
                for identity in margin.sharedAs ?? [] where !(merged[at].sharedAs ?? []).contains(identity) {
                    merged[at].sharedAs = (merged[at].sharedAs ?? []) + [identity]
                }
            } else {
                index[margin.id] = merged.count
                merged.append(margin)
            }
        }
        return merged
    }

    /// The Margins Continue should ask about: the ones the listener is already past (#3059). A Margin still ahead of
    /// their place plays in place as the episode reaches it, so the big button just plays; only a Margin behind the
    /// place would be skipped, and the review is the way to hear it. With no place given, all of them count.
    public static func entriesBehind(_ entries: [Entry], placeMs: Int?) -> [Entry] {
        guard let placeMs else { return entries } // the place isn't known, so none can be ruled out
        return entries.filter { $0.mediaTimeMs < placeMs }
    }

    /// The text of the offer shown before Continue: how many Margins and whose.
    public static func offerMessage(for entries: [Entry]) -> String {
        // Named senders are told apart by name. A nameless one has no name to show, so those are counted by file and
        // read "a friend" or "2 friends", never as a stand-in.
        var senders: [String] = []
        var namelessFiles = Set<String>()
        for entry in entries {
            if let name = SharedPacketArrival.senderName(entry.senderLabel) {
                if !senders.contains(name) { senders.append(name) }
            } else {
                namelessFiles.insert(entry.layer.id)
            }
        }
        if namelessFiles.count == 1 { senders.append("a friend") }
        if namelessFiles.count > 1 { senders.append("\(namelessFiles.count) friends") }
        let count = entries.count
        let whose: String
        switch senders.count {
        case 0, 1: whose = senders.first ?? "a friend"
        case 2: whose = "\(senders[0]) and \(senders[1])"
        case 3: whose = "\(senders[0]), \(senders[1]) and \(senders[2])"
        default: whose = "\(senders[0]), \(senders[1]) and \(senders.count - 2) others"
        }
        return "\(count) new Margin\(count == 1 ? "" : "s") from \(whose). Hear \(count == 1 ? "it" : "them") in place first, then carry on from where you were."
    }

    static func playsBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.playsAfterOthers != rhs.playsAfterOthers { return rhs.playsAfterOthers }
        if lhs.mediaTimeMs != rhs.mediaTimeMs { return lhs.mediaTimeMs < rhs.mediaTimeMs }
        let (left, right) = (lhs.senderLabel, rhs.senderLabel)
        if left.lowercased() != right.lowercased() { return left.lowercased() < right.lowercased() }
        if left != right { return left < right }
        if lhs.interjection.createdAt != rhs.interjection.createdAt { return lhs.interjection.createdAt < rhs.interjection.createdAt }
        return lhs.marginId < rhs.marginId
    }
}

extension Array where Element == SharedMarginReview.Entry {
    /// Gives each Margin that plays after the others the time where the others end: the episode's end when its
    /// length is known, never earlier than the last Margin that has a place (#3789).
    func placingAfterOthersLast(durationMs: Int?) -> [Element] {
        let end = Swift.max(durationMs ?? 0, filter { !$0.playsAfterOthers }.map(\.mediaTimeMs).max() ?? 0)
        return map { entry in
            guard entry.playsAfterOthers else { return entry }
            return SharedMarginReview.Entry(
                layer: entry.layer, interjection: entry.interjection, mediaTimeMs: end, isApproximate: true,
                replyContext: entry.replyContext, playsAfterOthers: true)
        }
    }
}

/// What the listener turned down on the new-Margins offer ("Listen without them", #474). The offer stays quiet for
/// that item until a Margin arrives that it hadn't asked about, so Continue on a two-hour episode with a friend's
/// Margin at minute 90 doesn't ask at every press. Hearing a Margin some other way never brings the offer back.
public struct NewMarginsOfferMemory: Sendable, Equatable {
    private var declined: [String: Set<String>] = [:]

    public init() {}

    /// The listener chose to carry on without hearing `margins` (their `marginId`s) on this item.
    public mutating func decline(itemId: String, margins: [String]) {
        declined[itemId, default: []].formUnion(margins)
    }

    /// Whether every one of `margins` has already been turned down on this item.
    public func isDeclined(itemId: String, margins: [String]) -> Bool {
        Set(margins).isSubset(of: declined[itemId] ?? [])
    }
}
