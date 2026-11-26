import Foundation

/// What the app's quiet import does with one fetched answer (#4675, `docs/design/reply-mailbox.md` piece 7 and "Around
/// it"), before anything is written: keep what is already in, drop it, or import it onto the shared item. The app
/// works out the three facts (an earlier import of the same packet, where the matcher would place it, and how
/// `SharedPacketArrival.route` would open it); this decides, so the rule is host-tested and the app stays thin.
public enum ReplyBoxQuietImport {
    public enum Decision: Equatable, Sendable {
        /// The same packet is already in the Library on the shared item, as this layer. Nothing is written and nothing
        /// new is announced (imports are idempotent by digest, #468).
        case alreadyIn(layerId: String)
        /// Left out, with the Diagnostics reason.
        case drop(ReplyBoxAdmission.DropReason)
        /// Import it onto this item (always the record's shared item).
        case importOnto(itemId: String)
    }

    /// An earlier import of the same packet that still stands on an item.
    public struct EarlierImport: Equatable, Sendable {
        public var layerId: String
        public var itemId: String

        public init(layerId: String, itemId: String) {
            self.layerId = layerId
            self.itemId = itemId
        }
    }

    /// `earlier` is an earlier import of this exact packet whose item still holds it (nil for a new packet, or one whose
    /// earlier layer lost its item and would be repaired). `matchingItemId` is where the matcher would place the packet,
    /// `parentPackageDigests` every parent its `margin-conversation` parts name.
    public static func decide(
        record: ReplyBoxRecord, earlier: EarlierImport?, matchingItemId: String?, isListeningMap: Bool,
        requiresRecipientItem: Bool, parentPackageDigests: [String]
    ) -> Decision {
        if let earlier {
            return earlier.itemId == record.itemId ? .alreadyIn(layerId: earlier.layerId) : .drop(.otherItem)
        }
        let route = SharedPacketArrival.route(isListeningMap: isListeningMap, requiresRecipientItem: requiresRecipientItem)
        if let reason = ReplyBoxAdmission.check(
            record: record, placedItemId: matchingItemId, parentPackageDigests: parentPackageDigests, route: route
        ) {
            return .drop(reason)
        }
        return .importOnto(itemId: record.itemId)
    }
}
