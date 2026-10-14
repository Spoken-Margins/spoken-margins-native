import Foundation
import XCTest
@testable import SessionKit

/// Tapping a share link opens the app and imports the sealed packet (#488).
final class ShareLinkOpeningTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef"
    private let host = "spokenmargins.proximitytoprogress.com"
    private let packet = Data("PK\u{3}\u{4}a packet's exact bytes".utf8) + Data((0...255).map { UInt8($0) })
    private let preview = Data(#"{"schema":"spokenmargins.link-preview.v1"}"#.utf8)

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-link-opening-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Parsing

    func testAShareLinkParsesToItsIdAndKey() throws {
        let key = ShareLinkSealing.Key.random()
        let url = try XCTUnwrap(ShareLinkSealing.linkURL(base: URL(string: "https://\(host)/l/\(id)")!, key: key))

        let link = try XCTUnwrap(ShareLinkURL(url: url))

        XCTAssertEqual(link.id, id)
        XCTAssertEqual(link.key, key)
        XCTAssertEqual(link.packetURL.absoluteString, "https://\(host)/l/\(id)/packet")
    }

    func testALinkWithoutAKeyStillParsesAndOpensAsDamaged() throws {
        for text in ["https://\(host)/l/\(id)", "https://\(host)/l/\(id)#", "https://\(host)/l/\(id)#not a key", "https://\(host)/l/\(id)#AAAA"] {
            let link = try XCTUnwrap(ShareLinkURL(url: URL(string: text)!), text)
            XCTAssertNil(link.key, text)
        }
    }

    func testOnlyTheExactShareLinkShapeParses() {
        let key = ShareLinkSealing.Key.random().fragment
        let accepted = [
            "https://\(host)/l/\(id)#\(key)",
            "https://\(host.uppercased())/l/\(id)#\(key)",
            "https://\(host):443/l/\(id)#\(key)",
            "https://\(host)/l/\(id)?utm=1#\(key)",
        ]
        let rejected = [
            "http://\(host)/l/\(id)#\(key)",
            "spokenmargins://\(host)/l/\(id)#\(key)",
            "https://example.com/l/\(id)#\(key)",
            "https://\(host).example.com/l/\(id)#\(key)",
            "https://www.\(host)/l/\(id)#\(key)",
            "https://user@\(host)/l/\(id)#\(key)",
            "https://\(host):8443/l/\(id)#\(key)",
            "https://\(host)/l/\(id)/#\(key)",
            "https://\(host)/l/\(id)/packet#\(key)",
            "https://\(host)/l/\(id)/report#\(key)",
            "https://\(host)/L/\(id)#\(key)",
            "https://\(host)/x/\(id)#\(key)",
            "https://\(host)/l/#\(key)",
            "https://\(host)/l#\(key)",
            "https://\(host)/#\(key)",
            "https://\(host)//l/\(id)#\(key)",
            "https://\(host)/l/\(id.uppercased())#\(key)",
            "https://\(host)/l/\(id.dropLast())#\(key)",
            "https://\(host)/l/\(id)0#\(key)",
            "https://\(host)/l/\(String(id.dropLast()))g#\(key)",
            "https://\(host)/l/\(String(id.dropLast()))%61#\(key)",
            "https://\(host)/l/..%2f\(id.dropLast(4))#\(key)",
            "https://\(host)/l/ \(id.dropLast())#\(key)",
            "file:///l/\(id)",
        ]
        for text in accepted {
            XCTAssertNotNil(URL(string: text).flatMap(ShareLinkURL.init(url:)), text)
        }
        for text in rejected {
            XCTAssertNil(URL(string: text).flatMap(ShareLinkURL.init(url:)), text)
        }
    }

    func testTheShareHostIsRecognisedForLinksTheAppCannotOpen() {
        XCTAssertTrue(ShareLinkURL.isOnShareHost(URL(string: "https://\(host)/l/\(id)/packet")!))
        XCTAssertFalse(ShareLinkURL.isOnShareHost(URL(string: "https://example.com/l/\(id)")!))
        XCTAssertFalse(ShareLinkURL.isOnShareHost(URL(string: "spokenmargins://open")!))
    }

    // MARK: Downloading

    private func link(key: ShareLinkSealing.Key?) throws -> ShareLinkURL {
        let base = URL(string: "https://\(host)/l/\(id)")!
        let url = key.flatMap { ShareLinkSealing.linkURL(base: base, key: $0) } ?? base
        return try XCTUnwrap(ShareLinkURL(url: url))
    }

    func testADownloadedLinkWritesTheExactPacketFile() async throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        let requested = Requests()
        let downloader = ShareLinkPacketDownloader { url, maximumBytes in
            requested.record(url, maximumBytes)
            return (200, sealed.packet)
        }
        let directory = try scratchDirectory()

        let file = try await downloader.download(try link(key: key), into: directory)

        XCTAssertEqual(file.pathExtension, "spokenmargins")
        XCTAssertEqual(try Data(contentsOf: file), packet, "the file must be byte-identical to the file share")
        XCTAssertEqual(requested.urls, [URL(string: "https://\(host)/l/\(id)/packet")!])
        XCTAssertGreaterThan(requested.maximumBytes.first ?? 0, 20 << 20, "the cap must leave room for the sealing header")
    }

    func testEveryNonSuccessAnswerSaysTheLinkExpiredOrCannotBeReached() async throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        for status in [204, 301, 404, 410, 429, 500, 503] {
            let downloader = ShareLinkPacketDownloader { _, _ in (status, sealed.packet) }
            await assertFails(downloader, link: try link(key: key), as: .expiredOrUnreachable, "status \(status)")
        }
    }

    func testANetworkErrorOrAnOversizedAnswerSaysTheLinkCannotBeReached() async throws {
        let key = ShareLinkSealing.Key.random()
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .dataLengthExceedsMaximum, .secureConnectionFailed] {
            let downloader = ShareLinkPacketDownloader { _, _ in throw URLError(code) }
            await assertFails(downloader, link: try link(key: key), as: .expiredOrUnreachable, "\(code)")
        }
    }

    func testACancelledDownloadStaysCancelled() async throws {
        let downloader = ShareLinkPacketDownloader { _, _ in throw CancellationError() }
        do {
            _ = try await downloader.download(try link(key: .random()), into: try scratchDirectory())
            XCTFail("a cancelled download must not produce a file")
        } catch is CancellationError {
        }
    }

    func testALinkWithoutItsKeyIsDamagedAndNeverAsksTheServer() async throws {
        let requested = Requests()
        let downloader = ShareLinkPacketDownloader { url, maximumBytes in
            requested.record(url, maximumBytes)
            return (200, Data())
        }

        await assertFails(downloader, link: try link(key: nil), as: .incompleteOrDamaged)

        XCTAssertTrue(requested.urls.isEmpty)
    }

    func testTheWrongKeyADamagedBlobAndAPreviewInThePacketSlotAreAllDamaged() async throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        var flipped = sealed.packet
        flipped[flipped.count / 2] ^= 0x01
        let blobs: [(String, Data, ShareLinkSealing.Key)] = [
            ("wrong key", sealed.packet, .random()),
            ("flipped byte", flipped, key),
            ("truncated", sealed.packet.prefix(20), key),
            ("empty", Data(), key),
            ("plain packet", packet, key),
            ("preview part", sealed.preview, key),
        ]
        for (name, blob, linkKey) in blobs {
            let downloader = ShareLinkPacketDownloader { _, _ in (200, blob) }
            await assertFails(downloader, link: try link(key: linkKey), as: .incompleteOrDamaged, name)
        }
    }

    func testAFailedDownloadLeavesNoFileBehind() async throws {
        let directory = try scratchDirectory()
        let downloader = ShareLinkPacketDownloader { _, _ in (410, Data()) }

        _ = try? await downloader.download(try link(key: .random()), into: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testTheMessagesTheListenerSees() {
        XCTAssertEqual(ShareLinkPacketDownloader.Failure.expiredOrUnreachable.message, "This link has expired or can't be reached.")
        XCTAssertEqual(ShareLinkPacketDownloader.Failure.incompleteOrDamaged.message, "This link is incomplete or damaged.")
    }

    private func assertFails(
        _ downloader: ShareLinkPacketDownloader, link: ShareLinkURL, as expected: ShareLinkPacketDownloader.Failure,
        _ context: String = "", file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let directory = try scratchDirectory()
            let written = try await downloader.download(link, into: directory)
            XCTFail("expected \(expected), wrote \(written.path) \(context)", file: file, line: line)
        } catch let failure as ShareLinkPacketDownloader.Failure {
            XCTAssertEqual(failure, expected, context, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error) \(context)", file: file, line: line)
        }
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    private var recordedMaximumBytes: [Int] = []

    func record(_ url: URL, _ maximumBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        recordedURLs.append(url)
        recordedMaximumBytes.append(maximumBytes)
    }

    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recordedURLs }
    var maximumBytes: [Int] { lock.lock(); defer { lock.unlock() }; return recordedMaximumBytes }
}
