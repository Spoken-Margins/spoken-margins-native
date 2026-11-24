import Foundation

extension Interjection {
    /// The key that names one Margin across an item's listening passes (#4688). Margin ids are numbered per session
    /// (`RecordingDraftJournal`: "ij-001" is every pass's first Margin), and the store keys a Margin by its session and
    /// id, so anything that holds Margins from more than one pass keys them by this, never by `id` alone.
    public var sessionScopedId: String { Self.sessionScopedId(sessionId: sessionId, id: id) }

    /// The same key from its parts, for a record that carries both (a share revision, a stored lookup).
    public static func sessionScopedId(sessionId: String, id: String) -> String { "\(sessionId)::\(id)" }
}
