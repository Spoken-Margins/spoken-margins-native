import Foundation

/// The decisions the shared-packet import flow makes before it touches a file or the database. The app's
/// `SpokenMarginsPackageImportCoordinator` reads the store, the packet and the listener's files, asks these
/// functions what to do, and carries it out. They take what the coordinator found and return a verdict, so they
/// run on the host (Linux and Mac) without a store or an app.
public enum PackageImportPolicy {
    /// What staging a packet does once its digest is looked up.
    public enum DuplicateCheck: Equatable, Sendable {
        /// The packet is already imported onto this Library item: open it and say so, show no review.
        case alreadyImported(itemId: String)
        /// Show the packet for review. `isRepair` when an earlier import of the same digest exists but no
        /// longer stands on a valid item (wrong source, deleted or different item), so confirming repairs it.
        case review(isRepair: Bool)
    }

    /// Looks at the layer an earlier import of this packet left (`existing`, nil when none) and says whether it
    /// still stands. A layer counts only when it was not rejected as the wrong source, names an item,
    /// that item still loads and is not deleted, and `hasValidItemAssociation` agrees the item is the packet's work.
    /// `loadItem` and `hasValidItemAssociation` run only as far as the earlier checks pass.
    public static func duplicateCheck(
        existing: ImportedCommentaryLayer?,
        loadItem: (String) -> Item?,
        hasValidItemAssociation: (ImportedCommentaryLayer, Item) -> Bool
    ) -> DuplicateCheck {
        guard let existing else { return .review(isRepair: false) }
        guard existing.sourceResolutionStatus != .wrongSource,
              let itemId = existing.itemId,
              let item = loadItem(itemId),
              item.deletedAt == nil,
              hasValidItemAssociation(existing, item) else { return .review(isRepair: true) }
        return .alreadyImported(itemId: itemId)
    }

    /// Where the item for a confirmed import comes from.
    public enum ItemSource: Equatable, Sendable {
        /// The listener already has the one matching Library item.
        case existing(itemId: String)
        /// The packet carries the text, so install it.
        case embeddedText
        /// Fetch the episode.
        case acquirePodcast
        /// Fetch the article, PDF or other text source.
        case acquireArticle
    }

    /// The matching Library item wins, then embedded text, then a download by the packet's item type.
    public static func itemSource(
        matchingItemId: String?,
        transportKind: SharedItemTransportKind,
        itemType: SharedItemType
    ) -> ItemSource {
        if let matchingItemId { return .existing(itemId: matchingItemId) }
        if transportKind == .embeddedText { return .embeddedText }
        return itemType == .podcast ? .acquirePodcast : .acquireArticle
    }
}
