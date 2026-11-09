import Foundation
import SessionKit

/// The saved Session and Margin a tap on "play this Margin's moment" means (#2505). It is the check
/// `playMarginMoment` ran on the main thread over every Margin of the session; it reads the one Margin, and a caller
/// may run it inside `StoreReader`.
public struct MarginMomentTarget: Sendable {
    public let session: Session
    public let interjection: Interjection

    /// Nil when the session is gone or belongs to another item, or the Margin is not in it, not on that item, or no
    /// longer active.
    public static func find(store: SQLiteSessionStore, sessionId: String, itemId: String, interjectionId: String) throws -> MarginMomentTarget? {
        guard let session = try store.loadSession(id: sessionId), session.itemId == itemId,
              let interjection = try store.loadInterjection(id: interjectionId, sessionId: session.id),
              interjection.sessionId == session.id, interjection.itemId == session.itemId, interjection.status == "active" else { return nil }
        return MarginMomentTarget(session: session, interjection: interjection)
    }
}
