#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Stable provenance for one captured Margin, not a sender identity or signature. SessionEngine
/// gives each session a random UUID; its Margin IDs alone (ij-001, etc.) are only session-local.
/// The opaque token goes in an existing representation ID, which Build 29 already accepts.
public enum MarginShareProvenance {
    private static let prefix = "sm-origin-v1-"

    public static func token(sessionId: String, interjectionId: String) -> String? {
        guard let sessionUUID = UUID(uuidString: String(sessionId.suffix(36))), !interjectionId.isEmpty else { return nil }
        // Length-delimited JSON avoids collisions from separators in a local ID. Neither local ID
        // nor the session UUID is exposed in the packet.
        guard let data = try? JSONEncoder().encode([sessionUUID.uuidString.lowercased(), interjectionId]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func representationID(token: String?, kind: String, fallback: String) -> String {
        guard let token, isValidToken(token) else { return fallback }
        return prefix + token + "-" + kind
    }

    public static func token(representationID: String) -> String? {
        guard representationID.hasPrefix(prefix) else { return nil }
        let parts = representationID.dropFirst(prefix.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, ["text", "original", "cleaned"].contains(String(parts[1])),
              isValidToken(String(parts[0])) else { return nil }
        return String(parts[0])
    }

    public static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
