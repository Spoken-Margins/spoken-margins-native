import Foundation
import XCTest
@testable import SessionKit

/// #579: the app's one readable-page extractor refused a second page while it read the first, so a link shared
/// from another app at that moment was quarantined as "No readable article text was found."; and a capture that
/// never returned held every later page until relaunch.
@MainActor
final class ReadablePageQueueTests: XCTestCase {
    func testASecondPageWaitsForTheFirstInsteadOfBeingRefused() async throws {
        let reader = OnePageReader()

        // Today's extractor, called directly: the second page is refused while the first loads.
        let first = Task { try await reader.read(URL(string: "https://example.com/first")!) }
        await reader.waitUntilLoading(count: 1)
        await XCTAssertThrowsErrorAsync(try await reader.read(URL(string: "https://example.com/second")!)) {
            XCTAssertEqual($0.localizedDescription, "No readable article text was found.")
        }
        reader.finishLoading()
        _ = try await first.value

        // Through the queue: both pages are read, one after the other.
        let queue = ReadablePageQueue()
        let shared = Task { try await queue.read { try await reader.read(URL(string: "https://example.com/shared")!) } }
        await reader.waitUntilLoading(count: 2)
        let added = Task { try await queue.read { try await reader.read(URL(string: "https://example.com/added")!) } }
        await Task.yield()
        XCTAssertEqual(reader.loaded.count, 2, "the second page must wait for the first")
        reader.finishLoading()
        await reader.waitUntilLoading(count: 3)
        reader.finishLoading()

        let sharedPage = try await shared.value
        let addedPage = try await added.value
        XCTAssertEqual(sharedPage.source.url, "https://example.com/shared")
        XCTAssertEqual(addedPage.source.url, "https://example.com/added")
        XCTAssertEqual(reader.loaded.map(\.absoluteString).suffix(2), ["https://example.com/shared", "https://example.com/added"])
    }

    func testACaptureThatNeverReturnsEndsWithATimeoutAndFreesTheQueue() async throws {
        let queue = ReadablePageQueue(timeLimit: .milliseconds(50))
        var stops = 0
        let started = ContinuousClock.now

        await XCTAssertThrowsErrorAsync(try await queue.read({
            // A capture script that never calls back and ignores cancellation.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return Self.page("https://example.com/never")
        }, stop: { stops += 1 })) {
            XCTAssertEqual($0 as? ReadablePageTimeout, ReadablePageTimeout(limit: .milliseconds(50)))
        }
        XCTAssertEqual(stops, 1, "the reader is told to give up its page")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))

        let next = try await queue.read { Self.page("https://example.com/next") }
        XCTAssertEqual(next.source.url, "https://example.com/next")
    }

    func testAPageReadInTimeIsNotStoppedAndErrorsPassThrough() async throws {
        let queue = ReadablePageQueue(timeLimit: .milliseconds(50))
        var stops = 0

        let page = try await queue.read({ Self.page("https://example.com/quick") }, stop: { stops += 1 })
        XCTAssertEqual(page.source.url, "https://example.com/quick")
        await XCTAssertThrowsErrorAsync(try await queue.read({ throw URLError(.notConnectedToInternet) }, stop: { stops += 1 })) {
            XCTAssertEqual(($0 as? URLError)?.code, .notConnectedToInternet)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(stops, 0)
    }

    func testTheDefaultLimitIsAMinute() {
        XCTAssertEqual(ReadablePageQueue.defaultTimeLimit, .seconds(60))
        XCTAssertEqual(ReadablePageTimeout(limit: .seconds(60)).localizedDescription,
                       "The article took longer than 60 seconds to read.")
    }

    nonisolated static func page(_ url: String) -> BrowserTextHandoff {
        BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: url, title: url),
            text: "Text of \(url).",
            contentFormat: .markdown,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }
}

/// Stands in for the app's extractor as it is today: one web view, and a page asked for while another loads
/// is refused (`AppOwnedReadablePageExtractor.extract`'s `continuation == nil` guard).
@MainActor
private final class OnePageReader {
    struct Refused: LocalizedError {
        var errorDescription: String? { "No readable article text was found." }
    }

    private(set) var loaded: [URL] = []
    private var loading: CheckedContinuation<Void, Never>?

    func read(_ url: URL) async throws -> BrowserTextHandoff {
        guard loading == nil else { throw Refused() }
        loaded.append(url)
        await withCheckedContinuation { loading = $0 }
        return ReadablePageQueueTests.page(url.absoluteString)
    }

    func finishLoading() {
        let current = loading
        loading = nil
        current?.resume()
    }

    func waitUntilLoading(count: Int) async {
        while loaded.count < count || loading == nil {
            await Task.yield()
        }
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}
