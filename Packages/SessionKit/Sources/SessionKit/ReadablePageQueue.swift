import Foundation

/// Reads one page at a time, each within a time limit (#579).
///
/// The app has one readable-page extractor, and it refused a second page while it was reading the first:
/// a link shared from another app while the listener added an article was quarantined as "No readable
/// article text was found." Now the second page waits its turn. A page whose capture never returns ended
/// nothing and held every later page; now it ends with `ReadablePageTimeout` after `timeLimit`.
@MainActor
public final class ReadablePageQueue {
    public static let defaultTimeLimit: Duration = .seconds(60)

    private let timeLimit: Duration
    private var reading = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(timeLimit: Duration = ReadablePageQueue.defaultTimeLimit) {
        self.timeLimit = timeLimit
    }

    /// Runs `read` once every earlier page has finished. When `read` hasn't finished after the time limit,
    /// `stop` is called so the reader can give up its page, and the caller gets `ReadablePageTimeout` whether
    /// or not `read` ever returns. The next page starts once this caller has its answer.
    public func read(
        _ read: @escaping @MainActor () async throws -> BrowserTextHandoff,
        stop: @escaping @MainActor () -> Void = {}
    ) async throws -> BrowserTextHandoff {
        await waitForTurn()
        defer { finishTurn() }
        let answered = Answered()
        let limit = timeLimit
        return try await withCheckedThrowingContinuation { continuation in
            answered.work = Task { @MainActor in
                let result: Result<BrowserTextHandoff, Error>
                do { result = .success(try await read()) } catch { result = .failure(error) }
                guard answered.claim() else { return }
                answered.timer?.cancel()
                continuation.resume(with: result)
            }
            answered.timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                guard answered.claim() else { return }
                answered.work?.cancel()
                stop()
                continuation.resume(throwing: ReadablePageTimeout(limit: limit))
            }
        }
    }

    private func waitForTurn() async {
        guard reading else {
            reading = true
            return
        }
        // `finishTurn` hands the turn over without clearing `reading`.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func finishTurn() {
        if waiting.isEmpty {
            reading = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// A page that was still being read when its time limit ran out.
public struct ReadablePageTimeout: LocalizedError, Equatable, Sendable {
    public let limit: Duration

    public init(limit: Duration) {
        self.limit = limit
    }

    public var errorDescription: String? {
        "The article took longer than \(limit.components.seconds) seconds to read."
    }
}

/// Whichever of the page and the time limit finishes first answers the caller.
@MainActor
private final class Answered {
    private var done = false
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    func claim() -> Bool {
        guard !done else { return false }
        done = true
        return true
    }
}
