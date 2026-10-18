#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// Share links are sealed on the phone and the key rides only in the link's `#` part (#805).
final class ShareLinkSealingTests: XCTestCase {
    private let packet = Data("PK\u{3}\u{4}a packet's exact bytes".utf8) + Data((0...255).map { UInt8($0) })
    private let preview = Data(#"{"schema":"spokenmargins.link-preview.v1","margins":[{"text":"Hear this 🎧"}]}"#.utf8)

    // MARK: Round trip

    func testASealedLinkOpensToTheExactPacketAndPreview() throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)

        let opened = try ShareLinkSealing.open(sealed, key: key)

        XCTAssertEqual(opened.packet, packet, "the opened packet must be byte-identical to the file share")
        XCTAssertEqual(opened.preview, preview)
    }

    func testTheServerSeesNoPlaintext() throws {
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: .random())
        for blob in [sealed.preview, sealed.packet] {
            XCTAssertNil(blob.range(of: Data("Hear this".utf8)))
            XCTAssertNil(blob.range(of: Data("a packet's exact bytes".utf8)))
            XCTAssertNil(blob.range(of: Data("link-preview".utf8)))
        }
    }

    func testEachSealUsesAFreshNonce() throws {
        let key = ShareLinkSealing.Key.random()
        let first = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        let second = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        XCTAssertNotEqual(first.packet, second.packet)
        XCTAssertNotEqual(first.preview, second.preview)
        XCTAssertNotEqual(ShareLinkSealing.Key.random(), ShareLinkSealing.Key.random())
    }

    // MARK: Damaged links open as one plain result

    func testTheWrongKeyFailsPlainly() throws {
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: .random())
        XCTAssertThrowsError(try ShareLinkSealing.open(sealed, key: .random())) { error in
            XCTAssertEqual(error as? ShareLinkSealing.Failure, .incompleteOrDamaged)
        }
    }

    func testAnyTamperedByteFailsPlainly() throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        // Every region: header, nonce, ciphertext and tag.
        for index in [0, 7, 8, 19, 20, sealed.packet.count / 2, sealed.packet.count - 1] {
            var tampered = sealed.packet
            tampered[index] ^= 0x01
            XCTAssertThrowsError(
                try ShareLinkSealing.open(ShareLinkSealing.SealedLink(preview: sealed.preview, packet: tampered), key: key),
                "byte \(index)"
            ) { error in
                XCTAssertEqual(error as? ShareLinkSealing.Failure, .incompleteOrDamaged)
            }
        }
    }

    func testATruncatedBlobFailsPlainly() throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        for length in [0, 1, 8, 20, 35, 36, sealed.packet.count - 1] {
            let truncated = ShareLinkSealing.SealedLink(preview: sealed.preview, packet: sealed.packet.prefix(length))
            XCTAssertThrowsError(try ShareLinkSealing.open(truncated, key: key), "length \(length)") { error in
                XCTAssertEqual(error as? ShareLinkSealing.Failure, .incompleteOrDamaged)
            }
        }
    }

    func testAPreviewCannotBePassedOffAsThePacket() throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        let swapped = ShareLinkSealing.SealedLink(preview: sealed.packet, packet: sealed.preview)
        XCTAssertThrowsError(try ShareLinkSealing.open(swapped, key: key))

        // Relabelling the header doesn't help either: the header is authenticated.
        var relabelled = sealed.preview
        relabelled[7] = ShareLinkSealing.Part.packet.rawValue
        XCTAssertThrowsError(try ShareLinkSealing.open(relabelled, as: .packet, key: key))
    }

    func testALinkMissingItsKeyFailsPlainly() throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        for link in [
            "https://spokenmargins.proximitytoprogress.com/l/AbCdEf123456",
            "https://spokenmargins.proximitytoprogress.com/l/AbCdEf123456#",
            "https://spokenmargins.proximitytoprogress.com/l/AbCdEf123456#\(key.fragment.dropLast(3))",
        ] {
            let found = ShareLinkSealing.key(inLink: URL(string: link)!)
            XCTAssertNil(found, link)
            XCTAssertThrowsError(try ShareLinkSealing.open(sealed, key: found), link) { error in
                XCTAssertEqual(error as? ShareLinkSealing.Failure, .incompleteOrDamaged)
                XCTAssertEqual((error as? ShareLinkSealing.Failure)?.message, "This link is incomplete or damaged.")
            }
        }
    }

    // MARK: The key in the link

    func testTheKeyTravelsOnlyInTheFragment() throws {
        let key = ShareLinkSealing.Key.random()
        let base = URL(string: "https://spokenmargins.proximitytoprogress.com/l/AbCdEf123456")!
        let link = try XCTUnwrap(ShareLinkSealing.linkURL(base: base, key: key))

        XCTAssertEqual(key.fragment.count, 43)
        XCTAssertEqual(link.absoluteString, base.absoluteString + "#" + key.fragment)
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertNil(components.query)
        XCTAssertFalse(components.path.contains(key.fragment))
        XCTAssertEqual(ShareLinkSealing.key(inLink: link), key)
    }

    func testFragmentParsingAcceptsPaddingAndRejectsAnythingElse() throws {
        let key = ShareLinkSealing.Key.random()
        XCTAssertEqual(ShareLinkSealing.Key(fragment: key.fragment + "="), key)
        XCTAssertNil(ShareLinkSealing.Key(fragment: ""))
        XCTAssertNil(ShareLinkSealing.Key(fragment: "="))
        XCTAssertNil(ShareLinkSealing.Key(fragment: key.fragment + "=A"))
        XCTAssertNil(ShareLinkSealing.Key(fragment: key.fragment + "AAAA"), "longer than 32 bytes")
        XCTAssertNil(ShareLinkSealing.Key(fragment: String(key.fragment.dropLast(4))), "shorter than 32 bytes")
        XCTAssertNil(ShareLinkSealing.Key(fragment: "+" + key.fragment.dropFirst()), "standard base64 isn't base64url")
        XCTAssertNil(ShareLinkSealing.Key(fragment: " " + key.fragment.dropFirst()))
        XCTAssertNil(ShareLinkSealing.Key(bytes: Data(count: 31)))
    }

    // MARK: The vector the web page also checks

    func testTheSharedVectorOpensAndSealsIdentically() throws {
        let vector = try Vector.load()
        let key = try XCTUnwrap(ShareLinkSealing.Key(fragment: vector.keyFragment))
        XCTAssertEqual(ShareLinkSealing.key(inLink: try XCTUnwrap(URL(string: vector.linkURL))), key)

        for (part, entry) in [(ShareLinkSealing.Part.preview, vector.preview), (.packet, vector.packet)] {
            XCTAssertEqual(entry.part, Int(part.rawValue))
            let sealed = try XCTUnwrap(Data(base64Encoded: entry.sealedBase64))
            let plaintext = try XCTUnwrap(Data(base64Encoded: entry.plaintextBase64))
            XCTAssertEqual(try ShareLinkSealing.open(sealed, as: part, key: key), plaintext, "\(part)")

            let nonce = try AES.GCM.Nonce(data: try XCTUnwrap(Data(hex: entry.nonceHex)))
            XCTAssertEqual(try ShareLinkSealing.seal(plaintext, as: part, key: key, nonce: nonce), sealed, "\(part)")
        }

        let link = ShareLinkSealing.SealedLink(
            preview: try XCTUnwrap(Data(base64Encoded: vector.preview.sealedBase64)),
            packet: try XCTUnwrap(Data(base64Encoded: vector.packet.sealedBase64))
        )
        let opened = try ShareLinkSealing.open(link, key: key)
        let preview = try JSONSerialization.jsonObject(with: opened.preview) as? [String: Any]
        XCTAssertEqual(preview?["schema"] as? String, "spokenmargins.link-preview.v1")
    }

    private struct Vector: Decodable {
        struct Entry: Decodable {
            let part: Int
            let nonceHex: String
            let plaintextBase64: String
            let sealedBase64: String
        }

        let keyFragment: String
        let linkURL: String
        let preview: Entry
        let packet: Entry

        static func load() throws -> Vector {
            try JSONDecoder().decode(Vector.self, from: TestInputs.data(.research, "B4/contracts/fixtures/share-link-sealing-vector.json"))
        }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
