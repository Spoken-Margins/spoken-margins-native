#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// The phone's side of the server's anonymous tokens (research/B4/DESIGN.md §3,
// §11; #748). An attested install asks for a few blind-signed tokens; later it
// spends one on a request that carries no install identity, such as a listening
// map upload. The server signs without seeing the token, so it can't link the
// spend to the install.
//
// Tokens are Privacy Pass type 2 (RFC 9578), signed with
// RSABSSA-SHA384-PSS-Deterministic (RFC 9474). This file does the client steps:
// encode and blind a token, then unblind and check the server's signature. The
// Go server's `internal/tokens` is the reference, and both reproduce the RFCs'
// test vectors. Nothing in the app calls this yet.

public enum PrivacyPassToken {
    public static let tokenType: UInt16 = 2
    /// The TokenChallenge issuer_name every Spoken Margins token names.
    public static let issuerName = "spokenmargins.proximitytoprogress.com"
    /// The purpose a listening-map upload token is made for (#743).
    public static let mapsPurpose = "maps"
    public static let keysSchema = "spokenmargins.token-keys.v1"
    /// RFC 9474's salt length for the SHA-384 PSS variants.
    static let saltLength = 48
    static let minimumModulusBits = 2048
    static let nonceLength = 32

    public enum Failure: Error, Equatable, Sendable {
        /// A key that isn't an RSASSA-PSS SHA-384 key encoded as RFC 9578 requires.
        case malformedKey
        /// A key under 2048 bits.
        case keyTooSmall
        case messageTooLong
        /// The server's blind signature doesn't unblind to a valid signature.
        case invalidSignature
        /// A keys document or issuance answer that can't be used.
        case malformedResponse
        case randomFailure
    }

    /// RFC 9577's TokenChallenge for this issuer, with no redemption context
    /// and `purpose` as origin_info.
    public static func challenge(purpose: String) -> Data {
        var out = Data()
        out.appendBigEndian(tokenType)
        out.appendBigEndian(UInt16(issuerName.utf8.count))
        out.append(contentsOf: Array(issuerName.utf8))
        out.append(0) // redemption_context: empty
        out.appendBigEndian(UInt16(purpose.utf8.count))
        out.append(contentsOf: Array(purpose.utf8))
        return out
    }

    public static func challengeDigest(purpose: String) -> Data {
        Data(SHA256.hash(data: challenge(purpose: purpose)))
    }

    /// RFC 9577 §2.2's header value for spending `token`.
    public static func authorizationHeader(token: Data) -> String {
        "PrivateToken token=\"\(token.base64URLEncodedString())\""
    }

    // MARK: Keys

    /// One of the issuer's signing keys.
    public struct PublicKey: Equatable, Sendable {
        /// The SubjectPublicKeyInfo bytes, as the server publishes them.
        public let spki: Data
        /// token_key_id: SHA-256 of `spki` (RFC 9578 §6.5).
        public let id: Data
        let modulus: BlindRSAInteger
        let exponent: BlindRSAInteger
        let modulusLength: Int

        /// Reads a key encoded as RFC 9578 §6.5 requires: id-RSASSA-PSS with
        /// SHA-384, MGF1-SHA-384 and a 48-byte salt spelled out. Any other
        /// encoding is refused, so the phone can't be handed a key for another
        /// scheme, and a key under 2048 bits is refused too.
        public init(spki: Data) throws {
            var outer = DERReader(Data(spki))
            guard var body = outer.read(tag: 0x30), outer.isAtEnd,
                  body.readRaw(tag: 0x30) == PublicKey.algorithmIdentifier,
                  var bits = body.read(tag: 0x03), body.isAtEnd,
                  bits.readByte() == 0 // no unused bits
            else { throw Failure.malformedKey }
            var rsaKey = DERReader(bits.remaining)
            guard var numbers = rsaKey.read(tag: 0x30), rsaKey.isAtEnd,
                  let n = numbers.read(tag: 0x02), let e = numbers.read(tag: 0x02), numbers.isAtEnd
            else { throw Failure.malformedKey }
            try self.init(modulus: n.remaining, exponent: e.remaining)
            // Re-encoding must give the same bytes: that checks every length
            // and that the integers are minimally encoded.
            guard self.spki == spki else { throw Failure.malformedKey }
        }

        /// Builds the key from its big-endian modulus and public exponent.
        init(modulus: Data, exponent: Data) throws {
            let n = BlindRSAInteger(bigEndian: modulus)
            let e = BlindRSAInteger(bigEndian: exponent)
            guard n.bitWidth >= PrivacyPassToken.minimumModulusBits else { throw Failure.keyTooSmall }
            guard e > BlindRSAInteger(1), e.bitWidth <= 32 else { throw Failure.malformedKey }
            self.modulus = n
            self.exponent = e
            self.modulusLength = (n.bitWidth + 7) / 8
            let rsaPublicKey = DER.sequence(DER.integer(n) + DER.integer(e))
            let spki = DER.sequence(PublicKey.algorithmIdentifier + DER.element(0x03, Data([0]) + rsaPublicKey))
            self.spki = spki
            self.id = Data(SHA256.hash(data: spki))
        }

        /// AlgorithmIdentifier { id-RSASSA-PSS, { [0] SHA-384, [1] MGF1(SHA-384), [2] 48 } },
        /// the bytes RFC 9578's test vectors use.
        static let algorithmIdentifier = Data(hexString:
            "303d06092a864886f70d01010a3030a00d300b0609608648016503040202a11a301806092a864886f70d010108300b0609608648016503040202a203020130")
    }

    /// The server's `GET /api/v1/tokens/keys` document. The same bytes go to
    /// every phone, so a phone that compares notes can tell it wasn't handed a
    /// key of its own (which would let the server link its tokens).
    public struct Keys: Equatable, Sendable {
        public struct Entry: Equatable, Sendable {
            public let key: PublicKey
            public let notBefore: Date
            public let notAfter: Date
        }

        /// Newest first, as the server lists them; the first signs today.
        public let entries: [Entry]

        public init(document data: Data) throws {
            struct Document: Decodable {
                struct Key: Decodable {
                    let tokenKeyId: String
                    let publicKey: String
                    let notBefore: String
                    let notAfter: String
                }
                let schema: String
                let tokenType: Int
                let issuer: String
                let keys: [Key]
            }
            guard let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.schema == PrivacyPassToken.keysSchema,
                  document.tokenType == Int(PrivacyPassToken.tokenType),
                  document.issuer == PrivacyPassToken.issuerName,
                  !document.keys.isEmpty
            else { throw Failure.malformedResponse }
            let dates = ISO8601DateFormatter()
            entries = try document.keys.map { item in
                guard let spki = Data(base64Encoded: item.publicKey),
                      let notBefore = dates.date(from: item.notBefore),
                      let notAfter = dates.date(from: item.notAfter)
                else { throw Failure.malformedResponse }
                let key = try PublicKey(spki: spki)
                guard key.id.hexString == item.tokenKeyId.lowercased() else { throw Failure.malformedResponse }
                return Entry(key: key, notBefore: notBefore, notAfter: notAfter)
            }
        }

        /// The key to blind against now: the newest one whose month has begun.
        public func signingKey(at now: Date) -> PublicKey? {
            entries.first { $0.notBefore <= now && now < $0.notAfter }?.key
        }
    }

    // MARK: Issuance

    /// One token before issuance: the phone keeps it until the server's blind
    /// signature comes back. It holds the blinding inverse, so it must stay
    /// on the phone; only `blindedMessage` goes to the server.
    public struct Pending: Sendable {
        public let key: PublicKey
        public let nonce: Data
        public let challengeDigest: Data
        public let blindedMessage: Data
        let inverse: BlindRSAInteger
        let encodedMessage: BlindRSAInteger

        /// token_input: token_type, nonce, challenge_digest, token_key_id.
        public var tokenInput: Data {
            PrivacyPassToken.tokenInput(nonce: nonce, challengeDigest: challengeDigest, keyID: key.id)
        }

        /// RFC 9474 §4.4: unblinds the server's signature, checks it, and
        /// returns the token to spend.
        public func finish(blindSignature: Data) throws -> Data {
            try tokenInput + PrivacyPassToken.finalize(
                key: key, blindSignature: blindSignature, inverse: inverse, encodedMessage: encodedMessage)
        }
    }

    /// RFC 9474 §4.4: unblind, then check. A valid RSA signature raised to e
    /// gives back the encoded message the phone built, salt included, so
    /// comparing with it is the full PSS verification.
    static func finalize(key: PublicKey, blindSignature: Data, inverse: BlindRSAInteger,
                         encodedMessage: BlindRSAInteger) throws -> Data {
        guard blindSignature.count == key.modulusLength else { throw Failure.invalidSignature }
        let blinded = BlindRSAInteger(bigEndian: blindSignature)
        guard blinded < key.modulus else { throw Failure.invalidSignature }
        let signature = (blinded * inverse) % key.modulus
        guard signature.power(key.exponent, modulus: key.modulus) == encodedMessage,
              let bytes = signature.bigEndian(length: key.modulusLength)
        else { throw Failure.invalidSignature }
        return bytes
    }

    /// Prepares one token for `purpose`, blinded against `key`, with a fresh
    /// nonce, salt and blinding value.
    public static func prepare(key: PublicKey, purpose: String) throws -> Pending {
        var generator = SystemRandomNumberGenerator()
        let nonce = randomBytes(nonceLength, using: &generator)
        let salt = randomBytes(saltLength, using: &generator)
        // r uniform in [1, n) with an inverse: draw modulus-length values and
        // keep the first that fits.
        for _ in 0..<64 {
            var candidate = randomBytes(key.modulusLength, using: &generator)
            let excessBits = key.modulusLength * 8 - key.modulus.bitWidth
            candidate[0] &= UInt8(0xff >> excessBits)
            let r = BlindRSAInteger(bigEndian: candidate)
            guard !r.isZero, r < key.modulus, r.inverse(modulus: key.modulus) != nil else { continue }
            return try prepare(key: key, nonce: nonce, challengeDigest: challengeDigest(purpose: purpose), salt: salt, blind: r)
        }
        throw Failure.randomFailure
    }

    /// The deterministic core of `prepare`, for the RFC test vectors.
    static func prepare(key: PublicKey, nonce: Data, challengeDigest: Data, salt: Data, blind r: BlindRSAInteger) throws -> Pending {
        let input = tokenInput(nonce: nonce, challengeDigest: challengeDigest, keyID: key.id)
        let (blinded, inverse, encoded) = try blind(key: key, message: input, salt: salt, blind: r)
        return Pending(key: key, nonce: nonce, challengeDigest: challengeDigest,
                       blindedMessage: blinded, inverse: inverse, encodedMessage: encoded)
    }

    /// RFC 9474 §4.2 with the salt and blinding value given.
    static func blind(key: PublicKey, message: Data, salt: Data, blind r: BlindRSAInteger)
        throws -> (blinded: Data, inverse: BlindRSAInteger, encoded: BlindRSAInteger) {
        let encodedBytes = try encodePSS(message: message, emBits: key.modulus.bitWidth - 1, salt: salt)
        let encoded = BlindRSAInteger(bigEndian: encodedBytes)
        guard BlindRSAInteger.gcd(encoded, key.modulus) == BlindRSAInteger(1),
              let inverse = r.inverse(modulus: key.modulus) else { throw Failure.malformedKey }
        let blinded = (r.power(key.exponent, modulus: key.modulus) * encoded) % key.modulus
        guard let bytes = blinded.bigEndian(length: key.modulusLength) else { throw Failure.malformedKey }
        return (bytes, inverse, encoded)
    }

    /// The JSON body for `POST /api/v1/tokens` (attested; the caller signs it).
    public static func issuanceRequestBody(_ pending: [Pending]) throws -> Data {
        guard let key = pending.first?.key, pending.allSatisfy({ $0.key == key }) else { throw Failure.malformedKey }
        return try JSONSerialization.data(withJSONObject: [
            "tokenKeyId": key.id.hexString,
            "blindedMessages": pending.map { $0.blindedMessage.base64EncodedString() }
        ], options: [.sortedKeys])
    }

    /// Finishes each pending token with the matching signature from the
    /// server's answer to `issuanceRequestBody`.
    public static func finish(_ pending: [Pending], response data: Data) throws -> [Data] {
        struct Response: Decodable {
            let tokenKeyId: String
            let blindSignatures: [String]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let key = pending.first?.key,
              response.tokenKeyId.lowercased() == key.id.hexString,
              response.blindSignatures.count == pending.count
        else { throw Failure.malformedResponse }
        return try zip(pending, response.blindSignatures).map { item, encoded in
            guard let signature = Data(base64Encoded: encoded) else { throw Failure.malformedResponse }
            return try item.finish(blindSignature: signature)
        }
    }

    // MARK: Encoding

    static func tokenInput(nonce: Data, challengeDigest: Data, keyID: Data) -> Data {
        var out = Data()
        out.appendBigEndian(tokenType)
        return out + nonce + challengeDigest + keyID
    }

    /// EMSA-PSS-ENCODE (RFC 8017 §9.1.1) with SHA-384 and MGF1-SHA-384.
    static func encodePSS(message: Data, emBits: Int, salt: Data) throws -> Data {
        let hashLength = SHA384.byteCount
        let emLength = (emBits + 7) / 8
        guard emLength >= hashLength + salt.count + 2 else { throw Failure.messageTooLong }
        let messageHash = Data(SHA384.hash(data: message))
        let h = Data(SHA384.hash(data: Data(count: 8) + messageHash + salt))
        var db = Data(count: emLength - hashLength - 1)
        db[db.count - salt.count - 1] = 0x01
        db.replaceSubrange((db.count - salt.count)..<db.count, with: salt)
        let mask = mgf1SHA384(seed: h, length: db.count)
        for index in 0..<db.count { db[index] ^= mask[index] }
        db[0] &= UInt8(0xff >> (8 * emLength - emBits))
        return db + h + Data([0xbc])
    }

    static func mgf1SHA384(seed: Data, length: Int) -> Data {
        var out = Data()
        var counter: UInt32 = 0
        while out.count < length {
            var block = seed
            block.appendBigEndian(counter)
            out += Data(SHA384.hash(data: block))
            counter += 1
        }
        return out.prefix(length)
    }

    private static func randomBytes(_ count: Int, using generator: inout SystemRandomNumberGenerator) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

// MARK: - DER, only what RFC 9578's key encoding needs

private enum DER {
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes = withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
        while bytes.first == 0 { bytes.removeFirst() }
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }

    static func element(_ tag: UInt8, _ body: Data) -> Data { Data([tag]) + length(body.count) + body }
    static func sequence(_ body: Data) -> Data { element(0x30, body) }

    /// A positive INTEGER: minimal big-endian bytes, with a leading zero when
    /// the top bit is set.
    static func integer(_ value: BlindRSAInteger) -> Data {
        var bytes = value.bigEndian(length: max(1, (value.bitWidth + 7) / 8)) ?? Data([0])
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(0x02, bytes)
    }
}

private struct DERReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = Data(data)
        self.offset = 0
    }

    var isAtEnd: Bool { offset == data.count }
    var remaining: Data { data.subdata(in: offset..<data.count) }

    mutating func readByte() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    /// The whole element (tag, length and body) if it has `tag`.
    mutating func readRaw(tag: UInt8) -> Data? {
        let start = offset
        guard read(tag: tag) != nil else {
            offset = start
            return nil
        }
        return data.subdata(in: start..<offset)
    }

    /// The body of the next element, as a reader, if it has `tag`.
    mutating func read(tag: UInt8) -> DERReader? {
        let start = offset
        guard readByte() == tag, let first = readByte() else {
            offset = start
            return nil
        }
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7f)
            guard (1...4).contains(count) else {
                offset = start
                return nil
            }
            length = 0
            for _ in 0..<count {
                guard let byte = readByte() else {
                    offset = start
                    return nil
                }
                length = length << 8 | Int(byte)
            }
        }
        guard length <= data.count - offset else {
            offset = start
            return nil
        }
        defer { offset += length }
        return DERReader(data.subdata(in: offset..<(offset + length)))
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    init(hexString: String) {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
