#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
@testable import SessionKit
import XCTest

final class PrivacyPassTokenTests: XCTestCase {
    private func bytes(_ hex: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        var out = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                XCTFail("not hex", file: file, line: line)
                return Data()
            }
            out.append(byte)
            index = next
        }
        return Data(out)
    }

    // RFC 9474 A.1 and A.3: encoding, blinding and finalizing reproduce the
    // published bytes. The vectors give the blinding inverse, so r is its
    // inverse, which also checks BlindRSAInteger.inverse.
    func testRFC9474Vectors() throws {
        XCTAssertEqual(PrivacyPassVectors.blindRSA.count, 2)
        for vector in PrivacyPassVectors.blindRSA {
            let key = try PrivacyPassToken.PublicKey(modulus: bytes(vector.n), exponent: bytes(vector.e))
            let inverse = BlindRSAInteger(bigEndian: bytes(vector.inverse))
            let r = try XCTUnwrap(inverse.inverse(modulus: key.modulus), vector.name)
            XCTAssertEqual(r.inverse(modulus: key.modulus), inverse, vector.name)

            let (blinded, computedInverse, encoded) = try PrivacyPassToken.blind(
                key: key, message: bytes(vector.preparedMessage), salt: bytes(vector.salt), blind: r)
            XCTAssertEqual(encoded.bigEndian(length: key.modulusLength), bytes(vector.encodedMessage), vector.name)
            XCTAssertEqual(blinded, bytes(vector.blindedMessage), vector.name)
            XCTAssertEqual(computedInverse, inverse, vector.name)

            let signature = try PrivacyPassToken.finalize(
                key: key, blindSignature: bytes(vector.blindSignature), inverse: inverse, encodedMessage: encoded)
            XCTAssertEqual(signature, bytes(vector.signature), vector.name)

            var damaged = bytes(vector.blindSignature)
            damaged[damaged.count - 1] ^= 1
            XCTAssertThrowsError(try PrivacyPassToken.finalize(
                key: key, blindSignature: damaged, inverse: inverse, encodedMessage: encoded)) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .invalidSignature)
            }
        }
    }

    // RFC 9578 A.2: the key encoding and id, the token request and the final
    // token, for all five vectors.
    func testRFC9578Type2Vectors() throws {
        XCTAssertEqual(PrivacyPassVectors.tokenType2.count, 5)
        for (index, vector) in PrivacyPassVectors.tokenType2.enumerated() {
            let spki = bytes(vector.publicKey)
            let key = try PrivacyPassToken.PublicKey(spki: spki)
            XCTAssertEqual(key.spki, spki, "vector \(index)")
            XCTAssertEqual(key.id, Data(SHA256.hash(data: spki)), "vector \(index)")

            let token = bytes(vector.token)
            XCTAssertEqual(token.prefix(2), Data([0, 2]), "vector \(index)")
            let nonce = token.subdata(in: 2..<34)
            let digest = token.subdata(in: 34..<66)
            XCTAssertEqual(digest, Data(SHA256.hash(data: bytes(vector.tokenChallenge))), "vector \(index)")
            XCTAssertEqual(token.subdata(in: 66..<98), key.id, "vector \(index)")

            let pending = try PrivacyPassToken.prepare(
                key: key, nonce: nonce, challengeDigest: digest,
                salt: bytes(vector.salt), blind: BlindRSAInteger(bigEndian: bytes(vector.blind)))
            let request = bytes(vector.tokenRequest)
            XCTAssertEqual(request.prefix(2), Data([0, 2]), "vector \(index)")
            XCTAssertEqual(request[request.startIndex + 2], key.id.last, "vector \(index): truncated key id")
            XCTAssertEqual(pending.blindedMessage, request.dropFirst(3), "vector \(index)")
            XCTAssertEqual(try pending.finish(blindSignature: bytes(vector.tokenResponse)), token, "vector \(index)")

            // The same through the server's issuance answer.
            let idHex = key.id.map { String(format: "%02x", $0) }.joined()
            let response = Data(#"{"tokenKeyId":"\#(idHex)","blindSignatures":["\#(bytes(vector.tokenResponse).base64EncodedString())"]}"#.utf8)
            XCTAssertEqual(try PrivacyPassToken.finish([pending], response: response), [token], "vector \(index)")
        }
    }

    // The key must be RFC 9578's exact encoding of a key of at least 2048 bits.
    func testKeyEncodingIsStrict() throws {
        let spki = bytes(PrivacyPassVectors.tokenType2[0].publicKey)
        var plainRSA = spki
        // id-RSASSA-PSS (…01 01 0a) becomes rsaEncryption (…01 01 01).
        let oidEnd = try XCTUnwrap(plainRSA.range(of: Data([0x01, 0x01, 0x0a])))
        plainRSA[oidEnd.upperBound - 1] = 0x01
        var trailing = spki
        trailing.append(0)
        for (name, bad) in [("plain rsaEncryption", plainRSA), ("trailing byte", trailing), ("truncated", spki.prefix(100))] {
            XCTAssertThrowsError(try PrivacyPassToken.PublicKey(spki: Data(bad)), name) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedKey, name)
            }
        }
        let large = Data([0xc3] + [UInt8](repeating: 0x55, count: 1023)) // 8192 bits
        XCTAssertThrowsError(try PrivacyPassToken.PublicKey(modulus: large, exponent: Data([1, 0, 1]))) {
            XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedKey)
        }
        let small = Data([0xc3] + [UInt8](repeating: 0x55, count: 127)) // 1024 bits
        XCTAssertThrowsError(try PrivacyPassToken.PublicKey(modulus: small, exponent: Data([1, 0, 1]))) {
            XCTAssertEqual($0 as? PrivacyPassToken.Failure, .keyTooSmall)
        }
        let key = try PrivacyPassToken.PublicKey(spki: spki)
        XCTAssertThrowsError(try PrivacyPassToken.encodePSS(message: Data(), emBits: 8 * 90, salt: Data(count: 48))) {
            XCTAssertEqual($0 as? PrivacyPassToken.Failure, .messageTooLong)
        }
        XCTAssertNoThrow(try PrivacyPassToken.encodePSS(message: Data(), emBits: key.modulus.bitWidth - 1, salt: Data(count: 48)))
    }

    // Fresh blinding values unblind correctly. The server's answer to
    // r^e * m is r * sig, so RFC 9474 A.3's signature stands in for the
    // server without its private key.
    func testFreshBlindingFinishes() throws {
        let vector = PrivacyPassVectors.blindRSA[1]
        let key = try PrivacyPassToken.PublicKey(modulus: bytes(vector.n), exponent: bytes(vector.e))
        let signature = BlindRSAInteger(bigEndian: bytes(vector.signature))
        var nonces = Set<Data>(), blindedMessages = Set<Data>()
        for _ in 0..<2 {
            let pending = try PrivacyPassToken.prepare(key: key, purpose: PrivacyPassToken.mapsPurpose)
            XCTAssertEqual(pending.challengeDigest, PrivacyPassToken.challengeDigest(purpose: "maps"))
            XCTAssertEqual(pending.blindedMessage.count, key.modulusLength)
            nonces.insert(pending.nonce)
            blindedMessages.insert(pending.blindedMessage)

            // Same message and salt as the vector, fresh r.
            var bytesR = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
            bytesR[0] |= 1
            let r = BlindRSAInteger(bigEndian: bytesR)
            let (blinded, inverse, encoded) = try PrivacyPassToken.blind(
                key: key, message: bytes(vector.preparedMessage), salt: bytes(vector.salt), blind: r)
            XCTAssertNotEqual(blinded, bytes(vector.blindedMessage))
            let answer = try XCTUnwrap(((r * signature) % key.modulus).bigEndian(length: key.modulusLength))
            XCTAssertEqual(try PrivacyPassToken.finalize(
                key: key, blindSignature: answer, inverse: inverse, encodedMessage: encoded), bytes(vector.signature))
            // Another token's answer doesn't finish this one.
            XCTAssertThrowsError(try pending.finish(blindSignature: answer)) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .invalidSignature)
            }
        }
        XCTAssertEqual(nonces.count, 2, "each token gets a fresh nonce")
        XCTAssertEqual(blindedMessages.count, 2, "each token gets a fresh blind")

        // With the nonce and salt fixed, two random blinds still differ, so
        // the server can't recognise a token request it saw before.
        var rs = Set<Data>()
        for _ in 0..<2 {
            let r = try PrivacyPassToken.randomBlind(for: key)
            rs.insert(try PrivacyPassToken.blind(key: key, message: Data([1]), salt: Data(count: 48), blind: r).blinded)
        }
        XCTAssertEqual(rs.count, 2)
    }

    // Pinned against the Go server's tokens.Challenge("maps") and its
    // ChallengeDigest, so both sides name the same issuer and purpose.
    func testChallengeMatchesTheServer() {
        XCTAssertEqual(PrivacyPassToken.challenge(purpose: "maps").count, 48)
        XCTAssertEqual(PrivacyPassToken.challengeDigest(purpose: "maps"), bytes(Self.serverMapsChallengeDigest))
        XCTAssertNotEqual(PrivacyPassToken.challengeDigest(purpose: "maps"), PrivacyPassToken.challengeDigest(purpose: "bridge"))
    }

    func testKeysDocumentAndIssuanceMessages() throws {
        let spki = bytes(PrivacyPassVectors.tokenType2[0].publicKey)
        let id = Data(SHA256.hash(data: spki)).map { String(format: "%02x", $0) }.joined()
        func document(id: String = id, issuer: String = PrivacyPassToken.issuerName) -> Data {
            Data("""
            {"issuer":"\(issuer)","keys":[{"notAfter":"2026-12-01T00:00:00Z","notBefore":"2026-10-01T00:00:00Z",\
            "publicKey":"\(spki.base64EncodedString())","tokenKeyId":"\(id)"}],\
            "schema":"spokenmargins.token-keys.v1","tokenType":2}
            """.utf8)
        }
        let keys = try PrivacyPassToken.Keys(document: document())
        let october = ISO8601DateFormatter().date(from: "2026-10-03T18:00:00Z")!
        XCTAssertEqual(keys.signingKey(at: october)?.spki, spki)
        XCTAssertNil(keys.signingKey(at: ISO8601DateFormatter().date(from: "2026-12-02T00:00:00Z")!))
        var withFutureKey = try XCTUnwrap(JSONSerialization.jsonObject(with: document()) as? [String: Any])
        var entries = try XCTUnwrap(withFutureKey["keys"] as? [[String: Any]])
        entries.insert(["tokenKeyId": "ab", "publicKey": "AAAA", "notBefore": "2026-11-01T00:00:00Z",
                        "notAfter": "2027-01-01T00:00:00Z"], at: 0)
        withFutureKey["keys"] = entries
        let skipped = try PrivacyPassToken.Keys(document: JSONSerialization.data(withJSONObject: withFutureKey))
        XCTAssertEqual(skipped.entries.map(\.key.spki), [spki], "an unreadable entry is skipped, not fatal")
        for bad in [document(id: String(repeating: "0", count: 64)), document(issuer: "example.org"), Data("{}".utf8)] {
            XCTAssertThrowsError(try PrivacyPassToken.Keys(document: bad)) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedResponse)
            }
        }

        let key = try XCTUnwrap(keys.signingKey(at: october))
        let pending = try (0..<2).map { _ in try PrivacyPassToken.prepare(key: key, purpose: "maps") }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: PrivacyPassToken.issuanceRequestBody(pending)) as? [String: Any])
        XCTAssertEqual(body["tokenKeyId"] as? String, id)
        XCTAssertEqual(body["blindedMessages"] as? [String], pending.map { $0.blindedMessage.base64EncodedString() })
        let wrongKey = Data(#"{"tokenKeyId":"00","blindSignatures":["",""]}"#.utf8)
        XCTAssertThrowsError(try PrivacyPassToken.finish(pending, response: wrongKey)) {
            XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedResponse)
        }
    }

    // MARK: Key selection and parse guards

    /// The key document lists keys newest first. The phone blinds against the first whose month has
    /// begun and not ended. A key that is not yet valid must never be used: every phone is handed the
    /// same document, and a phone that blinded against a key of its own choosing would let the server
    /// link its tokens to it.
    func testSigningKeyIsTheFirstWhoseMonthHasBegunAndNotEnded() throws {
        let october = PrivacyPassVectors.tokenType2[0]
        let keyOctober = try PrivacyPassToken.PublicKey(spki: bytes(october.publicKey))
        let vector = PrivacyPassVectors.blindRSA[1]
        let keyNovember = try PrivacyPassToken.PublicKey(modulus: bytes(vector.n), exponent: bytes(vector.e))
        func keyID(_ key: PrivacyPassToken.PublicKey) -> String { key.id.map { String(format: "%02x", $0) }.joined() }
        let document = Data("""
        {"issuer":"\(PrivacyPassToken.issuerName)","keys":[\
        {"notAfter":"2027-01-01T00:00:00Z","notBefore":"2026-11-01T00:00:00Z",\
        "publicKey":"\(keyNovember.spki.base64EncodedString())","tokenKeyId":"\(keyID(keyNovember))"},\
        {"notAfter":"2026-12-01T00:00:00Z","notBefore":"2026-10-01T00:00:00Z",\
        "publicKey":"\(keyOctober.spki.base64EncodedString())","tokenKeyId":"\(keyID(keyOctober))"}],\
        "schema":"spokenmargins.token-keys.v1","tokenType":2}
        """.utf8)
        let keys = try PrivacyPassToken.Keys(document: document)
        XCTAssertEqual(keys.entries.count, 2)
        func signing(at time: String) -> Data? {
            ISO8601DateFormatter().date(from: time).flatMap { keys.signingKey(at: $0)?.spki }
        }
        XCTAssertNil(signing(at: "2026-09-30T23:59:59Z"), "before every key's month")
        XCTAssertEqual(signing(at: "2026-10-03T18:00:00Z"), keyOctober.spki, "November's key has not begun, so it must not sign")
        XCTAssertEqual(signing(at: "2026-11-01T00:00:00Z"), keyNovember.spki, "a month begins at its notBefore instant")
        XCTAssertEqual(signing(at: "2026-11-20T00:00:00Z"), keyNovember.spki, "both are valid: the first listed (newest) signs")
        XCTAssertEqual(signing(at: "2026-12-15T00:00:00Z"), keyNovember.spki, "October's key has ended")
        XCTAssertNil(signing(at: "2027-01-01T00:00:00Z"), "a month ends at its notAfter instant")
    }

    /// A document for another schema or another token type is not this issuer's key list, even when
    /// everything else in it is valid.
    func testKeysDocumentOfAnotherSchemaOrTokenTypeIsRefused() throws {
        let spki = bytes(PrivacyPassVectors.tokenType2[0].publicKey)
        let id = Data(SHA256.hash(data: spki)).map { String(format: "%02x", $0) }.joined()
        func document(schema: String = PrivacyPassToken.keysSchema, tokenType: Int = Int(PrivacyPassToken.tokenType)) -> Data {
            Data("""
            {"issuer":"\(PrivacyPassToken.issuerName)","keys":[{"notAfter":"2026-12-01T00:00:00Z","notBefore":"2026-10-01T00:00:00Z",\
            "publicKey":"\(spki.base64EncodedString())","tokenKeyId":"\(id)"}],\
            "schema":"\(schema)","tokenType":\(tokenType)}
            """.utf8)
        }
        XCTAssertNoThrow(try PrivacyPassToken.Keys(document: document()), "the unmodified document is accepted")
        for (name, bad) in [
            ("schema", document(schema: "spokenmargins.token-keys.v2")),
            ("token type", document(tokenType: 3))
        ] {
            XCTAssertThrowsError(try PrivacyPassToken.Keys(document: bad), name) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedResponse, name)
            }
        }
    }

    /// RFC 9578 gives one encoding of a key, so a key that decodes to the same numbers with a padded
    /// integer is refused: the phone compares key ids, and two spellings of one key would have two ids.
    func testKeyWithAPaddedExponentIsRefusedButTheSameKeyInItsMinimalFormIsAccepted() throws {
        let vector = PrivacyPassVectors.blindRSA[1]
        let modulus = bytes(vector.n)
        let reference = try PrivacyPassToken.PublicKey(modulus: modulus, exponent: bytes(vector.e))

        func der(_ tag: UInt8, _ body: Data) -> Data {
            let length = body.count < 0x80 ? Data([UInt8(body.count)])
                : body.count < 0x100 ? Data([0x81, UInt8(body.count)])
                : Data([0x82, UInt8(body.count >> 8), UInt8(body.count & 0xff)])
            return Data([tag]) + length + body
        }
        func spki(exponent: [UInt8]) -> Data {
            // SubjectPublicKeyInfo { rsaEncryption-PSS algorithm, BIT STRING { RSAPublicKey { n, e } } }
            let rsaKey = der(0x30, der(0x02, Data([0]) + modulus) + der(0x02, Data(exponent)))
            return der(0x30, PrivacyPassToken.PublicKey.algorithmIdentifier + der(0x03, Data([0]) + rsaKey))
        }

        let minimal = spki(exponent: [0x01, 0x00, 0x01])
        XCTAssertEqual(minimal, reference.spki, "the byte-built key is the library's own encoding")
        XCTAssertEqual(try PrivacyPassToken.PublicKey(spki: minimal), reference)

        XCTAssertThrowsError(try PrivacyPassToken.PublicKey(spki: spki(exponent: [0x00, 0x01, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedKey)
        }
    }

    /// The public exponent must be an odd number above 1 that fits 32 bits, which keeps out a key
    /// whose "encryption" is the identity (e = 1) and an exponent built to make verification slow.
    func testPublicExponentOfOneOrMoreThan32BitsIsRefused() throws {
        let vector = PrivacyPassVectors.blindRSA[1]
        let modulus = bytes(vector.n)
        XCTAssertNoThrow(try PrivacyPassToken.PublicKey(modulus: modulus, exponent: Data([1, 0, 1])))
        for (name, exponent) in [("e = 1", Data([1])), ("e = 0", Data([0])), ("a 40-bit exponent", Data([1, 0, 0, 0, 1]))] {
            XCTAssertThrowsError(try PrivacyPassToken.PublicKey(modulus: modulus, exponent: exponent), name) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedKey, name)
            }
        }
    }

    /// The server answers with one blind signature per blinded message. An answer with a different
    /// count is refused whole. Zipping would instead hand back fewer tokens than were asked for, or
    /// ignore the extra, and the shortfall would go unnoticed until a spend failed.
    func testIssuanceAnswerWithTheWrongNumberOfSignaturesIsRefused() throws {
        let vector = PrivacyPassVectors.tokenType2[0]
        let key = try PrivacyPassToken.PublicKey(spki: bytes(vector.publicKey))
        let token = bytes(vector.token)
        // The RFC's own token: its blinding values are known, so its server answer is a valid signature.
        let known = try PrivacyPassToken.prepare(
            key: key, nonce: token.subdata(in: 2..<34), challengeDigest: token.subdata(in: 34..<66),
            salt: bytes(vector.salt), blind: BlindRSAInteger(bigEndian: bytes(vector.blind)))
        let other = try PrivacyPassToken.prepare(key: key, purpose: PrivacyPassToken.mapsPurpose)
        let answer = bytes(vector.tokenResponse).base64EncodedString()
        func response(_ signatures: [String]) -> Data {
            let id = key.id.map { String(format: "%02x", $0) }.joined()
            return Data(#"{"tokenKeyId":"\#(id)","blindSignatures":[\#(signatures.map { "\"\($0)\"" }.joined(separator: ","))]}"#.utf8)
        }

        XCTAssertEqual(try PrivacyPassToken.finish([known], response: response([answer])), [token], "one signature for one request")
        for (name, pending, signatures) in [
            ("fewer signatures than requests", [known, other], [answer]),
            ("more signatures than requests", [known], [answer, answer]),
            ("no signatures", [known], [])
        ] {
            XCTAssertThrowsError(try PrivacyPassToken.finish(pending, response: response(signatures)), name) {
                XCTAssertEqual($0 as? PrivacyPassToken.Failure, .malformedResponse, name)
            }
        }
    }

    func testAuthorizationHeader() {
        let token = Data([0xfb, 0xff, 0x00, 0x3e])
        XCTAssertEqual(PrivacyPassToken.authorizationHeader(token: token), #"PrivateToken token="-_8APg""#)
    }

    func testBlindRSAIntegerArithmetic() {
        let a = BlindRSAInteger(bigEndian: Data([0x01] + [UInt8](repeating: 0, count: 16))) // 2^128
        let b = BlindRSAInteger(UInt64.max)
        XCTAssertEqual((a - BlindRSAInteger(1)).bigEndian(length: 16), Data(repeating: 0xff, count: 16))
        XCTAssertEqual((b * b + b + b + BlindRSAInteger(1)), a) // (2^64 - 1)^2 + 2(2^64 - 1) + 1 = 2^128
        let (q, r) = (a + BlindRSAInteger(5)).quotientAndRemainder(dividingBy: b)
        XCTAssertEqual(q * b + r, a + BlindRSAInteger(5))
        XCTAssertTrue(r < b)
        XCTAssertEqual(BlindRSAInteger(3).power(BlindRSAInteger(200), modulus: BlindRSAInteger(1_000_000_007)),
                       BlindRSAInteger(3).power(BlindRSAInteger(100), modulus: BlindRSAInteger(1_000_000_007))
                           .power(BlindRSAInteger(2), modulus: BlindRSAInteger(1_000_000_007)))
        XCTAssertNil(BlindRSAInteger(6).inverse(modulus: BlindRSAInteger(9)))
        XCTAssertEqual(BlindRSAInteger(3).inverse(modulus: BlindRSAInteger(11)), BlindRSAInteger(4))
        XCTAssertNil(BlindRSAInteger(bigEndian: Data([1, 0])).bigEndian(length: 1))
    }

    /// Go: hex(tokens.ChallengeDigest("maps")) on the server (PR #740).
    static let serverMapsChallengeDigest = "3a17e0cd3c68e5199b333ebcd525581662154f99f14f3f56953164e740ed28fc"
}
