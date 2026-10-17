import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #1896: following a feed and refreshing it writes one `item_published` row per retained entry to the listening
/// signal log, naming the source and the item. This used to be checked by searching the coordinator's source text
/// for the call, which passes when the arguments are wrong or the app hands the coordinator no recorder.
final class FollowedSourceSignalTests: XCTestCase {
    private var logURL: URL!

    override func setUpWithError() throws {
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("signal-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("i4-engagement.jsonl")
        SignalFeedURLProtocol.episodeCount = 3
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
    }

    private func coordinator(_ repository: InMemorySessionRepository, signals: ListeningSignalRecorder?) -> FollowedSourceCoordinator {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignalFeedURLProtocol.self]
        return FollowedSourceCoordinator(repository: repository, session: URLSession(configuration: configuration), signals: signals)
    }

    func testFollowingAFeedRecordsOneItemPublishedRowPerEntryNamingTheSourceAndItem() async throws {
        let repository = InMemorySessionRepository()
        let recorder = ListeningSignalRecorder(fileURL: logURL, flushDelay: 0.01)
        let coordinator = coordinator(repository, signals: recorder)

        let subscription = try await coordinator.follow(urlString: "https://signals.example/feed.json")
        let entries = try await coordinator.entries()
        XCTAssertEqual(entries.count, 3)

        let rows = recorder.signals()
        XCTAssertEqual(rows.count, 3, "one row per retained entry")
        XCTAssertTrue(rows.allSatisfy { $0.event == .itemPublished })
        XCTAssertTrue(rows.allSatisfy { $0.source == ListeningSignalContext.source(for: subscription) })
        XCTAssertEqual(rows.first?.source.title, "Signal Show")
        XCTAssertEqual(Set(rows.compactMap { $0.item?.id }), Set(entries.map(\.id)), "each row names its entry")
        XCTAssertEqual(Set(rows.compactMap { $0.item?.title }), ["Episode 1", "Episode 2", "Episode 3"])
        for row in rows {
            let entry = try XCTUnwrap(entries.first { $0.id == row.item?.id })
            XCTAssertEqual(row.item?.publishedAt, entry.publishedAt, "the row carries the episode's own publication date")
        }
    }

    func testRefreshingAddsOnlyTheNewEpisodeBecauseEachEntryIsPublishedOnce() async throws {
        let repository = InMemorySessionRepository()
        let recorder = ListeningSignalRecorder(fileURL: logURL, flushDelay: 0.01)
        let coordinator = coordinator(repository, signals: recorder)
        _ = try await coordinator.follow(urlString: "https://signals.example/feed.json")
        XCTAssertEqual(recorder.signals().count, 3)

        _ = await coordinator.refreshStale(force: true)
        XCTAssertEqual(recorder.signals().count, 3, "a refresh with nothing new publishes nothing again")

        SignalFeedURLProtocol.episodeCount = 4
        _ = await coordinator.refreshStale(force: true)
        let rows = recorder.signals()
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.compactMap { $0.item?.title }.sorted(), ["Episode 1", "Episode 2", "Episode 3", "Episode 4"])
    }

    func testWithoutARecorderFollowingStillWorksAndWritesNoLog() async throws {
        let repository = InMemorySessionRepository()
        let coordinator = coordinator(repository, signals: nil)
        _ = try await coordinator.follow(urlString: "https://signals.example/feed.json")
        let entries = try await coordinator.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }
}

/// A JSON feed of `episodeCount` dated episodes.
private final class SignalFeedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var episodeCount = 3

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "signals.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let formatter = ISO8601DateFormatter()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let items = (1...Self.episodeCount).map { index in
            let date = formatter.string(from: base.addingTimeInterval(Double(index) * 86_400))
            return #"{"id":"ep-\#(index)","url":"https://signals.example/episodes/\#(index)","title":"Episode \#(index)","date_published":"\#(date)","attachments":[{"url":"https://signals.example/\#(index).mp3","mime_type":"audio/mpeg"}]}"#
        }
        let data = Data(#"{"version":"https://jsonfeed.org/version/1.1","title":"Signal Show","items":[\#(items.joined(separator: ","))]}"#.utf8)
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/feed+json", "Content-Length": "\(data.count)"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
