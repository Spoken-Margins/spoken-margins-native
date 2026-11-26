import Foundation
import SessionKit

/// Friends' replies land on the row that holds the Margins they answer (#5286). A replies packet names its parents by
/// packet identity (the digest of the packet the listener sent and each Margin's id in it), which only the listener's
/// own Margins on one item carry as `sharedAs`. That is stronger evidence than the episode identity the replies packet
/// names: the friend's copy may be another feed edition (Opus where the listener heard the MP3), and the listener may
/// hold the episode on two rows. The item holding the parents wins when it is the same work as the packet's item; any
/// other case falls back to `SharedPacketItemMatcher.matchingItemId`.
public enum ReplyParentItemMatch {
    /// Every parent the packet's replies name (`VerifiedSpokenMarginsPackage.conversations`), without repeats, in
    /// packet order.
    public static func parents(in conversations: [MarginConversationArtifact]) -> [MarginPacketIdentity] {
        var seen: Set<MarginPacketIdentity> = []
        return conversations.flatMap(\.replies).compactMap { reply in
            let parent = MarginPacketIdentity(packageDigest: reply.parentPackageDigest, packageScopedId: reply.parentPackageScopedId)
            return seen.insert(parent).inserted ? parent : nil
        }
    }

    /// The one live item among `holdingParents` (the items holding the listener's own Margins shared as one of the
    /// parents) that can stand for the packet's item, or nil when none or several can. A reply never moves to a row
    /// that is another work: replies that name another episode keep the ordinary match.
    public static func itemId(
        for packetItem: SharedItemIdentity,
        holdingParents: Set<String>,
        among items: [Item],
        ownedAudiobookDigest: (Item) -> String? = { _ in nil },
        textDigests: (Item) -> ItemTextDigests? = { _ in nil }
    ) -> String? {
        guard !holdingParents.isEmpty else { return nil }
        let matches = items.filter { item in
            holdingParents.contains(item.id) && item.deletedAt == nil
                && ImportedItemResolver.canRepresentSameWork(packetItem, SharedPacketItemMatcher.localIdentity(
                    for: item, ownedAudiobookDigest: ownedAudiobookDigest(item), textDigests: textDigests(item)))
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}
