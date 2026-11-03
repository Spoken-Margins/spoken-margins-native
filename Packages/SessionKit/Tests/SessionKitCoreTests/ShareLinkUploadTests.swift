import Foundation
import XCTest
@testable import SessionKit

/// The app side of share links (#487): preview rules, the sealed upload, and every way it can fail. The transport
/// is a recording one, so these run on Linux; the real URLSession transport is the app's.
final class ShareLinkUploadTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(url: URL, contentType: String, body: Data)] = []
        var requests: [(url: URL, contentType: String, body: Data)] { lock.withLock { stored } }
        func add(_ url: URL, _ contentType: String, _ body: Data) { lock.withLock { stored.append((url, contentType, body)) } }
    }

    private let key = ShareLinkSealing.Key(bytes: Data((0..<32).map { UInt8($0) }))!
    private let on = ServerFeatureState.on

    private func client(
        recorder: Recorder,
        status: Int = 201,
        body: String = #"{"id":"0123456789abcdef0123456789abcdef","path":"/l/0123456789abcdef0123456789abcdef","expiresAt":"2026-12-03T00:00:00Z"}"#,
        fail: Bool = false
    ) -> ShareLinkClient {
        let key = self.key
        return ShareLinkClient(server: { URL(string: "https://links.example.test\($0)")! }, key: { key }) { url, contentType, data in
            recorder.add(url, contentType, data)
            if fail { throw URLError(.notConnectedToInternet) }
            return (status, Data(body.utf8))
        }
    }

    private func preview(_ texts: [String] = ["Listen to this part."]) throws -> ShareLinkPreview {
        try ShareLinkPreviewBuilder.make(
            title: "HPR4736: How to replace the battery in a car key fob", show: "Hacker Public Radio",
            pageURL: "https://hackerpublicradio.org/eps/hpr4736/index.html", enclosureURL: "https://cdn.example.com/hpr4736.mp3",
            marginTexts: texts
        )
    }

    /// The two parts of the multipart body in order, by their form names.
    private func parts(of request: (url: URL, contentType: String, body: Data)) throws -> [(name: String, data: Data)] {
        let boundary = try XCTUnwrap(request.contentType.components(separatedBy: "boundary=").last)
        let delimiter = Data("--\(boundary)".utf8)
        var result: [(String, Data)] = []
        var cursor = request.body.startIndex
        var starts: [Range<Data.Index>] = []
        while let found = request.body.range(of: delimiter, in: cursor..<request.body.endIndex) {
            starts.append(found)
            cursor = found.upperBound
        }
        for (index, start) in starts.dropLast().enumerated() {
            let section = request.body[start.upperBound..<starts[index + 1].lowerBound]
            let headerEnd = try XCTUnwrap(section.range(of: Data("\r\n\r\n".utf8)))
            let header = String(decoding: section[section.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            let name = try XCTUnwrap(header.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first)
            // The part's data runs to the CRLF before the next delimiter.
            result.append((name, Data(section[headerEnd.upperBound...].dropLast(2))))
        }
        return result
    }

    // MARK: The upload

    func testASealedPacketAndPreviewAreUploadedAndTheKeyStaysInTheLink() async throws {
        let recorder = Recorder()
        let packet = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let preview = try preview(["First.", "Second."])

        let result = await client(recorder: recorder).makeLink(packet: packet, preview: preview, linksState: on)

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://links.example.test/api/v1/links")
        guard case .link(let link, let expiresAt) = result else { return XCTFail("expected a link, got \(result)") }
        XCTAssertEqual(link.absoluteString, "https://links.example.test/l/0123456789abcdef0123456789abcdef#\(key.fragment)")
        XCTAssertEqual(expiresAt, "2026-12-03T00:00:00Z")

        // Exactly two parts, preview first. The server gets neither the key nor any plaintext.
        let sent = try parts(of: request)
        XCTAssertEqual(sent.map(\.name), ["preview", "packet"])
        XCTAssertNil(request.body.range(of: key.bytes))
        XCTAssertNil(request.body.range(of: Data(key.fragment.utf8)))
        XCTAssertNil(request.body.range(of: Data("Second.".utf8)))
        XCTAssertNil(request.body.range(of: packet.prefix(64)))
        XCTAssertNil(request.url.fragment)

        // What the friend's phone gets back from the link is byte-identical to the file share.
        let linkKey = try XCTUnwrap(ShareLinkSealing.key(inLink: link))
        let opened = try ShareLinkSealing.open(.init(preview: sent[0].data, packet: sent[1].data), key: linkKey)
        XCTAssertEqual(opened.packet, packet)
        XCTAssertEqual(try JSONDecoder().decode(ShareLinkPreview.self, from: opened.preview), preview)
    }

    func testNothingIsSealedOrSentWhileTheLinksSwitchIsNotOn() async throws {
        let reasons: [ServerFeatureOffReason] = [.noConfig, .malformedConfig, .switchedOff, .staleConfig, .buildTooOld(minimumBuild: 99)]
        for reason in reasons {
            let recorder = Recorder()
            let result = await client(recorder: recorder).makeLink(packet: Data([1, 2, 3]), preview: try preview(), linksState: .off(reason))
            XCTAssertEqual(result, .useFile(.unavailable), "\(reason)")
            XCTAssertTrue(recorder.requests.isEmpty, "\(reason)")
        }
    }

    func testEveryFailureComesBackAsTheFileShareNeverAThrow() async throws {
        let cases: [(status: Int, expected: ShareLinkFallback)] = [
            (413, .tooLarge), (429, .busy), (503, .unavailable), (500, .failed), (404, .failed), (400, .failed), (200, .failed), (0, .failed),
        ]
        for (status, expected) in cases {
            let recorder = Recorder()
            let result = await client(recorder: recorder, status: status).makeLink(packet: Data([1]), preview: try preview(), linksState: on)
            XCTAssertEqual(result, .useFile(expected), "HTTP \(status)")
        }
        let offline = await client(recorder: Recorder(), fail: true).makeLink(packet: Data([1]), preview: try preview(), linksState: on)
        XCTAssertEqual(offline, .useFile(.offline))
    }

    func testEveryFallbackOffersTheFileInOneLine() {
        let all: [ShareLinkFallback] = [.unavailable, .nothingToSay, .tooLarge, .busy, .offline, .failed]
        for fallback in all {
            XCTAssertTrue(fallback.message.contains("as a file instead?"), "\(fallback)")
            XCTAssertFalse(fallback.message.contains("\n"))
        }
    }

    func testAPacketOverTheServerLimitIsRefusedBeforeAnythingIsSent() async throws {
        let recorder = Recorder()
        // The 36 bytes sealing adds push a packet at exactly the limit over it.
        let packet = Data(count: ShareLinkClient.maximumSealedPacketBytes)
        let result = await client(recorder: recorder).makeLink(packet: packet, preview: try preview(), linksState: on)
        XCTAssertEqual(result, .useFile(.tooLarge))
        XCTAssertTrue(recorder.requests.isEmpty)

        let fits = Data(count: ShareLinkClient.maximumSealedPacketBytes - 36)
        let ok = await client(recorder: recorder).makeLink(packet: fits, preview: try preview(), linksState: on)
        guard case .link = ok else { return XCTFail("a packet that fits should upload, got \(ok)") }
    }

    func testAnAnswerThatIsNotALinkPathIsNeverTurnedIntoALink() async throws {
        for body in [#"{}"#, #"{"path":""}"#, #"{"path":"/l/"}"#, #"{"path":"/l/a/b"}"#, #"{"path":"https://evil.example/l/x"}"#,
                     #"{"path":"/x/abc"}"#, #"{"path":"/l/abc123"}"#, #"{"path":"/l/0123456789ABCDEF0123456789ABCDEF"}"#,
                     #"{"path":"/l/0123456789abcdef0123456789abcde"}"#, #"{"path":"/l/a b"}"#, #"{"path":"/l/a?x=1"}"#, "not json"] {
            let result = await client(recorder: Recorder(), body: body).makeLink(packet: Data([1]), preview: try preview(), linksState: on)
            XCTAssertEqual(result, .useFile(.failed), body)
        }
    }

    func testTheLinkNeverCarriesTheKeyToTheServerInAnyRequestHeaderOrUrl() async throws {
        let recorder = Recorder()
        _ = await client(recorder: recorder).makeLink(packet: Data([1, 2]), preview: try preview(), linksState: on)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertFalse(request.url.absoluteString.contains(key.fragment))
        XCTAssertTrue(request.contentType.hasPrefix("multipart/form-data; boundary="))
        XCTAssertFalse(request.contentType.contains(key.fragment))
    }

    // MARK: The preview

    func testAPrivateOrNonPageSourceAddressIsLeftOutOfThePreview() throws {
        func url(_ page: String?, enclosure: String? = nil) throws -> String? {
            try ShareLinkPreviewBuilder.make(title: "T", show: nil, pageURL: page, enclosureURL: enclosure, marginTexts: ["x"]).source.url
        }
        XCTAssertEqual(try url("https://hackerpublicradio.org/eps/hpr4736/index.html"), "https://hackerpublicradio.org/eps/hpr4736/index.html")
        XCTAssertEqual(try url("https://example.com/podcast/episode-12"), "https://example.com/podcast/episode-12")
        // A secret in the query, the path or the userinfo; a members-only host; a feed; the audio file itself.
        XCTAssertNil(try url("https://example.com/ep?token=abc123"))
        XCTAssertNil(try url("https://example.com/ep?page=2"), "any query is left out")
        XCTAssertNil(try url("https://example.com/ep#section"), "a fragment is left out")
        XCTAssertNil(try url("https://user:pw@example.com/ep"))
        XCTAssertNil(try url("https://www.patreon.com/posts/1234"))
        XCTAssertNil(try url("https://example.com/private/feed/0123456789abcdef0123456789abcdef"))
        XCTAssertNil(try url("https://example.com/feed.xml"))
        XCTAssertNil(try url("https://example.com/feed"))
        XCTAssertNil(try url("https://example.com/eps/hpr4736/hpr4736.mp3"))
        XCTAssertNil(try url("https://example.com/eps/HPR4736.MP3"))
        XCTAssertNil(try url("https://example.com/page", enclosure: "https://example.com/page"))
        XCTAssertNil(try url("http://example.com/ep"), "https only")
        XCTAssertNil(try url("https://example.com:8443/ep"))
        XCTAssertNil(try url("ftp://example.com/ep"))
        XCTAssertNil(try url("   "))
        XCTAssertNil(try url(nil))
        XCTAssertNil(try url("https://example.com/" + String(repeating: "a", count: 2_100)))
    }

    func testNoPrivateAddressAppearsAnywhereInTheEncodedPreview() throws {
        let secret = "https://feeds.example.com/private/abc?token=SECRET123"
        let preview = try ShareLinkPreviewBuilder.make(
            title: "Episode", show: "Show", pageURL: secret, enclosureURL: "https://cdn.example.com/a.mp3?sig=SECRET123", marginTexts: ["hi"]
        )
        let text = String(decoding: try ShareLinkPreviewBuilder.encoded(preview), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET123"))
        XCTAssertFalse(text.contains("feeds.example.com"))
        XCTAssertFalse(text.contains("cdn.example.com"))
    }

    func testMarginWordsAreTrimmedCutToFiveHundredScalarsAndEmptyOnesDropped() throws {
        let emoji = String(repeating: "👨‍👩‍👧", count: 300) // each is 5 scalars but one Character
        let preview = try ShareLinkPreviewBuilder.make(
            title: "T", show: nil, pageURL: nil, enclosureURL: nil,
            marginTexts: ["  Hello \n", "", "   \n ", emoji, String(repeating: "a", count: 499), String(repeating: "b", count: 501)]
        )
        let texts = preview.margins.map(\.text)
        XCTAssertEqual(texts.count, 4)
        XCTAssertEqual(texts[0], "Hello")
        XCTAssertEqual(texts[1].unicodeScalars.count, 500)
        XCTAssertEqual(texts[2].count, 499)
        XCTAssertEqual(texts[3].count, 500)
        XCTAssertNil(preview.source.url)
        XCTAssertNil(preview.source.show)
    }

    func testAPreviewWithNoWordsIsRefusedSoTheSenderIsOfferedTheFile() {
        for texts in [[], [""], ["   ", "\n\t"]] {
            XCTAssertThrowsError(try ShareLinkPreviewBuilder.make(title: "T", show: nil, pageURL: nil, enclosureURL: nil, marginTexts: texts)) {
                XCTAssertEqual($0 as? ShareLinkPreviewBuilder.Failure, .nothingToSay)
            }
        }
    }

    func testAPreviewStaysUnderTheServersSixteenKilobytesAndKeepsTheFirstMargins() throws {
        let texts = (0..<200).map { "Margin \($0): " + String(repeating: "é", count: 480) }
        let preview = try ShareLinkPreviewBuilder.make(title: String(repeating: "T", count: 900), show: String(repeating: "S", count: 900), pageURL: nil, enclosureURL: nil, marginTexts: texts)
        let encoded = try ShareLinkPreviewBuilder.encoded(preview)
        XCTAssertLessThanOrEqual(encoded.count, ShareLinkPreviewBuilder.maximumPreviewBytes)
        XCTAssertGreaterThan(preview.margins.count, 5)
        XCTAssertLessThan(preview.margins.count, 200)
        XCTAssertEqual(preview.margins.first?.text.hasPrefix("Margin 0:"), true)
        XCTAssertEqual(preview.margins.map(\.text), Array(texts.prefix(preview.margins.count)).map { $0.unicodeScalars.count > 500 ? String(String.UnicodeScalarView($0.unicodeScalars.prefix(500))) : $0 })
        XCTAssertEqual(preview.source.title.unicodeScalars.count, 300)
        // The sealed part is 36 bytes bigger and still fits the server's limit.
        let sealed = try ShareLinkSealing.seal(packet: Data([1]), preview: encoded, key: key)
        XCTAssertLessThanOrEqual(sealed.preview.count, 16 << 10)
    }

    func testThePreviewIsPlainJsonWithOnlyWordsAndNoQuotedSource() throws {
        let preview = try preview(["One."])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try ShareLinkPreviewBuilder.encoded(preview)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "source", "margins"])
        XCTAssertEqual(object["schema"] as? String, "spokenmargins.link-preview.v1")
        let margins = try XCTUnwrap(object["margins"] as? [[String: Any]])
        XCTAssertEqual(margins.map { Set($0.keys) }, [["text"]], "no before or after excerpt: a link never quotes the source")
        let source = try XCTUnwrap(object["source"] as? [String: Any])
        XCTAssertEqual(Set(source.keys), ["title", "show", "url"])
    }

    func testTheLinksServiceNameMatchesTheServersConfig() {
        XCTAssertEqual(ServerService.links, "links")
        let config = ServerConfig(serial: 1, services: ["links": .init(enabled: true, minimumBuild: 35)])
        let cached = CachedServerConfig(config: config, fetchedAt: Date())
        XCTAssertEqual(ServerFeatureGate.state(of: ServerService.links, cached: cached, now: Date(), appBuild: 35), .on)
        XCTAssertEqual(ServerFeatureGate.state(of: ServerService.links, cached: cached, now: Date(), appBuild: 34), .off(.buildTooOld(minimumBuild: 35)))
    }
}
