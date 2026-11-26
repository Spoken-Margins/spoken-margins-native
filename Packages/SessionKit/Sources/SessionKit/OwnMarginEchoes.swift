import Foundation

/// A copy of the listener's own Margin that came back to them inside an imported packet (#4697).
///
/// Every Margin the listener shares is remembered by the packet identities it went out under (`Interjection.sharedAs`).
/// If a packet carrying that Margin is imported on the same phone (their own link opened, a file sent to themselves, a
/// friend's packet that repeats it), the importer saves it like any other friend's Margin, under the packet's layer. It
/// is still the listener's own words: the Library row must not count it as "from a friend", it must not be new to the
/// person who made it, and the review must not offer it. The match is the packet identity, the same one
/// `MarginReplyGraph` uses to let "a listener's own Margin win over a copy of it they imported back"; words and a
/// display label alone never decide it, so a friend who happens to say the same thing is still a friend.
///
/// The Library's counts come from SQL (`SQLiteSessionStore.notAnEchoOfOwnMarginSQL`), which cannot call this. The two
/// are one rule written twice, and `OwnMarginEchoesTests` runs both over the same table so they cannot drift apart.
/// Nothing here writes: the copy stays stored exactly as it was, so the previous build opens the database unchanged.
public enum OwnMarginEchoes {
    /// Every packet identity the listener's active Margins went out under. A deleted Margin is neither a parent nor a
    /// reply in the reply graph and isn't in the Margins list the review is given, so its copy reads as it always
    /// did; every screen and the SQL follow the same rule, so the row and the offer cannot disagree.
    public static func identities(of ownMargins: [Interjection]) -> Set<MarginPacketIdentity> {
        Set(ownMargins.filter { $0.status == "active" }.flatMap { $0.sharedAs ?? [] })
    }

    /// The identities an imported Margin is known by: the packet it arrived in, and any later packet that carried it
    /// again (#858).
    public static func identities(of margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer) -> [MarginPacketIdentity] {
        [MarginPacketIdentity(packageDigest: layer.packageDigest, packageScopedId: margin.packageScopedId)]
            + (margin.alsoSharedAs ?? [])
    }

    /// Whether this imported Margin is a copy of one of the listener's own, given `ownIdentities` from `identities(of:)`.
    public static func isEcho(
        _ margin: ImportedCommentaryInterjection, in layer: ImportedCommentaryLayer, ownIdentities: Set<MarginPacketIdentity>
    ) -> Bool {
        guard !ownIdentities.isEmpty else { return false }
        return identities(of: margin, in: layer).contains { ownIdentities.contains($0) }
    }

    /// The Margins that are really someone else's: `records` without the listener's own echoes.
    public static func withoutEchoes(
        _ records: [ImportedCommentaryInterjection], in layer: ImportedCommentaryLayer, ownIdentities: Set<MarginPacketIdentity>
    ) -> [ImportedCommentaryInterjection] {
        guard !ownIdentities.isEmpty else { return records }
        return records.filter { !isEcho($0, in: layer, ownIdentities: ownIdentities) }
    }

    /// The layers and records that are really someone else's (#4910).
    public struct FriendMargins: Equatable {
        public let layers: [ImportedCommentaryLayer]
        public let records: [String: [ImportedCommentaryInterjection]]
    }

    /// `layers` and `records` without the listener's own echoes, for every reader that shows or plays a friend's
    /// Margins from memory. `ownMargins` are the own Margins of the layers' item. A layer that held Margins and now
    /// holds none was only copies, so it is dropped with its key; a layer with no Margins to begin with (a Listening
    /// Map) is kept. With no own identities the input comes back unchanged.
    public static func friendMargins(
        layers: [ImportedCommentaryLayer],
        records: [String: [ImportedCommentaryInterjection]],
        ownMargins: [Interjection]
    ) -> FriendMargins {
        let own = identities(of: ownMargins)
        guard !own.isEmpty else { return FriendMargins(layers: layers, records: records) }
        var keptLayers: [ImportedCommentaryLayer] = []
        var keptRecords: [String: [ImportedCommentaryInterjection]] = [:]
        for layer in layers {
            guard let all = records[layer.id] else {
                keptLayers.append(layer)
                continue
            }
            let kept = withoutEchoes(all, in: layer, ownIdentities: own)
            if kept.isEmpty && !all.isEmpty { continue }
            keptLayers.append(layer)
            keptRecords[layer.id] = kept
        }
        return FriendMargins(layers: keptLayers, records: keptRecords)
    }
}
