#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The phone's half of a book club's mailbox (#1799, `docs/design/club-mailbox.md` sections 2 and 5): what it
/// derives from the club's one secret, how it seals the club's header and each post, and the invite link that
/// carries the secret.
///
/// A club is made from one random 32-byte secret `K`. It lives only in the invite link's `#` part, which no
/// browser or app sends to a server. Four independent values come out of `K` with HKDF-SHA-256 (empty salt):
///
/// | info string       | bytes | what it is |
/// | ----------------- | ----- | ---------- |
/// | `sm-club-id-v1`   | 16    | the club id, the mailbox's name, written as 32 lowercase hex digits |
/// | `sm-club-read-v1` | 32    | the read proof a member sends to list and fetch posts |
/// | `sm-club-post-v1` | 32    | the post proof a member sends to add a post |
/// | `sm-club-seal-v1` | 32    | the AES-256-GCM key that seals the header and every post |
///
/// The server is given the id and the SHA-256 of each proof when the club is made, never `K` or the seal key.
///
/// A sealed item is `header ‖ nonce (12) ‖ ciphertext ‖ tag (16)`. The 8-byte header is the share-link header
/// ("SMLINK", version 1, part), with part 3 for the club's header and part 2 for a post. The AES-GCM additional
/// data is that header, then the club's 16 id bytes, so the server cannot move an item to another club, or pass a
/// post off as the header, without the tag failing. It does not include the item's number: the server hands out
/// post numbers when a post arrives, so a phone cannot know its post's number when it seals it, and two members
/// posting at once would seal for the same number. A moved or reordered post is the same packet at another
/// place, which the importer takes in any order and once (#468), so nothing is lost by leaving the number out.
/// `research/B4/contracts/fixtures/club-sealing-vector.json` pins every value above byte for byte, and the Go
/// server's tests and these tests both check it.
public enum ClubSealing {
    /// The club's secret and a share link's key are the same thing: 32 random bytes in base64url.
    public typealias Key = ShareLinkSealing.Key

    /// Anything wrong with a club's invite or one of its items, from a missing key to a flipped byte, reads as this.
    public enum Failure: Error, Equatable, Sendable {
        case incompleteOrDamaged

        public var message: String { "This club link is incomplete or damaged." }
    }

    /// Which sort of item in the box: the sealed header (item 0) or a post (items 1, 2, 3 and so on).
    public enum Item: Equatable, Hashable, Sendable {
        case header
        case post

        var part: UInt8 {
            switch self {
            case .header: 3
            case .post: 2
            }
        }
    }

    /// What `K` becomes. Equal keys give equal credentials; no field gives away another.
    public struct Credentials: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public static let idByteCount = 16
        public static let proofByteCount = 32
        public static let idInfo = "sm-club-id-v1"
        public static let readInfo = "sm-club-read-v1"
        public static let postInfo = "sm-club-post-v1"
        public static let sealInfo = "sm-club-seal-v1"

        /// 32 lowercase hex digits: the mailbox's name and the id in the invite link's path.
        public let id: String
        /// 64 lowercase hex digits, sent as `Authorization: Bearer` to list and fetch.
        public let readProof: String
        /// 64 lowercase hex digits, sent as `Authorization: Bearer` to post.
        public let postProof: String
        /// SHA-256 of the 32 read-proof bytes, in lowercase hex: what the server keeps.
        public let readHash: String
        public let postHash: String

        let idBytes: Data
        let sealKey: Data
        public var description: String { debugDescription }

        /// Never prints the proofs or the seal key, so a stray `print` or log line cannot leak them.
        public var debugDescription: String { "ClubSealing.Credentials(id: \(id), …)" }

        public init(key: Key) {
            let secret = SymmetricKey(data: key.bytes)
            func derive(_ info: String, _ count: Int) -> Data {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: secret,
                    salt: Data(),
                    info: Data(info.utf8),
                    outputByteCount: count
                ).withUnsafeBytes { Data($0) }
            }
            let idBytes = derive(Self.idInfo, Self.idByteCount)
            let read = derive(Self.readInfo, Self.proofByteCount)
            let post = derive(Self.postInfo, Self.proofByteCount)
            self.idBytes = idBytes
            self.id = Self.hex(idBytes)
            self.readProof = Self.hex(read)
            self.postProof = Self.hex(post)
            self.readHash = Self.hex(Data(SHA256.hash(data: read)))
            self.postHash = Self.hex(Data(SHA256.hash(data: post)))
            self.sealKey = derive(Self.sealInfo, 32)
        }

        static func hex(_ bytes: Data) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    static let formatVersion: UInt8 = 1
    private static let magic = Data("SMLINK".utf8)
    private static let nonceByteCount = 12
    private static let tagByteCount = 16

    /// The sealed bytes' fixed extra length over the plaintext: header, nonce and tag.
    public static let overheadByteCount = 8 + nonceByteCount + tagByteCount

    /// Seals one item with a fresh random nonce. `nonce` exists for the shared test vector only.
    public static func seal(
        _ plaintext: Data,
        as item: Item,
        in credentials: Credentials,
        nonce: AES.GCM.Nonce = AES.GCM.Nonce()
    ) throws(Failure) -> Data {
        let header = headerBytes(for: item)
        do {
            let box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: credentials.sealKey),
                nonce: nonce,
                authenticating: associatedData(for: item, in: credentials)
            )
            var sealed = header
            sealed.append(contentsOf: box.nonce)
            sealed.append(box.ciphertext)
            sealed.append(box.tag)
            return sealed
        } catch {
            throw .incompleteOrDamaged
        }
    }

    /// Opens one item. A wrong key, club or part, a flipped byte and a short blob all fail the same way.
    public static func open(_ sealed: Data, as item: Item, in credentials: Credentials) throws(Failure) -> Data {
        let header = headerBytes(for: item)
        let bytes = Data(sealed)
        guard bytes.count >= overheadByteCount, bytes.prefix(header.count) == header else {
            throw .incompleteOrDamaged
        }
        let body = bytes.dropFirst(header.count)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: body.prefix(nonceByteCount)),
                ciphertext: body.dropFirst(nonceByteCount).dropLast(tagByteCount),
                tag: body.suffix(tagByteCount)
            )
            return try AES.GCM.open(
                box,
                using: SymmetricKey(data: credentials.sealKey),
                authenticating: associatedData(for: item, in: credentials)
            )
        } catch {
            throw .incompleteOrDamaged
        }
    }

    static func headerBytes(for item: Item) -> Data {
        magic + [formatVersion, item.part]
    }

    /// The 8-byte header, then the club's 16 id bytes.
    static func associatedData(for item: Item, in credentials: Credentials) -> Data {
        headerBytes(for: item) + credentials.idBytes
    }
}

/// What the creator seals as a club's first item: its name and the creator's own label, as the joiner will see them.
public struct ClubHeader: Codable, Equatable, Sendable {
    public static let schema = "spokenmargins.club-header.v1"
    public static let maximumNameScalars = 100
    public static let maximumLabelScalars = 60

    public var schema: String
    public var name: String
    public var creatorLabel: String?

    /// Trims and cuts the words to what the invite screen shows. Nil when the club has no name.
    public init?(name: String, creatorLabel: String? = nil) {
        let cleanName = Self.cut(name, to: Self.maximumNameScalars)
        guard !cleanName.isEmpty else { return nil }
        let cleanLabel = creatorLabel.map { Self.cut($0, to: Self.maximumLabelScalars) }.flatMap { $0.isEmpty ? nil : $0 }
        self.schema = Self.schema
        self.name = cleanName
        self.creatorLabel = cleanLabel
    }

    private static func cut(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(limit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// A header from sealed-then-opened bytes, nil unless it is this version's shape with a usable name.
    static func decoded(_ data: Data) -> ClubHeader? {
        guard let header = try? JSONDecoder().decode(ClubHeader.self, from: data),
              header.schema == schema,
              let clean = ClubHeader(name: header.name, creatorLabel: header.creatorLabel),
              clean == header else { return nil }
        return header
    }
}

/// A club invite: `https://<host>/c/<id>#<K>`. The path is public; the `#` part is the secret.
public struct ClubInvite: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Parsed: Equatable, Sendable {
        /// Not a club link at all: another host, another path or no id. Other handlers may take it.
        case notAClubLink
        /// A club link that cannot open: no key, a key that is not one, or a path id that is not the key's id.
        case incompleteOrDamaged
        case invite(ClubInvite)
    }

    public let key: Key
    public let credentials: ClubSealing.Credentials

    public typealias Key = ClubSealing.Key

    public var id: String { credentials.id }

    /// Never prints the key, which is the club.
    public var description: String { "ClubInvite(id: \(id), …)" }
    public var debugDescription: String { description }

    public init(key: Key) {
        self.key = key
        self.credentials = ClubSealing.Credentials(key: key)
    }

    /// A fresh club: a new random secret.
    public static func random() -> ClubInvite {
        ClubInvite(key: .random())
    }

    /// Reads a link the app was opened with. Only that exact shape is a club link: `https`, the product host,
    /// `/c/<32 lowercase hex>`, no user, password or port. The phone refuses a link whose path id is not the id
    /// derived from its key, so a link cannot name one club and open another.
    public static func parse(_ url: URL) -> Parsed {
        guard ShareLinkURL.isOnShareHost(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .notAClubLink }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "c" else { return .notAClubLink }
        let pathID = String(parts[2])
        guard pathID.utf8.count == ShareLinkURL.idLength,
              pathID.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            return .notAClubLink
        }
        guard let key = ShareLinkSealing.key(inLink: url) else { return .incompleteOrDamaged }
        let invite = ClubInvite(key: key)
        return invite.id == pathID ? .invite(invite) : .incompleteOrDamaged
    }

    /// The link to share, on `host` (the product host unless a Debug build was pointed elsewhere).
    public func url(host: String = ProductServer.productionHost) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/c/\(id)"
        components.fragment = key.fragment
        return components.url!
    }

    /// The sealed header the creator uploads with the club: item 0.
    public func sealedHeader(_ header: ClubHeader) throws -> Data {
        try ClubSealing.seal(try header.encoded(), as: .header, in: credentials)
    }

    /// The header a joiner reads from item 0, or nil when it does not open or is not a club header.
    public func openHeader(_ sealed: Data) throws(ClubSealing.Failure) -> ClubHeader {
        let plain = try ClubSealing.open(sealed, as: .header, in: credentials)
        guard let header = ClubHeader.decoded(plain) else { throw .incompleteOrDamaged }
        return header
    }
}
