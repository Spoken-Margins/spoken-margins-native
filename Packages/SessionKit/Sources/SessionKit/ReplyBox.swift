#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A reply box (#4675, `docs/design/reply-mailbox.md`): a club of two that the sender's phone makes with each share
/// link, so a friend who opens the link in a browser can answer through it.
///
/// The box is made from one random 32-byte secret `K`, which never leaves this phone. Its id, read proof, post proof
/// and seal key come from `K` exactly as a club's do (``ClubSealing/Credentials``). The server is told the id and the
/// hashes of the two proofs in four headers on the link upload (``uploadHeaders(linkKey:)``). The friend gets the post
/// proof and the seal key, never `K`, in a small part sealed with the link's own key (``sealedReplyPart(linkKey:)``,
/// `SMLINK` part 4), so a holder of the link can post an answer but never read one. Only this phone, holding `K`, can
/// list, fetch, close or report.
///
/// `research/B4/contracts/fixtures/reply-box-vector.json` pins every value byte for byte; Go, Swift and web tests check it.
public struct ReplyBox: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public typealias Key = ClubSealing.Key

    /// The four headers on `POST /api/v1/links`, all or none.
    public static let idHeader = "X-SM-Reply-Id"
    public static let readHashHeader = "X-SM-Reply-Read-Hash"
    public static let postHashHeader = "X-SM-Reply-Post-Hash"
    public static let partHeader = "X-SM-Reply-Part"

    /// The reply part's format version, `v` in its JSON.
    public static let replyPartVersion = 1
    /// The server takes at most 1 KiB of sealed reply part (decoded).
    public static let maximumSealedReplyPartBytes = 1 << 10

    public let key: Key
    public let credentials: ClubSealing.Credentials

    public init(key: Key) {
        self.key = key
        self.credentials = ClubSealing.Credentials(key: key)
    }

    /// A fresh box: a new random secret.
    public static func random() -> ReplyBox {
        ReplyBox(key: .random())
    }

    /// 32 lowercase hex digits: the box's name on the server.
    public var id: String { credentials.id }

    /// The box as a club invite, which is what ``ClubClient`` lists and fetches with.
    public var invite: ClubInvite { ClubInvite(key: key) }

    /// The seal key as the friend's page reads it: base64url, no padding (43 characters).
    public var sealKeyBase64URL: String {
        credentials.sealKey.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Never prints the key or the proofs.
    public var description: String { "ReplyBox(id: \(id), …)" }
    public var debugDescription: String { description }

    /// The reply part before sealing: `{"box":…,"post":…,"seal":…,"v":1}`, keys sorted, no spaces.
    public struct Part: Codable, Equatable, Sendable {
        public var v: Int
        public var box: String
        public var post: String
        public var seal: String
    }

    public var part: Part {
        Part(v: Self.replyPartVersion, box: id, post: credentials.postProof, seal: sealKeyBase64URL)
    }

    func replyPartJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(part)
    }

    /// The reply part sealed with the link's key as `SMLINK` part 4. `nonce` exists for the shared test vector only.
    public func sealedReplyPart(linkKey: ShareLinkSealing.Key, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        try ShareLinkSealing.seal(try replyPartJSON(), as: .reply, key: linkKey, nonce: nonce)
    }

    /// The four headers the phone adds to the link upload. `nonce` exists for the shared test vector only.
    public func uploadHeaders(linkKey: ShareLinkSealing.Key, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> [String: String] {
        let sealed = try sealedReplyPart(linkKey: linkKey, nonce: nonce)
        return [
            Self.idHeader: id,
            Self.readHashHeader: credentials.readHash,
            Self.postHashHeader: credentials.postHash,
            Self.partHeader: sealed.base64EncodedString(),
        ]
    }

    /// Opens a sealed reply part, as the friend's page does. Unknown keys are ignored; a wrong version, a damaged blob
    /// or a field of the wrong shape fails.
    public static func openReplyPart(_ sealed: Data, linkKey: ShareLinkSealing.Key) throws(ShareLinkSealing.Failure) -> Part {
        let plain = try ShareLinkSealing.open(sealed, as: .reply, key: linkKey)
        guard let part = try? JSONDecoder().decode(Part.self, from: plain),
              part.v == replyPartVersion,
              part.box.utf8.count == 32, part.post.utf8.count == 64, part.seal.utf8.count == 43 else {
            throw .incompleteOrDamaged
        }
        return part
    }

    /// Seals an answer as the friend's page does: a club post (`SMLINK` part 2, the seal key, additional data the
    /// header then the box id bytes). The phone never posts to its own box; this is for tests and tools.
    public func sealAnswer(_ packet: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws(ClubSealing.Failure) -> Data {
        try ClubSealing.seal(packet, as: .post, in: credentials, nonce: nonce)
    }

    /// Opens a fetched answer to the packet's exact bytes.
    public func openAnswer(_ sealed: Data) throws(ClubSealing.Failure) -> Data {
        try ClubSealing.open(sealed, as: .post, in: credentials)
    }
}
