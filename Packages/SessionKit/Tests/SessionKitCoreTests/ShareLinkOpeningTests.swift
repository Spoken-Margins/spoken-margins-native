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

    /// #1967: a gone link, a server fault and an odd answer are three different things to tell the listener.
    func testEachNonSuccessAnswerSaysWhatItMeans() async throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(packet: packet, preview: preview, key: key)
        let table: [(status: Int, expected: ShareLinkPacketDownloader.Failure)] = [
            (404, .expired), (410, .expired),
            (429, .serverProblem), (500, .serverProblem), (503, .serverProblem), (599, .serverProblem),
            (204, .expiredOrUnreachable), (301, .expiredOrUnreachable), (403, .expiredOrUnreachable)
        ]
        for (status, expected) in table {
            let downloader = ShareLinkPacketDownloader { _, _ in (status, sealed.packet) }
            await assertFails(downloader, link: try link(key: key), as: expected, "status \(status)")
        }
    }

    /// #1967: with no connection the link is fine; the listener must not be told it expired.
    func testNoConnectionSaysOfflineAndOffersARetry() async throws {
        let key = ShareLinkSealing.Key.random()
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
            .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive
        ]
        for code in codes {
            let downloader = ShareLinkPacketDownloader { _, _ in throw URLError(code) }
            await assertFails(downloader, link: try link(key: key), as: .offline, "\(code)")
        }
    }

    func testAnOversizedAnswerOrAFailedSecureConnectionSaysTheLinkCannotBeReached() async throws {
        let key = ShareLinkSealing.Key.random()
        for code in [URLError.Code.dataLengthExceedsMaximum, .secureConnectionFailed] {
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

    #if !canImport(FoundationNetworking)
    /// Audit on 39b55b5: the live download used the public transport's 30-second whole-download cap, so a valid
    /// 8 MB link on a slow phone connection timed out and was reported as expired.
    func testTheLiveDownloadGivesTheLargestAllowedPacketTimeToArriveOnASlowConnection() {
        let configuration = ShareLinkPacketDownloader.liveConfiguration()
        let secondsAtOneMegabit = Double(ShareLinkPacketDownloader.maximumSealedBytes * 8) / 1_000_000
        XCTAssertGreaterThanOrEqual(configuration.timeoutIntervalForResource, secondsAtOneMegabit)
        // Everything else is still the anonymous public transport.
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        // Small config and manifest fetches keep their short cap.
        XCTAssertEqual(BridgePublicTransport.configuration().timeoutIntervalForResource, 30)
    }
    #endif

    func testAURLSessionCancellationIsACancellationNotAnUnreachableLink() async throws {
        let downloader = ShareLinkPacketDownloader { _, _ in throw URLError(.cancelled) }
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

    /// J10, the offline check (#1842), opens this link in `docs/journeys.md` and `J10OfflineJourneyUITests`.
    /// Without a usable key it would fail as damaged before asking the server, so the check would never
    /// reach the unreachable host it is meant to test.
    func testTheOfflineCheckLinkAsksTheServerAndSaysOffline() async throws {
        let text = "https://\(host)/l/\(id)#AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let link = try XCTUnwrap(ShareLinkURL(url: URL(string: text)!))
        XCTAssertNotNil(link.key, "J10's link has no usable key")
        let requested = Requests()
        let downloader = ShareLinkPacketDownloader { url, maximumBytes in
            requested.record(url, maximumBytes)
            throw URLError(.cannotFindHost)
        }

        await assertFails(downloader, link: link, as: .offline)

        XCTAssertEqual(requested.urls.count, 1, "J10's link never asked the server")
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
        XCTAssertEqual(ShareLinkPacketDownloader.Failure.offline.message, "You're offline. Reconnect, then tap the link again.")
        XCTAssertEqual(ShareLinkPacketDownloader.Failure.expired.message, "This link has expired. Ask your friend to share it again.")
        XCTAssertEqual(ShareLinkPacketDownloader.Failure.serverProblem.message, "The server had a problem. Try again in a minute.")
    }

    func testOnlyAConnectionOrServerProblemIsWorthRetrying() {
        typealias Failure = ShareLinkPacketDownloader.Failure
        XCTAssertEqual(
            [Failure.offline, .expired, .serverProblem, .expiredOrUnreachable, .incompleteOrDamaged].map(\.isRetryable),
            [true, false, true, false, false]
        )
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
