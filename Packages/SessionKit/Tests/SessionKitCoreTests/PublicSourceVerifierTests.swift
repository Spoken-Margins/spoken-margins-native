import Foundation
import SessionKit
import XCTest

/// The check that earns a source its `PublicSourceMark` (#3449): an anonymous look at its public address.
final class PublicSourceVerifierTests: XCTestCase, @unchecked Sendable {
    private let address = "https://example.com/posts/harbour-lights"
    private let enclosure = "https://cdn.example.com/episodes/harbour-lights.mp3"
    private let checkedAt = Date()

    private let sentences = [
        "The harbour lights came on one by one as the ferry slid past the breakwater and into the dark water.",
        "Nobody on the upper deck said anything for a while, because the cold had taken the words out of them.",
        "She counted the buoys the way her grandfather had taught her, by the colour and the rhythm of each flash.",
        "At the pier a man in a yellow coat was already coiling rope, as though the night had been planned for him.",
        "The ticket office had closed hours before, and a handwritten sign promised that it would open at dawn.",
        "Later they walked the length of the sea wall and watched the tide pull the last of the light out to sea.",
        "It was the kind of evening that makes a town feel like a rumour that only the locals can confirm.",
        "By midnight the cafe on the corner had turned its chairs over, and the street belonged to the gulls.",
    ]

    private var copy: String { sentences.joined(separator: " ") }

    private func page(_ parts: [String], head: String = "") -> Data {
        let body = parts.map { "<p>\($0)</p>" }.joined(separator: "\n")
        return Data("<!doctype html><html><head><title>Harbour Lights</title>\(head)</head><body><article>\(body)</article></body></html>".utf8)
    }

    private func textItem(_ text: String? = nil, reference: String? = nil, type: String? = "url") -> Item {
        Item(id: "item-1", title: "Harbour Lights", mediaType: "text", text: text ?? copy,
             externalReference: reference ?? address, status: "ready", externalReferenceType: type)
    }

    private func audioItem(enclosure: String? = nil, reference: String? = nil) -> Item {
        Item(id: "item-1", title: "Harbour Lights", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
             externalReference: reference ?? address, status: "ready", externalReferenceType: "url",
             media: ItemMedia(sourceType: .remoteStream, url: enclosure ?? self.enclosure, durationMs: 60_000))
    }

    private func verify(_ item: Item, timeout: Duration = .seconds(5), answers: @escaping @Sendable (URL, PublicSourceVerifier.Purpose) throws -> PublicSourceVerifier.Response) async -> (PublicSourceVerifier.Outcome, [URL]) {
        let probe = Probe(answers)
        let outcome = await PublicSourceVerifier(probe: probe.run).verify(item, now: checkedAt, timeout: timeout)
        return (outcome, probe.requested)
    }

    private func okPage(_ data: Data, type: String? = "text/html; charset=utf-8") -> PublicSourceVerifier.Response {
        PublicSourceVerifier.Response(status: 200, contentType: type, body: data)
    }

    private func assertMarked(_ result: (PublicSourceVerifier.Outcome, [URL]), _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.0, .marked(PublicSourceMark(url: address, checkedAt: checkedAt)), name, file: file, line: line)
    }

    private func assertNot(_ result: (PublicSourceVerifier.Outcome, [URL]), _ expected: PublicSourceVerifier.Outcome, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.0, expected, name, file: file, line: line)
    }

    // MARK: Text

    func testTheFullPageEarnsTheMark() async {
        assertMarked(await verify(textItem()) { _, _ in self.okPage(self.page(self.sentences)) }, "the page holds the whole copy")
    }

    func testNeighbouringFormsOfTheSamePageStillMatch() async {
        let rows: [(String, Data)] = [
            ("upper case", page(sentences.map { $0.uppercased() })),
            ("extra whitespace and line breaks", page(sentences.map { "  " + $0.replacingOccurrences(of: " ", with: " \n  ") + "  " })),
            ("inline tags inside the sentence", page(sentences.map { $0.replacingOccurrences(of: "the ", with: "<em>the</em> ") })),
            ("character references", page(sentences.map { $0.replacingOccurrences(of: ",", with: "&#44;").replacingOccurrences(of: ".", with: "&#x2E;").replacingOccurrences(of: "The ", with: "&#84;he ") })),
            ("curly punctuation and dashes", page(sentences.map { $0.replacingOccurrences(of: ", ", with: "\u{2014} ").replacingOccurrences(of: ".", with: "\u{2026}") })),
            ("non-breaking spaces", page(sentences.map { $0.replacingOccurrences(of: " ", with: "&nbsp;") })),
            ("scripts, styles and comments around the article", page(sentences, head: "<style>p{color:red}</style><script>var x = 'noise';</script><!-- note -->")),
            ("accented letters written decomposed", page(sentences.map { $0.replacingOccurrences(of: "cafe", with: "cafe\u{301}") })),
        ]
        for (name, data) in rows {
            assertMarked(await verify(textItem()) { _, _ in self.okPage(data) }, name)
        }
    }

    func testAnAccentedCopyMatchesAPlainPage() async {
        let accented = sentences.map { $0.replacingOccurrences(of: "cafe", with: "caf\u{E9}") }
        assertMarked(await verify(textItem(accented.joined(separator: " "))) { _, _ in self.okPage(self.page(self.sentences)) }, "accent folded")
    }

    func testAPaywallTeaserEarnsNoMark() async {
        let teaser = page(Array(sentences.prefix(3)) + ["Subscribe to keep reading this story and everything else we publish."])
        assertNot(await verify(textItem()) { _, _ in self.okPage(teaser) }, .notPublic, "only the opening is public")
    }

    func testTheFullTextHiddenInAScriptIsNotWhatAVisitorReads() async {
        let teaser = page(Array(sentences.prefix(2)), head: "<script type=\"application/ld+json\">{\"articleBody\": \"\(copy)\"}</script>")
        assertNot(await verify(textItem()) { _, _ in self.okPage(teaser) }, .notPublic, "structured data is not the page")
    }

    func testAnotherArticleOnTheSameHostEarnsNoMark() async {
        let other = ["The council voted on Tuesday to extend the bus lane as far as the old railway bridge on the north side.",
                     "Residents who attended the meeting said the plan would cut their commute by roughly a quarter of an hour.",
                     "A final decision on funding is not expected until the spring, when the regional budget is published.",
                     "Opponents argued that the money would be better spent on repairing the surface of the existing roads.",
                     "The mayor said she would ask for a second report before putting the proposal to a full vote of the council."]
        assertNot(await verify(textItem()) { _, _ in self.okPage(self.page(other)) }, .notPublic, "a lookalike page on the same host")
    }

    func testEmptyAndOddBodiesEarnNoMark() async {
        assertNot(await verify(textItem()) { _, _ in self.okPage(Data()) }, .notPublic, "empty body")
        assertNot(await verify(textItem()) { _, _ in self.okPage(Data("<html><body></body></html>".utf8)) }, .notPublic, "empty page")
        assertNot(await verify(textItem()) { _, _ in self.okPage(Data(self.copy.utf8), type: "application/json") }, .notPublic, "a JSON answer")
        assertNot(await verify(textItem()) { _, _ in self.okPage(Data([0xFF, 0xFE, 0x00, 0x41])) }, .notPublic, "bytes that are not text")
    }

    func testACopyTooShortToSampleCannotBeChecked() async {
        let short = textItem(sentences.prefix(2).joined(separator: " "))
        let result = await verify(short) { _, _ in self.okPage(self.page(self.sentences)) }
        assertNot(result, .notPublic, "two sentences prove nothing")
        XCTAssertEqual(result.1, [], "and no request is made for it")
    }

    func testAnswerStatuses() async {
        for status in [401, 402, 403, 404, 410, 451] {
            assertNot(await verify(textItem()) { _, _ in .init(status: status, contentType: "text/html", body: self.page(self.sentences)) }, .notPublic, "status \(status) is not public even with a body")
        }
        for status in [429, 500, 502, 503] {
            assertNot(await verify(textItem()) { _, _ in .init(status: status) }, .couldNotCheck, "status \(status) is the server's fault, so try again")
        }
    }

    func testOfflineCouldNotBeChecked() async {
        assertNot(await verify(textItem()) { _, _ in throw URLError(.notConnectedToInternet) }, .couldNotCheck, "offline")
        assertNot(await verify(textItem()) { _, _ in throw URLError(.timedOut) }, .couldNotCheck, "timed out")
    }

    func testASlowAnswerEndsAtTheDeadline() async {
        let slow = Probe { _, _ in self.okPage(self.page(self.sentences)) }
        slow.delay = .seconds(30)
        let started = ContinuousClock.now
        let outcome = await PublicSourceVerifier(probe: slow.runDelayed).verify(textItem(), timeout: .milliseconds(150))
        XCTAssertEqual(outcome, .couldNotCheck)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the share tap does not wait for a hung server")
    }

    // MARK: Redirects

    func testRedirectsAreFollowedWhenTheyStayOnHTTPS() async {
        let canonical = URL(string: "https://www.example.com/posts/harbour-lights/")!
        let result = await verify(textItem()) { url, _ in
            url == canonical ? self.okPage(self.page(self.sentences)) : .init(status: 301, redirect: canonical)
        }
        assertMarked(result, "http-to-www and a trailing slash")
        XCTAssertEqual(result.1.count, 2)
    }

    func testRedirectsThatLeadAwayEarnNoMark() async {
        let rows: [(String, URL)] = [
            ("to http", URL(string: "http://example.com/posts/harbour-lights")!),
            ("to a login page", URL(string: "https://example.com/login?next=/posts/harbour-lights")!),
            ("to a sign-in host", URL(string: "https://signin.example.com/start")!),
            ("to a subscribe page", URL(string: "https://example.com/subscribe")!),
            ("to a paywall path", URL(string: "https://example.com/paywall/harbour-lights")!),
            ("to userinfo", URL(string: "https://me:pw@example.com/posts/harbour-lights")!),
            ("to a file", URL(string: "file:///etc/hosts")!),
        ]
        for (name, target) in rows {
            let result = await verify(textItem()) { url, _ in url == target ? self.okPage(self.page(self.sentences)) : .init(status: 302, redirect: target) }
            assertNot(result, .notPublic, name)
            XCTAssertEqual(result.1.count, 1, "\(name): the hop is not requested")
        }
        assertNot(await verify(textItem()) { _, _ in .init(status: 302) }, .notPublic, "a redirect with no address")
    }

    func testAnAccountWordInASlugIsNotAGate() {
        XCTAssertFalse(PublicSourceVerifier.looksLikeAGate(URL(string: "https://example.com/posts/accountability-and-the-harbour")!))
        XCTAssertTrue(PublicSourceVerifier.looksLikeAGate(URL(string: "https://example.com/sign-in")!))
        XCTAssertTrue(PublicSourceVerifier.looksLikeAGate(URL(string: "https://example.com/Log_In")!))
    }

    func testARedirectLoopStops() async {
        let result = await verify(textItem()) { url, _ in .init(status: 302, redirect: url.appendingPathComponent("x")) }
        assertNot(result, .notPublic, "a loop")
        XCTAssertEqual(result.1.count, PublicSourceVerifier.maximumRedirects + 1)
    }

    // MARK: Sources that cannot earn it

    func testOriginsWithNoPublicCopyAreNeverRequested() async {
        let rows: [(String, Item)] = [
            ("http", textItem(reference: "http://example.com/post")),
            ("a secret in the query", textItem(reference: address + "?token=abc123def456")),
            ("a secret in the path", textItem(reference: "https://example.com/u/0123456789abcdef0123456789abcdef/post")),
            ("userinfo", textItem(reference: "https://me:pw@example.com/post")),
            ("a paid-feed host", textItem(reference: "https://www.patreon.com/posts/harbour-lights")),
            ("a PDF from Files", textItem(reference: "file:///private/var/Doc.pdf", type: "file")),
            ("a file that kept a web address", textItem(type: "file")),
            ("an EPUB", textItem(type: "epub")),
            ("an audiobook", textItem(type: "audiobook")),
            ("pasted text", textItem(type: "manual")),
            ("no address", textItem(reference: "")),
            ("an enclosure with a subscriber token", audioItem(enclosure: "https://cdn.example.com/feed/ep.mp3?token=abcdef123456")),
            ("an http enclosure", audioItem(enclosure: "http://cdn.example.com/ep.mp3")),
            ("an enclosure on a paid host", audioItem(enclosure: "https://www.patreon.com/file/ep.mp3")),
            ("an enclosure with userinfo", audioItem(enclosure: "https://me:pw@cdn.example.com/ep.mp3")),
            ("an imported audio file", Item(id: "i", title: "t", mediaType: "audiobook", text: nil, externalReference: address, status: "ready", externalReferenceType: "file",
                                            media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///a.mp3"))),
        ]
        for (name, item) in rows {
            let result = await verify(item) { _, _ in self.okPage(self.page(self.sentences)) }
            assertNot(result, .notPublic, name)
            XCTAssertEqual(result.1, [], "\(name): nothing is fetched")
        }
    }

    // MARK: Audio

    func testAnEnclosureThatAnswersWithAudioEarnsTheMark() async {
        for status in [200, 206] {
            let result = await verify(audioItem()) { url, purpose in
                XCTAssertEqual(purpose, .audioStart)
                return .init(status: status, contentType: "audio/mpeg", body: Data([0x49]))
            }
            assertMarked(result, "status \(status)")
        }
        assertMarked(await verify(audioItem()) { _, _ in .init(status: 200, contentType: "Audio/MP4; codecs=mp4a", body: Data([0])) }, "case and parameters")
        assertMarked(await verify(audioItem()) { _, _ in .init(status: 200, contentType: "application/octet-stream") }, "an untyped download")
    }

    func testAnEnclosureThroughAMeasurementRedirectEarnsTheMark() async {
        let cdn = URL(string: "https://media.cdn.example.net/ep.mp3?expires=1800000000&sig=abc")!
        let result = await verify(audioItem()) { url, _ in
            url == cdn ? .init(status: 206, contentType: "audio/mpeg", body: Data([1])) : .init(status: 302, redirect: cdn)
        }
        assertMarked(result, "the final address may carry a signature; the start address is what was shared")
    }

    func testAnEnclosureThatIsNotAudioEarnsNoMark() async {
        let rows: [(String, PublicSourceVerifier.Response)] = [
            ("a login page with a 200", .init(status: 200, contentType: "text/html", body: Data("<html>Sign in</html>".utf8))),
            ("no content type", .init(status: 200, contentType: nil, body: Data([1]))),
            ("a JSON error", .init(status: 200, contentType: "application/json", body: Data("{}".utf8))),
            ("a 401", .init(status: 401, contentType: "audio/mpeg")),
            ("a 403", .init(status: 403, contentType: "audio/mpeg")),
            ("a 404", .init(status: 404, contentType: "audio/mpeg")),
        ]
        for (name, response) in rows {
            assertNot(await verify(audioItem()) { _, _ in response }, .notPublic, name)
        }
        assertNot(await verify(audioItem()) { _, _ in throw URLError(.notConnectedToInternet) }, .couldNotCheck, "offline")
    }

    func testAnEpisodePageAddressDoesNotNeedToServeTheArticle() async {
        let result = await verify(audioItem()) { url, _ in
            XCTAssertEqual(url.absoluteString, self.enclosure, "audio checks the enclosure, not the episode page")
            return .init(status: 200, contentType: "audio/mpeg", body: Data([1]))
        }
        assertMarked(result, "enclosure only")
        XCTAssertEqual(result.1.count, 1)
    }

    // MARK: The marker

    func testTheMarkerSavesTheMarkOnTheItem() async throws {
        let repository = InMemorySessionRepository()
        repository.items["item-1"] = textItem()
        let probe = Probe { _, _ in self.okPage(self.page(self.sentences)) }
        let marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.run), now: { self.checkedAt })

        let first = await marker.ensureMark(itemId: "item-1", repository: repository)
        XCTAssertEqual(first, .marked(PublicSourceMark(url: address, checkedAt: checkedAt)))
        XCTAssertTrue(MapTextDisclosure.allowsModelText(of: try repository.loadItem(id: "item-1")))

        let second = await marker.ensureMark(itemId: "item-1", repository: repository)
        XCTAssertEqual(second, first)
        XCTAssertEqual(probe.requested.count, 1, "a marked item is not fetched again")
    }

    func testAFailedCheckLeavesTheItemAndTheNextTapTriesAgain() async throws {
        let repository = InMemorySessionRepository()
        repository.items["item-1"] = textItem()
        let probe = Probe { _, _ in throw URLError(.notConnectedToInternet) }
        let marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.run))
        let outcome = await marker.ensureMark(itemId: "item-1", repository: repository)
        XCTAssertEqual(outcome, .couldNotCheck)
        XCTAssertEqual(try repository.loadItem(id: "item-1"), textItem(), "nothing written")
        _ = await marker.ensureMark(itemId: "item-1", repository: repository)
        XCTAssertEqual(probe.requested.count, 2)
    }

    func testAnItemTheListenerChangedDuringTheCheckKeepsTheirChangeAndLosesTheMark() async throws {
        let repository = InMemorySessionRepository()
        repository.items["item-1"] = textItem()
        let probe = Probe { _, _ in
            var moved = repository.items["item-1"]!
            moved.externalReference = "https://example.com/posts/renamed"
            repository.items["item-1"] = moved
            return self.okPage(self.page(self.sentences))
        }
        let marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.run))
        _ = await marker.ensureMark(itemId: "item-1", repository: repository)
        let saved = try repository.loadItem(id: "item-1")
        XCTAssertNil(saved.publicSourceMark, "the mark names the address it checked, and that address is gone")
        XCTAssertEqual(saved.externalReference, "https://example.com/posts/renamed")
    }

    func testAMissingItemCouldNotBeChecked() async {
        let probe = Probe { _, _ in .init(status: 200) }
        let outcome = await PublicSourceMarker(verifier: PublicSourceVerifier(probe: probe.run)).ensureMark(itemId: "nope", repository: InMemorySessionRepository())
        XCTAssertEqual(outcome, .couldNotCheck)
        XCTAssertEqual(probe.requested, [])
    }
}

private struct SlowForever: Error {}

/// Records the requests a verifier makes and answers them from a closure.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private let answers: @Sendable (URL, PublicSourceVerifier.Purpose) throws -> PublicSourceVerifier.Response
    var delay: Duration?

    init(_ answers: @escaping @Sendable (URL, PublicSourceVerifier.Purpose) throws -> PublicSourceVerifier.Response) {
        self.answers = answers
    }

    var requested: [URL] { lock.withLock { urls } }

    func run(_ url: URL, _ purpose: PublicSourceVerifier.Purpose) async throws -> PublicSourceVerifier.Response {
        lock.withLock { urls.append(url) }
        return try answers(url, purpose)
    }

    func runDelayed(_ url: URL, _ purpose: PublicSourceVerifier.Purpose) async throws -> PublicSourceVerifier.Response {
        if let delay { try await Task.sleep(for: delay) }
        return try await run(url, purpose)
    }
}

/// Reviewer-found gaps (#3449): private-network names, a mark that outlives its week, and an export option toggled repeatedly.
final class PublicSourceMarkLifetimeTests: XCTestCase, @unchecked Sendable {
    private let address = "https://example.com/posts/harbour-lights"

    func testOnlyNamesTheInternetCanLookUpAreCheckable() {
        let rows: [(String, Bool)] = [
            ("example.com", true), ("www.example.co.uk", true), ("Example.COM.", true), ("xn--bcher-kva.example.org", true),
            ("localhost", false), ("wiki", false), ("printer.local", false), ("wiki.corp", false), ("host.lan", false),
            ("10.0.0.5", false), ("192.168.1.20", false), ("8.8.8.8", false), ("0x7f.0.0.1", false), ("[::1]", false), ("::1", false),
            ("a..b.com", false), ("intranet.internal", false), ("nas.home.arpa", false), ("site.test", false), ("", false),
        ]
        for (host, expected) in rows {
            XCTAssertEqual(MapTextDisclosure.isPublicInternetHost(host), expected, host)
        }
    }

    func testAPrivateNetworkAddressNeverEarnsTheMark() {
        for reference in ["https://wiki.corp/notes/q3", "https://192.168.1.20/post", "https://localhost:8443/post", "https://printer.local/p"] {
            let item = Item(id: "i", title: "t", mediaType: "text", text: "x", externalReference: reference, status: "ready", externalReferenceType: "url")
            XCTAssertNil(MapTextDisclosure.checkableAddress(of: item), reference)
        }
        XCTAssertFalse(PublicSourceVerifier.isPlainHTTPS(URL(string: "https://192.168.1.20/post")!), "a redirect into a private network is refused")
    }

    func testAMarkExpiresAfterAWeek() {
        var item = Item(id: "i", title: "t", mediaType: "text", text: "x", externalReference: address, status: "ready", externalReferenceType: "url")
        let checked = Date(timeIntervalSince1970: 1_700_000_000)
        item.publicSourceMark = PublicSourceMark(url: address, checkedAt: checked)
        XCTAssertTrue(MapTextDisclosure.allowsModelText(of: item, now: checked.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertFalse(MapTextDisclosure.allowsModelText(of: item, now: checked.addingTimeInterval(8 * 24 * 3600)), "paywalled a week later, no map text goes")
    }

    func testAnExpiredMarkIsCheckedAgainAndRenewed() async throws {
        let repository = InMemorySessionRepository()
        var item = Item(id: "i", title: "t", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: address,
                        status: "ready", externalReferenceType: "url", media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/a.mp3"))
        item.publicSourceMark = PublicSourceMark(url: address, checkedAt: Date().addingTimeInterval(-9 * 24 * 3600))
        repository.items["i"] = item
        let marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: { _, _ in .init(status: 206, contentType: "audio/mpeg", body: Data([1])) }))
        _ = await marker.ensureMark(itemId: "i", repository: repository)
        let renewed = try XCTUnwrap(repository.loadItem(id: "i").publicSourceMark)
        XCTAssertLessThan(Date().timeIntervalSince(renewed.checkedAt), 60)
    }

    func testANotPublicAnswerIsNotAskedAgainOnTheNextToggle() async {
        let repository = InMemorySessionRepository()
        repository.items["i"] = Item(id: "i", title: "t", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil, externalReference: address,
                                     status: "ready", externalReferenceType: "url", media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/a.mp3"))
        let calls = Counter()
        let marker = PublicSourceMarker(verifier: PublicSourceVerifier(probe: { _, _ in calls.bump(); return .init(status: 403) }))
        for _ in 0..<3 { _ = await marker.ensureMark(itemId: "i", repository: repository) }
        XCTAssertEqual(calls.value, 1, "three option toggles, one request")
        let offline = Counter()
        let retry = PublicSourceMarker(verifier: PublicSourceVerifier(probe: { _, _ in offline.bump(); throw URLError(.notConnectedToInternet) }))
        for _ in 0..<2 { _ = await retry.ensureMark(itemId: "i", repository: repository) }
        XCTAssertEqual(offline.value, 2, "offline is tried again on the next tap")
    }

    func testAnAttributeHoldingAnArticleIsNotWhatAVisitorReads() {
        let html = Data("<div data-body='{\"html\": \"<p>hidden full text of the article</p>\"}'>Subscribe</div>".utf8)
        let text = PublicSourceVerifier.visibleText(ofHTML: html)
        XCTAssertFalse(text.contains("hidden full text"))
        XCTAssertTrue(text.contains("Subscribe"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
