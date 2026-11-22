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
}
