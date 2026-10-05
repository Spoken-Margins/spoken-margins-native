import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit

/// Sending Margins to Readwise as highlights (#172): the request Readwise receives, that no private
/// feed link leaves the device, and that the sent-ledger file stops repeats across passes and restarts.
final class ReadwiseHighlightTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("readwise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Request body

    func testPodcastMarginRequestCarriesExcerptNoteSourceAndPodcastCategory() async throws {
        let item = Item(
            id: "item-podcast", title: "Episode 12", mediaType: "audio", text: nil,
            externalReference: "https://example.com/episodes/12", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "https://cdn.example.com/12.mp3", durationMs: 3_600_000),
            author: "The Show"
        )
        let transport = RecordingTransport()
        let highlights = try gather([(item, margin(item: item, id: "m1"))])
        try await ReadwiseHighlightClient(transport: transport.send).send(highlights, token: "secret-token")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://readwise.io/api/v2/highlights/"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = try XCTUnwrap(transport.highlights.first?.first)
        XCTAssertEqual(sent, [
            "text": "Before. After.",
            "note": "A thought.",
            "title": "Episode 12",
            "author": "The Show",
            "source_url": "https://example.com/episodes/12",
            "category": "podcasts",
            "highlighted_at": "2026-04-24T03:06:40Z",
        ])
    }

    func testArticleMarginWithoutContextSendsTheMarginAsTheHighlight() async throws {
        let item = Item(id: "item-article", title: "An essay", mediaType: "text", text: "Source text.",
                        externalReference: "https://example.com/essay", status: "ready")
        var written = margin(item: item, id: "m1", kind: .written)
        written.anchor.anchorBefore = "  "
        written.anchor.anchorAfter = ""
        let transport = RecordingTransport()
        try await ReadwiseHighlightClient(transport: transport.send).send(try gather([(item, written)]), token: "t")

        let sent = try XCTUnwrap(transport.highlights.first?.first)
        XCTAssertEqual(sent["text"], "A thought.")
        XCTAssertEqual(sent["note"], "A thought.")
        XCTAssertEqual(sent["category"], "articles")
        XCTAssertNil(sent["author"], "No author key when the item has none")
    }

    func testSpokenMarginStillBeingTranscribedIsNotSentYet() throws {
        let item = Item(id: "item-article", title: "An essay", mediaType: "text", text: "Source text.",
                        externalReference: nil, status: "ready")
        var pending = margin(item: item, id: "m1")
        pending.transcript = nil
        pending.transcriptionStatus = "pending"
        XCTAssertEqual(try gather([(item, pending)]), [])
    }

    func testPrivateFeedLinksNeverReachTheRequest() async throws {
        let privateLink = "https://www.patreon.com/rss/show?auth=abc123SECRET456def789ghi012jkl345"
        let privateMedia = "https://c10.patreonusercontent.com/episode.mp3?token-hash=zyx987SECRET654wvu321tsr098qpo765"
        let item = Item(
            id: "item-private", title: "Members episode", mediaType: "audio", text: nil,
            externalReference: privateLink, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: privateMedia),
            author: "Paid Show"
        )
        var highlights = try gather([(item, margin(item: item, id: "m1"))])
        // A hand-built export that skipped the engine's filter is still cleaned.
        var export = try buildExport(repository: repository([(item, margin(item: item, id: "m2"))]), sessionId: "session-item-private", marginId: "m2")
        export.item.externalReference = privateLink
        export.item.sourceURL = privateMedia
        highlights.append(try XCTUnwrap(ReadwiseHighlight(export: export, createdAt: createdAt)))

        let transport = RecordingTransport()
        try await ReadwiseHighlightClient(transport: transport.send).send(highlights, token: "t")
        let body = try XCTUnwrap(transport.bodies.first)
        XCTAssertFalse(body.contains("patreon"), body)
        XCTAssertFalse(body.contains("SECRET"), body)
        XCTAssertEqual(transport.highlights.first?.count, 2)
        XCTAssertNil(transport.highlights.first?.first?["source_url"])
    }

    // MARK: - Ledger

    func testSecondPassSendsNothing() async throws {
        let highlights = try twoArticleHighlights()
        let transport = RecordingTransport()
        let client = ReadwiseHighlightClient(transport: transport.send)
        let sent1 = try await ReadwiseHighlightSyncPass.run(highlights, token: "t", client: client, ledger: ledger())

        XCTAssertEqual(sent1.sent, 2)
        let sent2 = try await ReadwiseHighlightSyncPass.run(highlights, token: "t", client: client, ledger: ledger())

        XCTAssertEqual(sent2.sent, 0)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFailureMidBatchSendsOnlyTheUnsentOnTheNextPass() async throws {
        let highlights = try twoArticleHighlights() + [try highlight(id: "m3")]
        let transport = RecordingTransport(statuses: [200, 500])
        let client = ReadwiseHighlightClient(transport: transport.send)
        do {
            _ = try await ReadwiseHighlightSyncPass.run(highlights, token: "t", client: client, ledger: ledger(), batchSize: 1)
            XCTFail("The second batch failed, so the pass should throw")
        } catch let error as ReadwiseHighlightError {
            XCTAssertEqual(error, .httpStatus(500))
        }
        XCTAssertEqual(try ledger().sentKeys(), ["session-item-article:m1"])

        let sent3 = try await ReadwiseHighlightSyncPass.run(highlights, token: "t", client: client, ledger: ledger(), batchSize: 1)


        XCTAssertEqual(sent3.sent, 2)
        // m1 once; m2 failed, then sent; m3 sent.
        XCTAssertEqual(transport.highlights.map { $0.map { $0["note"] ?? "" } }, [["first"], ["second"], ["second"], ["third"]])
    }

    /// #642: tapping Disconnect during a send pass let the pass keep sending batches with the token
    /// it had captured. It now stops before the next batch and keeps the accepted one in the ledger.
    func testDisconnectDuringAPassStopsTheNextBatch() async throws {
        let highlights = try twoArticleHighlights() + [try highlight(id: "m3")]
        let transport = RecordingTransport()
        let client = ReadwiseHighlightClient(transport: transport.send)
        // The stored credential: the listener disconnects once the first batch has gone out.
        let stored = LockedValue<String?>("t")
        let sendThenDisconnect = ReadwiseHighlightClient { request in
            let result = try await transport.send(request)
            stored.set(nil)
            return result
        }
        do {
            _ = try await ReadwiseHighlightSyncPass.run(
                highlights, token: "t", client: sendThenDisconnect, ledger: ledger(), batchSize: 1,
                tokenIsCurrent: { stored.get() == $0 }
            )
            XCTFail("Disconnect should stop the pass")
        } catch is CancellationError {}
        XCTAssertEqual(transport.requests.count, 1, "no batch starts after Disconnect")
        XCTAssertEqual(try ledger().sentKeys(), ["session-item-article:m1"])

        // A different token saved meanwhile stops the old pass too.
        stored.set("new-token")
        await XCTAssertThrowsCancellation {
            try await ReadwiseHighlightSyncPass.run(highlights, token: "t", client: client, ledger: self.ledger(), batchSize: 1, tokenIsCurrent: { stored.get() == $0 })
        }
        XCTAssertEqual(transport.requests.count, 1)

        // Connected with that token, the next pass sends what's left.
        let report = try await ReadwiseHighlightSyncPass.run(highlights, token: "new-token", client: client, ledger: ledger(), batchSize: 1, tokenIsCurrent: { stored.get() == $0 })
        XCTAssertEqual(report.sent, 2)
    }

    private func XCTAssertThrowsCancellation(_ body: () async throws -> ReadwiseSyncReport, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected a CancellationError", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("expected a CancellationError, got \(error)", file: file, line: line)
        }
    }

    func testLedgerSurvivesARestartAndGathererSkipsSentMargins() async throws {
        let item = article()
        let pairs = [(item, margin(item: item, id: "m1")), (item, margin(item: item, id: "m2"))]
        let transport = RecordingTransport()
        let client = ReadwiseHighlightClient(transport: transport.send)
        _ = try await ReadwiseHighlightSyncPass.run(try gather(pairs), token: "t", client: client, ledger: ledger())

        // A new ledger value on the same file is what the app sees after a relaunch.
        let reopened = ReadwiseSentLedger(fileURL: directory.appendingPathComponent("ReadwiseSentLedger.json"))
        XCTAssertEqual(try reopened.sentKeys(), ["session-item-article:m1", "session-item-article:m2"])
        let repo = repository(pairs)
        let session = try XCTUnwrap(repo.sessions["session-item-article"])
        XCTAssertEqual(try ReadwiseHighlightGatherer.highlights(sessions: [session], repository: repo, skipping: reopened.sentKeys()), [])
        let sent4 = try await ReadwiseHighlightSyncPass.run(try gather(pairs), token: "t", client: client, ledger: reopened)

        XCTAssertEqual(sent4.sent, 0)
    }

    /// #624: a spoken Margin stored before the fix holds a counter (seconds after 1970). It goes to
    /// Readwise dated by its session's start plus the counter, not in 1970; real dates pass unchanged.
    func testMarginStoredWithACounterDateIsSentWithItsSessionDate() async throws {
        let item = article()
        var old = margin(item: item, id: "m1")
        old.createdAt = Date(timeIntervalSince1970: 2)
        let current = margin(item: item, id: "m2")
        let repo = repository([(item, old), (item, current)])
        let sessionStart = Date(timeIntervalSince1970: 1_790_000_000)
        repo.sessions["session-item-article"]?.createdAt = sessionStart
        let highlights = try ReadwiseHighlightGatherer.highlights(sessions: Array(repo.sessions.values), repository: repo)
            .sorted { $0.marginKey < $1.marginKey }

        XCTAssertEqual(highlights.map(\.highlightedAt), [sessionStart.addingTimeInterval(2), createdAt])
        let transport = RecordingTransport()
        try await ReadwiseHighlightClient(transport: transport.send).send(highlights, token: "t")
        XCTAssertEqual(transport.highlights.first?.first?["highlighted_at"], "2026-09-21T14:13:22Z")
    }

    // MARK: - Readwise's reply (#623)

    /// Readwise's documented reply to POST /api/v2/highlights/: the books the highlights were filed under.
    private static let recordedReply = """
    [
      {
        "id": 2008,
        "title": "An essay",
        "author": null,
        "category": "articles",
        "source": "api_article",
        "num_highlights": 2,
        "last_highlight_at": "2026-04-24T03:06:40.000Z",
        "updated": "2026-04-24T03:06:41.000Z",
        "cover_image_url": "https://readwise-assets.s3.amazonaws.com/static/images/article2.png",
        "highlights_url": "https://readwise.io/bookreview/2008",
        "source_url": "https://example.com/essay",
        "modified_highlights": [1012, 1013]
      }
    ]
    """

    func testRecordedReplyNamesTheItemAndLinksItToItsReadwisePage() async throws {
        let transport = RecordingTransport(bodies: [Self.recordedReply])
        let report = try await ReadwiseHighlightSyncPass.run(
            try twoArticleHighlights(), token: "t", client: ReadwiseHighlightClient(transport: transport.send), ledger: ledger()
        )

        XCTAssertEqual(report, ReadwiseSyncReport(sent: 2, unlisted: 0, itemCount: 1, latestTitle: "An essay"))
        XCTAssertEqual(report.summary, "2 Margins sent to Readwise under \u{201C}An essay\u{201D}.")
        XCTAssertEqual(try ledger().links(), ["item-article": URL(string: "https://readwise.io/bookreview/2008")!])
        // The links outlive the app: a relaunch reads the same file.
        let reopened = ReadwiseSentLedger(fileURL: directory.appendingPathComponent("ReadwiseSentLedger.json"))
        XCTAssertEqual(try reopened.links()["item-article"], URL(string: "https://readwise.io/bookreview/2008"))
    }

    func testEmptyReplyIsNotReportedAsSent() async throws {
        let transport = RecordingTransport(bodies: ["[]"])
        let report = try await ReadwiseHighlightSyncPass.run(
            try twoArticleHighlights(), token: "t", client: ReadwiseHighlightClient(transport: transport.send), ledger: ledger()
        )

        XCTAssertEqual(report.unlisted, 2)
        let summary = try XCTUnwrap(report.summary)
        XCTAssertFalse(summary.contains("sent"), summary)
        XCTAssertEqual(summary, "Readwise accepted 2 Margins but didn't list any highlights. Check your Readwise account.")
        XCTAssertEqual(try ledger().links(), [:])
        // Readwise did accept them, so they aren't sent again every minute.
        XCTAssertEqual(try ledger().sentKeys(), ["session-item-article:m1", "session-item-article:m2"])
    }

    func testBookListingNoModifiedHighlightsCountsAsUnlisted() async throws {
        let reply = #"[{"title": "An essay", "highlights_url": "https://readwise.io/bookreview/2008", "modified_highlights": []}]"#
        let report = try await ReadwiseHighlightSyncPass.run(
            try twoArticleHighlights(), token: "t",
            client: ReadwiseHighlightClient(transport: RecordingTransport(bodies: [reply]).send), ledger: ledger()
        )
        XCTAssertEqual(report.unlisted, 2)
    }

    func testUnreadableReplyStillReportsTheSendWithoutALink() async throws {
        let report = try await ReadwiseHighlightSyncPass.run(
            try twoArticleHighlights(), token: "t",
            client: ReadwiseHighlightClient(transport: RecordingTransport(bodies: ["<html>ok</html>"]).send), ledger: ledger()
        )
        XCTAssertEqual(report.summary, "2 Margins sent to Readwise under \u{201C}An essay\u{201D}.")
        XCTAssertEqual(try ledger().links(), [:])
    }

    func testSeveralItemsNameTheMostRecentAndLinkEachByTitle() async throws {
        let essay = article()
        let episode = Item(id: "item-episode", title: "  A Hacking Tool Built With A Very Long Title Indeed ", mediaType: "text",
                           text: "Source text.", externalReference: nil, status: "ready")
        var later = margin(item: episode, id: "m9")
        later.createdAt = createdAt.addingTimeInterval(60)
        let highlights = try gather([(essay, margin(item: essay, id: "m1")), (episode, later)])
        let reply = """
        [{"title": "a hacking tool built with a very long title indeed", "highlights_url": "https://readwise.io/bookreview/31", "modified_highlights": [7]},
         {"title": "An essay", "highlights_url": "https://readwise.io/bookreview/30", "modified_highlights": [6]}]
        """
        let report = try await ReadwiseHighlightSyncPass.run(
            highlights, token: "t", client: ReadwiseHighlightClient(transport: RecordingTransport(bodies: [reply]).send), ledger: ledger()
        )

        XCTAssertEqual(report.summary,
                       "2 Margins sent to Readwise across 2 items, most recently \u{201C}A Hacking Tool Built With A Very Long T\u{2026}\u{201D}.")
        XCTAssertEqual(try ledger().links(), [
            "item-article": URL(string: "https://readwise.io/bookreview/30")!,
            "item-episode": URL(string: "https://readwise.io/bookreview/31")!,
        ])
    }

    func testOnlyReadwiseLinksAreKept() async throws {
        let reply = #"[{"title": "An essay", "highlights_url": "https://readwise.io.evil.example/bookreview/1", "modified_highlights": [1]}]"#
        _ = try await ReadwiseHighlightSyncPass.run(
            try twoArticleHighlights(), token: "t",
            client: ReadwiseHighlightClient(transport: RecordingTransport(bodies: [reply]).send), ledger: ledger()
        )
        XCTAssertEqual(try ledger().links(), [:])
        XCTAssertNil(ReadwiseBook(title: "x", highlightsURL: "http://readwise.io/bookreview/1", modifiedHighlights: nil).readwiseLink)
        XCTAssertNotNil(ReadwiseBook(title: "x", highlightsURL: "https://wise.readwise.io/bookreview/1", modifiedHighlights: nil).readwiseLink)
    }

    func testLedgerFileStaysReadableByBuild29() throws {
        // Build 29's ledger decodes only `sent`; a file with links must still decode that way, and a Build 29 file must load here.
        struct Build29File: Decodable { var sent: [String] }
        let file = ledger()
        try Data(#"{"sent":["s:m1"]}"#.utf8).write(to: file.fileURL)
        XCTAssertEqual(try file.sentKeys(), ["s:m1"])
        XCTAssertEqual(try file.links(), [:])

        try file.record(["s:m2"], links: ["item": URL(string: "https://readwise.io/bookreview/9")!])
        let old = try JSONDecoder().decode(Build29File.self, from: Data(contentsOf: file.fileURL))
        XCTAssertEqual(old.sent, ["s:m1", "s:m2"])
        // A later send without a link keeps the earlier one.
        try file.record(["s:m3"])
        XCTAssertEqual(try file.links(), ["item": URL(string: "https://readwise.io/bookreview/9")!])
    }

    func testStatusLineKeepsTheLastSendThroughQuietPasses() {
        XCTAssertEqual(ReadwiseSyncReport().summary, nil)
        XCTAssertEqual(ReadwiseSyncReport(sent: 1, itemCount: 1, latestTitle: "Essay").summary,
                       "1 Margin sent to Readwise under \u{201C}Essay\u{201D}.")
        XCTAssertEqual(ReadwiseSyncReport(sent: 3, unlisted: 1, itemCount: 2, latestTitle: "Essay").summary,
                       "3 Margins sent to Readwise across 2 items, most recently \u{201C}Essay\u{201D}. Readwise didn't list 1 of them.")
        XCTAssertEqual(ReadwiseSyncReport.statusLine(lastSummary: nil, sentAt: nil, checkedAt: "8:32 AM"),
                       "No new Margins to send. Last checked 8:32 AM.")
        XCTAssertEqual(ReadwiseSyncReport.statusLine(lastSummary: "1 Margin sent to Readwise under \u{201C}Essay\u{201D}.",
                                                     sentAt: "8:30 AM", checkedAt: "8:32 AM"),
                       "1 Margin sent to Readwise under \u{201C}Essay\u{201D}. Sent 8:30 AM. Last checked 8:32 AM.")
    }

    // MARK: - Errors

    func testRejectedTokenAndRateLimitAreTypedAndRecordNothing() async throws {
        for (status, expected) in [(401, ReadwiseHighlightError.tokenRejected), (403, .tokenRejected), (429, .rateLimited)] {
            let file = ledger()
            try? FileManager.default.removeItem(at: file.fileURL)
            let client = ReadwiseHighlightClient(transport: RecordingTransport(statuses: [status]).send)
            do {
                _ = try await ReadwiseHighlightSyncPass.run(try twoArticleHighlights(), token: "t", client: client, ledger: file)
                XCTFail("HTTP \(status) should throw")
            } catch let error as ReadwiseHighlightError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(try file.sentKeys(), [], "HTTP \(status) must leave every Margin unsent")
        }
        XCTAssertEqual(ReadwiseHighlightError.tokenRejected.errorDescription, "Readwise rejected the token. Reconnect in Settings.")

        // After a 429 the next pass sends them.
        let client = ReadwiseHighlightClient(transport: RecordingTransport(statuses: [200]).send)
        let sent5 = try await ReadwiseHighlightSyncPass.run(try twoArticleHighlights(), token: "t", client: client, ledger: ledger())

        XCTAssertEqual(sent5.sent, 2)
    }

    func testMalformedTokenIsRejectedBeforeAnyRequest() async throws {
        let transport = RecordingTransport()
        do {
            try await ReadwiseHighlightClient(transport: transport.send).send(try twoArticleHighlights(), token: "a\nb")
            XCTFail("A token with a line break must not be sent")
        } catch let error as ReadwiseHighlightError {
            XCTAssertEqual(error, .invalidToken)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Fixtures

    private func ledger() -> ReadwiseSentLedger {
        ReadwiseSentLedger(fileURL: directory.appendingPathComponent("ReadwiseSentLedger.json"))
    }

    private func article() -> Item {
        Item(id: "item-article", title: "An essay", mediaType: "text", text: "Source text.",
             externalReference: "https://example.com/essay", status: "ready")
    }

    private func highlight(id: String) throws -> ReadwiseHighlight {
        var m = margin(item: article(), id: id)
        m.transcript = ["m1": "first", "m2": "second", "m3": "third"][id]
        return try XCTUnwrap(gather([(article(), m)]).first)
    }

    private func twoArticleHighlights() throws -> [ReadwiseHighlight] {
        [try highlight(id: "m1"), try highlight(id: "m2")]
    }

    private func margin(item: Item, id: String, kind: InterjectionCaptureKind? = nil) -> Interjection {
        Interjection(
            id: id, itemId: item.id, sessionId: "session-" + item.id, targetType: .item, targetId: item.id,
            createdAt: createdAt, roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: nil),
            audioPath: nil, audioStatus: kind == .written ? "discarded" : "saved",
            transcriptionStatus: "transcribed", transcript: "A thought.", cleanedTranscript: nil,
            displayText: "A thought.", status: "active", captureKind: kind
        )
    }

    private func repository(_ pairs: [(Item, Interjection)]) -> InMemorySessionRepository {
        var items: [String: Item] = [:]
        var sessions: [String: Session] = [:]
        var margins: [String: Interjection] = [:]
        for (item, margin) in pairs {
            items[item.id] = item
            sessions[margin.sessionId] = Session(
                id: margin.sessionId, itemId: item.id, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: item.id,
                position: Position(), completionPercent: 0, playbackRate: 1
            )
            margins[margin.id] = margin
        }
        return InMemorySessionRepository(items: items, sessions: sessions, interjections: margins)
    }

    private func gather(_ pairs: [(Item, Interjection)]) throws -> [ReadwiseHighlight] {
        let repo = repository(pairs)
        return try ReadwiseHighlightGatherer.highlights(
            sessions: repo.sessions.values.sorted { $0.id < $1.id }, repository: repo
        ).sorted { $0.marginKey < $1.marginKey }
    }

    private func buildExport(repository: InMemorySessionRepository, sessionId: String, marginId: String) throws -> SessionExport {
        try SessionEngine(
            profile: RuntimeCapabilityProfile(id: "test", displayName: "Test", capabilities: [:]),
            repository: repository
        ).buildExport(options: ExportOptions(
            sessionId: sessionId,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false,
            scope: "selected_interjections", interjectionIds: [marginId]
        ))
    }
}

/// Records each request and answers with the next scripted status (200 once the script runs out)
/// and the next scripted body ("{}" once that script runs out).
private final class RecordingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]
    private var replies: [String]
    private(set) var requests: [URLRequest] = []

    init(statuses: [Int] = [], bodies: [String] = []) { self.statuses = statuses; self.replies = bodies }

    var bodies: [String] { requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }

    var highlights: [[[String: String]]] {
        requests.map { request in
            struct Body: Decodable { let highlights: [[String: String]] }
            return (try? JSONDecoder().decode(Body.self, from: request.httpBody ?? Data()))?.highlights ?? []
        }
    }

    var send: ReadwiseHighlightClient.Transport {
        { [self] request in
            let (status, body): (Int, String) = lock.withLock {
                requests.append(request)
                return (statuses.isEmpty ? 200 : statuses.removeFirst(), replies.isEmpty ? "{}" : replies.removeFirst())
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// A value read and written from the transport and the pass (#642).
private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
