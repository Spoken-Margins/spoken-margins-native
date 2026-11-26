import Foundation

/// A Margin's identity as the app keys it: "session::margin". The speech ask's waiting list stores these.
public enum MarginIdentity {
    public static let separator = "::"

    public static func make(sessionId: String, interjectionId: String) -> String {
        "\(sessionId)\(separator)\(interjectionId)"
    }

    /// The inverse of `make`, split at the first separator. Nil for anything that isn't one: no separator, or an empty
    /// session or Margin id.
    public static func split(_ identity: String) -> (sessionId: String, interjectionId: String)? {
        guard let range = identity.range(of: separator) else { return nil }
        let sessionId = String(identity[..<range.lowerBound])
        let interjectionId = String(identity[range.upperBound...])
        guard !sessionId.isEmpty, !interjectionId.isEmpty else { return nil }
        return (sessionId, interjectionId)
    }
}
