#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Seals a share link's packet and preview on the phone, so the link server stores bytes it can't read (#805).
///
/// A link is `https://<host>/l/<id>#<key>`. The key is 32 random bytes in base64url and travels only in the
/// `#` part, which browsers and apps never send to a server. The preview (Margin texts, source title, show)
/// and the packet are sealed separately with AES-256-GCM under that key, so the landing page can decrypt the
/// small preview without downloading the packet. Opened, the packet is byte-identical to the file share, so
/// ``ShareableLinkPolicy`` and the Build 29 round trip apply unchanged.
///
/// A sealed part is `header ‖ nonce (12) ‖ ciphertext ‖ tag (16)`. The 8-byte header is "SMLINK", the format
/// version and the part number. It is also the AES-GCM additional data, so a preview can't be passed off as the
/// packet, nor the version changed, without the tag failing. The browser's decrypt code
/// (`research/B4/server/internal/links/share-link-open.mjs`) and the tests check against one vector,
/// `research/B4/contracts/fixtures/share-link-sealing-vector.json`.
public enum ShareLinkSealing {
    public enum Part: UInt8, Sendable {
        case preview = 1
        case packet = 2
    }

    /// Anything wrong with a link, from a missing key to a flipped byte, opens as this one plain result.
    public enum Failure: Error, Equatable, Sendable {
        case incompleteOrDamaged

        public var message: String { "This link is incomplete or damaged." }
    }

    public struct Key: Equatable, Sendable {
        public static let byteCount = 32

        public let bytes: Data

        public init?(bytes: Data) {
            guard bytes.count == Self.byteCount else { return nil }
            self.bytes = Data(bytes)
        }

        /// Reads the key from a link's `#` part: base64url, with or without `=` padding.
        public init?(fragment: String) {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            let unpadded = String(fragment.prefix { $0 != "=" })
            guard !unpadded.isEmpty,
                  unpadded.unicodeScalars.allSatisfy(allowed.contains),
                  fragment.dropFirst(unpadded.count).allSatisfy({ $0 == "=" }) else { return nil }
            var base64 = unpadded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64) else { return nil }
            self.init(bytes: bytes)
        }

        /// A fresh key for one link.
        public static func random() -> Key {
            SymmetricKey(size: .bits256).withUnsafeBytes { Key(bytes: Data($0))! }
        }

        /// The `#` part of the link: base64url without padding (43 characters).
        public var fragment: String {
            bytes.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        fileprivate var symmetricKey: SymmetricKey { SymmetricKey(data: bytes) }
    }

    /// What the app uploads. The server stores both as opaque bytes.
    public struct SealedLink: Equatable, Sendable {
        public let preview: Data
        public let packet: Data

        public init(preview: Data, packet: Data) {
            self.preview = preview
            self.packet = packet
        }
    }

    public struct OpenedLink: Equatable, Sendable {
        public let preview: Data
        public let packet: Data
    }

    static let formatVersion: UInt8 = 1
    private static let magic = Data("SMLINK".utf8)
    private static let nonceByteCount = 12
    private static let tagByteCount = 16

    public static func seal(packet: Data, preview: Data, key: Key) throws -> SealedLink {
        SealedLink(
            preview: try seal(preview, as: .preview, key: key),
            packet: try seal(packet, as: .packet, key: key)
        )
    }

    /// Opens both parts. A nil key (the link lost its `#` part) fails the same way as a damaged blob.
    public static func open(_ sealed: SealedLink, key: Key?) throws(Failure) -> OpenedLink {
        guard let key else { throw .incompleteOrDamaged }
        return OpenedLink(
            preview: try open(sealed.preview, as: .preview, key: key),
            packet: try open(sealed.packet, as: .packet, key: key)
        )
    }

    /// Seals one part with a fresh random nonce. `nonce` exists for the shared test vector only.
    static func seal(_ plaintext: Data, as part: Part, key: Key, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        let header = headerBytes(for: part)
        let box = try AES.GCM.seal(plaintext, using: key.symmetricKey, nonce: nonce, authenticating: header)
        var sealed = header
        sealed.append(contentsOf: box.nonce)
        sealed.append(box.ciphertext)
        sealed.append(box.tag)
        return sealed
    }

    public static func open(_ sealed: Data, as part: Part, key: Key) throws(Failure) -> Data {
        let header = headerBytes(for: part)
        let bytes = Data(sealed)
        guard bytes.count >= header.count + nonceByteCount + tagByteCount,
              bytes.prefix(header.count) == header else { throw .incompleteOrDamaged }
        let body = bytes.dropFirst(header.count)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: body.prefix(nonceByteCount)),
                ciphertext: body.dropFirst(nonceByteCount).dropLast(tagByteCount),
                tag: body.suffix(tagByteCount)
            )
            return try AES.GCM.open(box, using: key.symmetricKey, authenticating: header)
        } catch {
            throw .incompleteOrDamaged
        }
    }

    /// The link to share: `base` (the server's `https://<host>/l/<id>`) with the key as its `#` part.
    public static func linkURL(base: URL, key: Key) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = key.fragment
        return components.url
    }

    /// The key in a link the app was opened with, or nil when the `#` part is missing or isn't a key.
    public static func key(inLink url: URL) -> Key? {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else { return nil }
        return Key(fragment: fragment)
    }

    private static func headerBytes(for part: Part) -> Data {
        magic + [formatVersion, part.rawValue]
    }
}
