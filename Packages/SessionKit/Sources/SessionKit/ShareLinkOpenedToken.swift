#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The token that says a share link was opened (#5275).
///
/// `hex(HMAC-SHA256(key, "spoken-margins opened v1 " + id))`: 64 lowercase hex characters made from the link's
/// key and id. Only someone holding the whole link can make it, so a messenger's preview fetcher or a scanner
/// that holds only `/l/<id>` can neither fake an open nor read one. Everyone holding the link makes the same
/// token, so a real open is one mark on the server, which keeps only the token's SHA-256. The web listener
/// makes the same value; both are held to `research/B4/contracts/fixtures/share-link-opened-token.json`.
public enum ShareLinkOpenedToken {
    static let label = "spoken-margins opened v1 "

    public static func make(key: ShareLinkSealing.Key, id: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data((label + id).utf8), using: SymmetricKey(data: key.bytes))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// The token for a link that still has its key; nil for one cut short.
    public static func make(for link: ShareLinkURL) -> String? {
        link.key.map { make(key: $0, id: link.id) }
    }

    /// The token's shape: what the server accepts.
    public static func isValid(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
