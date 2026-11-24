import Foundation
import SessionKit

/// What a packet's arrival needs to know about an item before the file is imported (#4910): the listener's own
/// Margins, and whether a friend's Margins were already there. Reads only.
public enum PacketArrivalReading {
    /// The item's own Margins from every session (unfiltered: `OwnMarginEchoes.identities(of:)` keeps the active ones),
    /// and whether the item held a friend's Margins, with the listener's own copies not counting. Like the check this
    /// replaces, it does not apply hidden senders.
    public static func beforeImport(
        itemId: String, store: SQLiteSessionStore
    ) throws -> (ownMargins: [Interjection], hadFriendMargins: Bool) {
        let ownMargins = try store.loadSessions(itemId: itemId).flatMap { try store.loadInterjections(sessionId: $0.id) }
        let layers = try store.loadImportedCommentaryLayers(itemId: itemId).filter { $0.deletedAt == nil }
        var records: [String: [ImportedCommentaryInterjection]] = [:]
        for layer in layers {
            records[layer.id] = try store.loadImportedCommentaryInterjections(layerId: layer.id)
        }
        return (
            ownMargins,
            SharedPacketArrival.hadFriendMargins(layers: layers, records: records, ownMargins: ownMargins))
    }
}
