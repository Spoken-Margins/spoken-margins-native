#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// A club's phone-side secrets, sealing and invite link (#1799, `docs/design/club-mailbox.md` sections 2 and 5).
final class ClubSealingTests: XCTestCase {
    private let packet = Data("PK\u{3}\u{4}a packet's exact bytes".utf8) + Data((0...255).map { UInt8($0) })

    // MARK: Derivation

    func testTheFourValuesComeFromTheSecretAndOnlyFromIt() {
        let key = ClubSealing.Key.random()
        let first = ClubSealing.Credentials(key: key)
        let second = ClubSealing.Credentials(key: key)
        XCTAssertEqual(first, second)
        let other = ClubSealing.Credentials(key: .random())
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertNotEqual(first.readProof, other.readProof)
        XCTAssertNotEqual(first.sealKey, other.sealKey)
    }

    func testTheFourValuesAreIndependentAndTheRightLength() {
        let credentials = ClubSealing.Credentials(key: .random())
        XCTAssertEqual(credentials.id.count, 32)
        XCTAssertEqual(credentials.readProof.count, 64)
        XCTAssertEqual(credentials.postProof.count, 64)
        XCTAssertEqual(credentials.readHash.count, 64)
        XCTAssertEqual(credentials.sealKey.count, 32)
        for value in [credentials.id, credentials.readProof, credentials.postProof, credentials.readHash, credentials.postHash] {
            XCTAssertTrue(value.allSatisfy { "0123456789abcdef".contains($0) }, "\(value) is lowercase hex")
        }
        // The server is given the hashes and must never be able to use one as a proof or the key.
        let all = [credentials.id, credentials.readProof, credentials.postProof, credentials.readHash, credentials.postHash,
                   ClubSealing.Credentials.hex(credentials.sealKey)]
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(credentials.readHash, ClubSealing.Credentials.hex(Data(SHA256.hash(data: Data(hexString: credentials.readProof)!))))
        XCTAssertFalse(credentials.readProof.contains(credentials.id))
    }

    // MARK: Sealing

    func testAPostOpensToTheExactPacketAndTheServerSeesNoPlaintext() throws {
        let credentials = ClubSealing.Credentials(key: .random())
        let sealed = try ClubSealing.seal(packet, as: .post, in: credentials)
        XCTAssertEqual(sealed.count, packet.count + ClubSealing.overheadByteCount)
        XCTAssertNil(sealed.range(of: Data("a packet's exact bytes".utf8)))
        XCTAssertEqual(try ClubSealing.open(sealed, as: .post, in: credentials), packet)
    }

    func testEachSealUsesAFreshNonce() throws {
        let credentials = ClubSealing.Credentials(key: .random())
        XCTAssertNotEqual(
            try ClubSealing.seal(packet, as: .post, in: credentials),
            try ClubSealing.seal(packet, as: .post, in: credentials)
        )
    }

    func testAPostDoesNotOpenInAnotherClubUnderAnotherKeyOrAsTheHeader() throws {
        let credentials = ClubSealing.Credentials(key: .random())
        let sealed = try ClubSealing.seal(packet, as: .post, in: credentials)
        // Another club.
        assertDamaged(try ClubSealing.open(sealed, as: .post, in: ClubSealing.Credentials(key: .random())))
        // The club's id is in the additional data, so the server cannot move a post to another club even when
        // both clubs seal under one key: with the right seal key, only the right id opens it.
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: sealed.dropFirst(8).prefix(12)),
            ciphertext: sealed.dropFirst(20).dropLast(16),
            tag: sealed.suffix(16)
        )
        let sealKey = SymmetricKey(data: credentials.sealKey)
        XCTAssertNoThrow(try AES.GCM.open(box, using: sealKey, authenticating: ClubSealing.headerBytes(for: .post) + credentials.idBytes))
        XCTAssertThrowsError(try AES.GCM.open(box, using: sealKey, authenticating: ClubSealing.headerBytes(for: .post) + Data(repeating: 9, count: 16)))
        XCTAssertThrowsError(try AES.GCM.open(box, using: sealKey, authenticating: ClubSealing.headerBytes(for: .post)))
        // A post passed off as the header, and the header as a post.
        assertDamaged(try ClubSealing.open(sealed, as: .header, in: credentials))
        let header = try ClubSealing.seal(Data("{}".utf8), as: .header, in: credentials)
        assertDamaged(try ClubSealing.open(header, as: .post, in: credentials))
    }

    func testAnyTamperedByteFailsPlainly() throws {
        let credentials = ClubSealing.Credentials(key: .random())
        let sealed = try ClubSealing.seal(packet, as: .post, in: credentials)
        for index in [0, 5, 6, 7, 8, 19, 20, sealed.count / 2, sealed.count - 1] {
            var tampered = sealed
            tampered[index] ^= 0x01
            assertDamaged(try ClubSealing.open(tampered, as: .post, in: credentials), "byte \(index)")
        }
    }

    func testATruncatedBlobFailsPlainly() throws {
        let credentials = ClubSealing.Credentials(key: .random())
        let sealed = try ClubSealing.seal(packet, as: .post, in: credentials)
        for length in [0, 1, 8, 20, 35, 36, sealed.count - 1] {
            assertDamaged(try ClubSealing.open(sealed.prefix(length), as: .post, in: credentials), "length \(length)")
        }
        // The shortest valid blob is an empty plaintext: header, nonce, tag.
        let empty = try ClubSealing.seal(Data(), as: .post, in: credentials)
        XCTAssertEqual(empty.count, ClubSealing.overheadByteCount)
        XCTAssertEqual(try ClubSealing.open(empty, as: .post, in: credentials), Data())
    }

    // MARK: The header

    func testTheHeaderKeepsTheNameAndLabelAndTheCreatorAndJoinerAgree() throws {
        let invite = ClubInvite.random()
        let header = try XCTUnwrap(ClubHeader(name: "  Tuesday Night Book Club ☕ ", creatorLabel: " Dana "))
        let sealed = try invite.sealedHeader(header)
        XCTAssertNil(sealed.range(of: Data("Tuesday".utf8)), "the server cannot read the club's name")
        // The joiner builds the invite from the link alone.
        let joiner = try XCTUnwrap(inviteFromLink(invite))
        let opened = try joiner.openHeader(sealed)
        XCTAssertEqual(opened.name, "Tuesday Night Book Club ☕")
        XCTAssertEqual(opened.creatorLabel, "Dana")
    }

    func testAHeaderTable() {
        XCTAssertNil(ClubHeader(name: ""))
        XCTAssertNil(ClubHeader(name: "   \n\t "))
        XCTAssertEqual(ClubHeader(name: "Club", creatorLabel: "  ")?.creatorLabel, nil)
        XCTAssertEqual(ClubHeader(name: "Club", creatorLabel: nil)?.creatorLabel, nil)
        XCTAssertEqual(ClubHeader(name: String(repeating: "é", count: 500))?.name.unicodeScalars.count, ClubHeader.maximumNameScalars)
        XCTAssertEqual(ClubHeader(name: "Club", creatorLabel: String(repeating: "x", count: 500))?.creatorLabel?.count, ClubHeader.maximumLabelScalars)
        // A cut never ends on a space or splits a scalar.
        let cut = ClubHeader(name: String(repeating: "a", count: 99) + " b")
        XCTAssertEqual(cut?.name, String(repeating: "a", count: 99))
        // The biggest header stays well inside the server's 16 KiB for a sealed header.
        let biggest = ClubHeader(name: String(repeating: "\u{1F600}", count: 500), creatorLabel: String(repeating: "\u{1F600}", count: 500))!
        XCTAssertLessThan((try? biggest.encoded().count) ?? .max, ClubClient.maximumHeaderBytes - ClubSealing.overheadByteCount)
    }

    func testAHeaderThatIsNotAClubHeaderDoesNotOpenAsOne() throws {
        let invite = ClubInvite.random()
        for json in [#"{}"#, #"{"schema":"spokenmargins.club-header.v1"}"#,
                     #"{"schema":"spokenmargins.club-header.v1","name":""}"#,
                     #"{"schema":"other","name":"Club"}"#, #"not json"#,
                     #"{"schema":"spokenmargins.club-header.v1","name":" Club "}"#] {
            let sealed = try ClubSealing.seal(Data(json.utf8), as: .header, in: invite.credentials)
            XCTAssertThrowsError(try invite.openHeader(sealed), json) { error in
                XCTAssertEqual(error as? ClubSealing.Failure, .incompleteOrDamaged)
            }
        }
    }

    // MARK: Invite links

    func testALinkRoundTripsAndNamesTheClubItOpens() throws {
        let invite = ClubInvite.random()
        let url = invite.url()
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, ProductServer.productionHost)
        XCTAssertEqual(url.path, "/c/\(invite.id)")
        XCTAssertEqual(url.fragment, invite.key.fragment)
        XCTAssertEqual(ClubInvite.parse(url), .invite(invite))
        // The new host and the old one both open it.
        XCTAssertEqual(ClubInvite.parse(invite.url(host: "spokenmargins.com")), .invite(invite))
    }

    func testALinkTable() throws {
        let invite = ClubInvite.random()
        let id = invite.id
        let fragment = invite.key.fragment
        let host = ProductServer.productionHost
        let other = ClubInvite.random()
        let cases: [(String, ClubInvite.Parsed)] = [
            // Not a club link: left for other handlers.
            ("https://\(host)/l/\(id)#\(fragment)", .notAClubLink),
            ("https://\(host)/c/\(id)/extra#\(fragment)", .notAClubLink),
            ("https://\(host)/c#\(fragment)", .notAClubLink),
            ("https://\(host)/c/#\(fragment)", .notAClubLink),
            ("https://\(host)/c/\(id.uppercased())#\(fragment)", .notAClubLink),
            ("https://\(host)/c/\(String(id.dropLast()))#\(fragment)", .notAClubLink),
            ("https://\(host)/c/\(id)0#\(fragment)", .notAClubLink),
            ("https://\(host)/c/not-an-id#\(fragment)", .notAClubLink),
            ("http://\(host)/c/\(id)#\(fragment)", .notAClubLink),
            ("https://example.com/c/\(id)#\(fragment)", .notAClubLink),
            ("https://\(host).evil.example/c/\(id)#\(fragment)", .notAClubLink),
            ("https://user@\(host)/c/\(id)#\(fragment)", .notAClubLink),
            ("https://\(host):8443/c/\(id)#\(fragment)", .notAClubLink),
            // A club link that cannot open: damaged, never a guess.
            ("https://\(host)/c/\(id)", .incompleteOrDamaged),
            ("https://\(host)/c/\(id)#", .incompleteOrDamaged),
            ("https://\(host)/c/\(id)#not-a-key", .incompleteOrDamaged),
            ("https://\(host)/c/\(id)#\(String(fragment.dropLast()))", .incompleteOrDamaged),
            // The path names one club and the key opens another.
            ("https://\(host)/c/\(other.id)#\(fragment)", .incompleteOrDamaged),
            // Padding on the key is allowed, as for share links.
            ("https://\(host)/c/\(id)#\(fragment)=", .invite(invite)),
            ("https://spokenmargins.com/c/\(id)#\(fragment)", .invite(invite))
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ClubInvite.parse(try XCTUnwrap(URL(string: text), text)), expected, text)
        }
    }

    // MARK: The vector the Go server's tests also check

    func testTheSharedVectorMatchesByteForByte() throws {
        let vector = try Vector.load()
        let key = try XCTUnwrap(ClubSealing.Key(fragment: vector.keyFragment))
        let invite = ClubInvite(key: key)
        let credentials = invite.credentials
        XCTAssertEqual(credentials.id, vector.id)
        XCTAssertEqual(credentials.readProof, vector.readProof)
        XCTAssertEqual(credentials.postProof, vector.postProof)
        XCTAssertEqual(credentials.readHash, vector.readHash)
        XCTAssertEqual(credentials.postHash, vector.postHash)
        XCTAssertEqual(ClubSealing.Credentials.hex(credentials.sealKey), vector.sealKeyHex)
        XCTAssertEqual(ClubInvite.parse(try XCTUnwrap(URL(string: vector.inviteURL))), .invite(invite))
        XCTAssertEqual(invite.url().absoluteString, vector.inviteURL)

        for (item, entry) in [(ClubSealing.Item.header, vector.header)] + vector.posts.map { (ClubSealing.Item.post, $0) } {
            let plaintext = try XCTUnwrap(Data(base64Encoded: entry.plaintextBase64))
            let sealed = try XCTUnwrap(Data(base64Encoded: entry.sealedBase64))
            XCTAssertEqual(ClubSealing.Credentials.hex(ClubSealing.associatedData(for: item, in: credentials)), entry.aadHex)
            let nonce = try AES.GCM.Nonce(data: try XCTUnwrap(Data(hexString: entry.nonceHex)))
            XCTAssertEqual(try ClubSealing.seal(plaintext, as: item, in: credentials, nonce: nonce), sealed, "seal")
            XCTAssertEqual(try ClubSealing.open(sealed, as: item, in: credentials), plaintext, "open")
        }
        // The header's plaintext is what this build writes for the same words.
        let header = try XCTUnwrap(ClubHeader(name: "Tuesday Night Book Club ☕", creatorLabel: "Dana"))
        XCTAssertEqual(try header.encoded(), Data(base64Encoded: vector.header.plaintextBase64))
        XCTAssertEqual(try invite.openHeader(try XCTUnwrap(Data(base64Encoded: vector.header.sealedBase64))), header)
    }

    // MARK: A real packet

    func testARealPacketComesBackByteIdentical() throws {
        let url = try TestInputs.url(.contracts, "fixtures/web-packets/web-written.spokenmargins")
        let bytes = try Data(contentsOf: url)
        let credentials = ClubSealing.Credentials(key: .random())
        let sealed = try ClubSealing.seal(bytes, as: .post, in: credentials)
        XCTAssertEqual(try ClubSealing.open(sealed, as: .post, in: credentials), bytes, "what a friend imports is the file the sender made")
    }

    // MARK: Helpers

    private func inviteFromLink(_ invite: ClubInvite) -> ClubInvite? {
        guard case .invite(let parsed) = ClubInvite.parse(invite.url()) else { return nil }
        return parsed
    }

    private func assertDamaged(_ expression: @autoclosure () throws -> Data, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
            XCTAssertEqual(error as? ClubSealing.Failure, .incompleteOrDamaged, message, file: file, line: line)
        }
    }

    private struct Vector: Decodable {
        struct Entry: Decodable {
            let nonceHex: String
            let aadHex: String
            let plaintextBase64: String
            let sealedBase64: String
        }

        let keyFragment: String
        let inviteURL: String
        let id: String
        let readProof: String
        let postProof: String
        let readHash: String
        let postHash: String
        let sealKeyHex: String
        let header: Entry
        let posts: [Entry]

        static func load() throws -> Vector {
            try JSONDecoder().decode(Vector.self, from: TestInputs.data(.research, "B4/contracts/fixtures/club-sealing-vector.json"))
        }
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
