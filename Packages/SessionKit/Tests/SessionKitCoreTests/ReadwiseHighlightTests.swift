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

        XCTAssertEqual(sent1, 2)
        let sent2 = try await ReadwiseHighlightSyncPass.run(highlights, token: "t", client: client, ledger: ledger())

        XCTAssertEqual(sent2, 0)
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


        XCTAssertEqual(sent3, 2)
        // m1 once; m2 failed, then sent; m3 sent.
        XCTAssertEqual(transport.highlights.map { $0.map { $0["note"] ?? "" } }, [["first"], ["second"], ["second"], ["third"]])
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

        XCTAssertEqual(sent4, 0)
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

        XCTAssertEqual(sent5, 2)
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

/// Records each request and answers with the next scripted status (200 once the script runs out).
private final class RecordingTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]
    private(set) var requests: [URLRequest] = []

    init(statuses: [Int] = []) { self.statuses = statuses }

    var bodies: [String] { requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }

    var highlights: [[[String: String]]] {
        requests.map { request in
            struct Body: Decodable { let highlights: [[String: String]] }
            return (try? JSONDecoder().decode(Body.self, from: request.httpBody ?? Data()))?.highlights ?? []
        }
    }

    var send: ReadwiseHighlightClient.Transport {
        { [self] request in
            let status: Int = lock.withLock {
                requests.append(request)
                return statuses.isEmpty ? 200 : statuses.removeFirst()
            }
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
